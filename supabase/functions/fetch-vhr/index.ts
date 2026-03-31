import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type CheapVhrSuccess = {
    yearMakeModel: string;
    vin: string;
    id: string;
    html: string;
};

const corsHeaders: Record<string, string> = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: corsHeaders,
    });
}

function normalizeVin(vin: string): string {
    return vin.trim().toUpperCase();
}

function isValidVin(vin: string): boolean {
    return /^[A-HJ-NPR-Z0-9]{17}$/.test(vin);
}

Deno.serve(async (req: Request) => {
    // 1. Manejo de CORS (Seguridad del navegador/cliente)
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (req.method !== "POST") {
        return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
    }

    // 2. Cargar variables de entorno secretas
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const cheapVhrApiKey = Deno.env.get("CHEAPVHR_API_KEY");

    if (!supabaseUrl || !supabaseServiceRoleKey || !cheapVhrApiKey) {
        return jsonResponse({ error: "Server configuration error." }, 500);
    }

    // 3. Validar que el usuario que llama a la función esté logueado en la app
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
        return jsonResponse({ error: "Missing or invalid Authorization header." }, 401);
    }

    const jwt = authHeader.replace("Bearer ", "").trim();

    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey, {
        global: {
            headers: {
                Authorization: `Bearer ${jwt}`,
            },
        },
    });

    const {
        data: { user },
        error: userError,
    } = await supabase.auth.getUser(jwt);

    if (userError || !user) {
        return jsonResponse({ error: "Unauthorized user token." }, 401);
    }

    // 4. Extraer y limpiar el VIN del cuerpo de la petición
    let vin: string;
    try {
        const body = await req.json();
        vin = normalizeVin(String(body?.vin ?? ""));
    } catch {
        return jsonResponse({ error: "Invalid JSON body." }, 400);
    }

    if (!isValidVin(vin)) {
        return jsonResponse({ error: "Invalid VIN format." }, 400);
    }

    // 5. CEREBRO DE AHORRO: Buscar en el Caché Global primero
    const { data: cached, error: cacheError } = await supabase
        .from("global_vin_cache_kbuck")
        .select("vin, carfax_html, cheapvhr_report_id, year_make_model, last_fetched_at")
        .eq("vin", vin)
        .maybeSingle();

    if (cacheError) {
        return jsonResponse({ error: "Cache lookup failed.", details: cacheError.message }, 500);
    }

    // Si ya existe en la base de datos, lo devolvemos gratis y cortamos aquí
    if (cached?.carfax_html) {
        return jsonResponse(
            {
                yearMakeModel: cached.year_make_model,
                vin: cached.vin,
                id: cached.cheapvhr_report_id,
                html: cached.carfax_html,
                lastFetchedAt: cached.last_fetched_at,
                fromCache: true,
            },
            200,
        );
    }

    // 6. Si no está en caché, le pedimos a CheapVHR que nos lo venda
    const apiUrl = `https://api.cheapvhr.com/v1/carfax/vin/${encodeURIComponent(vin)}/html`;

    let apiResponse: Response;
    try {
        apiResponse = await fetch(apiUrl, {
            method: "GET",
            headers: {
                "x-api-key": cheapVhrApiKey,
                "Accept": "application/json",
            },
        });
    } catch {
        return jsonResponse({ error: "Failed to connect to CheapVHR." }, 502);
    }

    // Manejo exacto de los errores de la API de CheapVHR
    if (!apiResponse.ok) {
        const status = apiResponse.status;
        const mapped = {
            400: { status: 400, error: "Invalid VIN sent to CheapVHR." },
            401: { status: 502, error: "CheapVHR authentication failed. (IP or API Key issue)" },
            404: { status: 404, error: "No report found for this VIN." },
            429: { status: 429, error: "CheapVHR rate limit exceeded. Please retry shortly." },
            500: { status: 502, error: "CheapVHR server error." },
        }[status] ?? { status: 502, error: "Unexpected CheapVHR error." };

        return jsonResponse(mapped, mapped.status);
    }

    // 7. Parsear la respuesta exitosa
    let report: CheapVhrSuccess;
    try {
        report = (await apiResponse.json()) as CheapVhrSuccess;
    } catch {
        return jsonResponse({ error: "Invalid CheapVHR response format." }, 502);
    }

    if (!report?.vin || !report?.id || typeof report?.html !== "string") {
        return jsonResponse({ error: "Incomplete CheapVHR response payload." }, 502);
    }

    // 8. Guardar el nuevo reporte en nuestra base de datos para no volver a pagarlo
    const nowIso = new Date().toISOString();

    const { error: upsertError } = await supabase.from("global_vin_cache_kbuck").upsert(
        {
            vin,
            carfax_html: report.html,
            cheapvhr_report_id: report.id,
            year_make_model: report.yearMakeModel ?? null,
            last_fetched_at: nowIso,
        },
        { onConflict: "vin" },
    );

    if (upsertError) {
        return jsonResponse({ error: "Failed to update cache.", details: upsertError.message }, 500);
    }

    // 9. Devolver el reporte final a la app nativa (Swift)
    // NOTA: Se ha eliminado intencionalmente el descuento de cuota aquí,
    // ya que la transacción se maneja exclusivamente vía StoreKit (Apple IAP).
    return jsonResponse(
        {
            yearMakeModel: report.yearMakeModel,
            vin: report.vin,
            id: report.id,
            html: report.html,
            lastFetchedAt: nowIso,
            fromCache: false,
        },
        200,
    );
});