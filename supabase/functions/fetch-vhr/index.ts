import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function normalizeVin(vin: string): string {
    return vin.trim().toUpperCase();
}

function isValidVin(vin: string): boolean {
    return /^[A-HJ-NPR-Z0-9]{17}$/.test(vin);
}

// --- FUNCIONES DE AUDITORÍA Y SEGURIDAD ---
async function logCarfaxAttempt(
    supabase: ReturnType<typeof createClient>,
    payload: { user_id: string; vin: string; status: string; source: string; detail?: string | null }
) {
    await supabase.from("carfax_request_log_kbuck").insert({
        user_id: payload.user_id,
        vin: payload.vin,
        status: payload.status,
        source: payload.source,
        detail: payload.detail ?? null,
        created_at: new Date().toISOString(),
    });
}

async function getUserAccess(supabase: ReturnType<typeof createClient>, userId: string) {
    const { data: profile, error: profileError } = await supabase
        .from("profiles_kbuck")
        .select("plan_tier, role")
        .eq("id", userId)
        .single();

    if (profileError || !profile) return { allowed: false, reason: "Unable to load user profile." };

    const planTier = String(profile.plan_tier ?? "").toLowerCase();
    const role = String(profile.role ?? "").toLowerCase();

    if (role === "super_admin") {
        return { allowed: true, planTier, role, consumeCredit: false };
    }

    const { data: creditRow, error: creditError } = await supabase
        .from("carfax_credits_kbuck")
        .select("remaining_credits")
        .eq("user_id", userId)
        .single();

    if (creditError || !creditRow) return { allowed: false, reason: "No Carfax entitlement found for this user." };

    const remainingCredits = Number(creditRow.remaining_credits ?? 0);
    if (remainingCredits <= 0) return { allowed: false, reason: "No Carfax credits remaining." };

    return { allowed: true, planTier, role, consumeCredit: true, remainingCredits };
}

async function consumeUserCredit(supabase: ReturnType<typeof createClient>, userId: string) {
    const { data: creditRow, error: readError } = await supabase
        .from("carfax_credits_kbuck")
        .select("remaining_credits")
        .eq("user_id", userId)
        .single();

    if (readError || !creditRow) return { ok: false, error: "Unable to load credit row." };

    const remaining = Number(creditRow.remaining_credits ?? 0);
    if (remaining <= 0) return { ok: false, error: "No credits remaining." };

    const { error: updateError } = await supabase
        .from("carfax_credits_kbuck")
        .update({
            remaining_credits: remaining - 1,
            updated_at: new Date().toISOString(),
        })
        .eq("user_id", userId);

    if (updateError) return { ok: false, error: updateError.message };
    return { ok: true };
}

async function consumeCreditIfNeeded(
    supabase: ReturnType<typeof createClient>,
    userId: string,
    vin: string,
    access: { consumeCredit?: boolean },
) {
    if (!access.consumeCredit) return { ok: true };

    const consume = await consumeUserCredit(supabase, userId);
    if (!consume.ok) {
        await logCarfaxAttempt(supabase, { user_id: userId, vin, status: "credit_failed", source: "blocked", detail: consume.error });
        return { ok: false, error: consume.error ?? "Unable to consume credit." };
    }

    return { ok: true };
}
// --------------------------------------------------------

Deno.serve(async (req: Request) => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
    if (req.method !== "POST") return jsonResponse({ error: "Method not allowed. Use POST." }, 405);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const cheapVhrApiKey = Deno.env.get("CHEAPVHR_API_KEY");
    
    // INFRAESTRUCTURA DE TÚNEL NATIVA DE DENO
    const proxyUrl = Deno.env.get("FIXIE_URL");
    
    if (!proxyUrl) {
        return jsonResponse({ error: "CRÍTICO: Túnel proxy desconectado. Abortando para evitar bloqueo de IPv6." }, 500);
    }
    
    const proxyClient = Deno.createHttpClient({
        proxy: { url: proxyUrl }
    });

    if (!supabaseUrl || !supabaseServiceRoleKey || !cheapVhrApiKey) {
        return jsonResponse({ error: "Server configuration error." }, 500);
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
        return jsonResponse({ error: "Missing or invalid Authorization header." }, 401);
    }

    const jwt = authHeader.replace("Bearer ", "").trim();
    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey, {
        global: { headers: { Authorization: `Bearer ${jwt}` } },
    });

    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) return jsonResponse({ error: "Unauthorized user token." }, 401);

    let vin: string;
    try {
        const body = await req.json();
        vin = normalizeVin(String(body?.vin ?? ""));
    } catch {
        return jsonResponse({ error: "Invalid JSON body." }, 400);
    }

    if (!isValidVin(vin)) return jsonResponse({ error: "Invalid VIN format." }, 400);

    // 1. VERIFICACIÓN DE SEGURIDAD Y PLAN
    const access = await getUserAccess(supabase, user.id);
    if (!access.allowed) {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "denied", source: "blocked", detail: access.reason });
        return jsonResponse({ error: access.reason ?? "Unauthorized Carfax access." }, 403);
    }

    // 2. CACHÉ GLOBAL
    const { data: cached, error: cacheError } = await supabase
        .from("global_vin_cache_kbuck")
        .select("vin, carfax_html, cheapvhr_report_id, year_make_model, last_fetched_at")
        .eq("vin", vin)
        .maybeSingle();

    if (cacheError) {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "cache_error", source: "blocked", detail: cacheError.message });
        return jsonResponse({ error: "Cache lookup failed.", details: cacheError.message }, 500);
    }

    if (cached?.carfax_html) {
        const consume = await consumeCreditIfNeeded(supabase, user.id, vin, access);
        if (!consume.ok) {
            return jsonResponse({ error: consume.error ?? "Unable to consume credit." }, 403);
        }

        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "served", source: "cache" });
        return jsonResponse({
            yearMakeModel: cached.year_make_model,
            vin: cached.vin,
            id: cached.cheapvhr_report_id,
            html: cached.carfax_html,
            lastFetchedAt: cached.last_fetched_at,
            fromCache: true,
        }, 200);
    }

    // 3. LLAMADA A CHEAPVHR (CON TÚNEL INQUEBRANTABLE)
    const apiUrl = `https://api.cheapvhr.com/v1/carfax/vin/${encodeURIComponent(vin)}/html`;

    let apiResponse: Response;
    try {
        apiResponse = await fetch(apiUrl, {
            method: "GET",
            headers: {
                "x-api-key": cheapVhrApiKey,
                "Accept": "application/json",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
            },
            client: proxyClient,
        });
    } catch (e: any) {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "upstream_connect_error", source: "upstream", detail: e.message });
        return jsonResponse({ error: `Proxy connection failed: ${e.message}` }, 502);
    }

    if (!apiResponse.ok) {
        const status = apiResponse.status;
        const errorText = await apiResponse.text().catch(() => "No response body");
        console.error(`[UPSTREAM ERROR] Status: ${status}, Body: ${errorText}`);
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: `upstream_${status}`, source: "upstream", detail: errorText.substring(0, 300) });

        const mapped: Record<number, any> = {
            400: { status: 400, error: "Invalid VIN sent to CheapVHR." },
            401: { status: 502, error: "CheapVHR authentication failed. (IP or API Key issue)" },
            404: { status: 404, error: "No report found for this VIN." },
            429: { status: 429, error: "CheapVHR rate limit exceeded. Please retry shortly." },
            500: { status: 502, error: "CheapVHR server error." },
        };
        const mappedError = mapped[status] ?? { status: 502, error: `Upstream Error ${status}: ${errorText.substring(0, 150)}` };

        return jsonResponse(mappedError, mappedError.status);
    }

    let report: any;
    try {
        report = await apiResponse.json();
    } catch {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "invalid_upstream_payload", source: "upstream", detail: "Failed to parse JSON." });
        return jsonResponse({ error: "Invalid CheapVHR response format." }, 502);
    }

    if (!report?.vin || typeof report?.html !== "string") {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "incomplete_upstream_payload", source: "upstream", detail: "Missing vin or html." });
        return jsonResponse({ error: "Incomplete CheapVHR response payload." }, 502);
    }

    // 🚨 5. SANITIZACIÓN EXTREMA: Forzamos a String puro para que iOS no colapse con diccionarios
    const safeId = typeof report.id === 'object' ? JSON.stringify(report.id) : String(report.id || "0");
    const safeYmm = typeof report.yearMakeModel === 'object' ? JSON.stringify(report.yearMakeModel) : String(report.yearMakeModel || "Desconocido");
    const safeVin = String(report.vin);

    console.log(`✅ [ÉXITO] CheapVHR respondió. Limpiamos los diccionarios rebeldes para iOS.`);

    // 4. GUARDADO EN CACHÉ
    const nowIso = new Date().toISOString();
    const { error: upsertError } = await supabase.from("global_vin_cache_kbuck").upsert(
        {
            vin: safeVin,
            carfax_html: report.html,
            cheapvhr_report_id: safeId,
            year_make_model: safeYmm,
            last_fetched_at: nowIso,
        },
        { onConflict: "vin" },
    );

    if (upsertError) {
        await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "cache_write_failed", source: "upstream", detail: upsertError.message });
        return jsonResponse({ error: "Failed to update cache.", details: upsertError.message }, 500);
    }

    // 5. COBRO DE CRÉDITO
    const consume = await consumeCreditIfNeeded(supabase, user.id, vin, access);
    if (!consume.ok) {
        return jsonResponse({ error: consume.error ?? "Unable to consume credit." }, 403);
    }

    await logCarfaxAttempt(supabase, { user_id: user.id, vin, status: "served", source: "upstream" });

    return jsonResponse({
        yearMakeModel: safeYmm,
        vin: safeVin,
        id: safeId,
        html: report.html,
        lastFetchedAt: nowIso,
        fromCache: false,
    }, 200);
});
