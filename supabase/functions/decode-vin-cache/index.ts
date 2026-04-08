import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CacheRow = {
    vin: string;
    year: number | null;
    make: string | null;
    model: string | null;
    trim: string | null;
    engine_cylinders: string | null;
    engine_displacement_l: string | null;
    drive_type: string | null;
    body_class: string | null;
};

type NHTSAVariableResult = {
    Variable: string;
    Value: string | null;
};

type NHTSAResponse = {
    Results: NHTSAVariableResult[];
};

function jsonResponse(body: unknown, status = 200) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
}

function normalizeVIN(rawVIN: string) {
    return rawVIN.toUpperCase().replace(/[^A-HJ-NPR-Z0-9]/g, "");
}

function normalizeRole(rawRole: string | null | undefined) {
    return (rawRole ?? "user").trim().toLowerCase().replace(/-/g, "_");
}

function cleanValue(rawValue: string | null | undefined) {
    if (!rawValue) return null;
    const trimmed = rawValue.trim();
    if (!trimmed) return null;

    const normalized = trimmed.toLowerCase();
    if (["null", "n/a", "not applicable"].includes(normalized)) return null;
    return trimmed;
}

function titleCase(rawValue: string | null | undefined) {
    const cleaned = cleanValue(rawValue);
    if (!cleaned) return null;
    return cleaned
        .toLowerCase()
        .split(/\s+/)
        .map((token) => token.charAt(0).toUpperCase() + token.slice(1))
        .join(" ");
}

function cleanModel(rawModel: string | null | undefined) {
    const cleaned = cleanValue(rawModel);
    if (!cleaned) return null;

    return cleaned
        .toLowerCase()
        .split(/\s+/)
        .map((token) => {
            const upper = token.toUpperCase();
            if (upper === "CRV") return "CR-V";
            if (upper === "RAV4") return "RAV4";
            if (upper === "F150") return "F-150";
            if (upper === "CX5") return "CX-5";
            return token.charAt(0).toUpperCase() + token.slice(1);
        })
        .join(" ");
}

function parseYear(rawYear: string | null | undefined) {
    const cleaned = cleanValue(rawYear);
    if (!cleaned) return null;

    const year = Number.parseInt(cleaned, 10);
    if (Number.isNaN(year)) return null;
    if (cleaned.length === 2) return year <= 24 ? 2000 + year : 1900 + year;
    return year;
}

function engineDisplayFromRow(row: CacheRow) {
    const liters = cleanValue(row.engine_displacement_l);
    const cylinders = cleanValue(row.engine_cylinders);
    if (liters && cylinders) return `${liters}L • ${cylinders} cyl`;
    if (liters) return `${liters}L`;
    if (cylinders) return `${cylinders} cyl`;
    return null;
}

function buildResponse(row: CacheRow, source: "cache" | "nhtsa") {
    return {
        vin: row.vin,
        year: row.year ? String(row.year) : "",
        make: row.make ?? "",
        model: row.model ?? "",
        trim: row.trim ?? "",
        bodyClass: row.body_class ?? "",
        driveType: row.drive_type ?? "",
        engine: engineDisplayFromRow(row) ?? "",
        source,
    };
}

function getVariable(results: NHTSAVariableResult[], variableName: string) {
    const match = results.find(
        (result) => result.Variable.trim().toLowerCase() === variableName.trim().toLowerCase(),
    );
    return cleanValue(match?.Value);
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    try {
        console.log("[decode-vin-cache] request received");
        const supabaseUrl = Deno.env.get("SUPABASE_URL");
        const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

        if (!supabaseUrl || !serviceRoleKey) {
            console.error("[decode-vin-cache] missing Supabase environment");
            return jsonResponse({ error: "Missing Supabase environment." }, 500);
        }

        const authHeader = req.headers.get("Authorization") ?? req.headers.get("authorization");
        if (!authHeader?.startsWith("Bearer ")) {
            console.error("[decode-vin-cache] missing bearer token");
            return jsonResponse({ error: "Missing bearer token" }, 401);
        }

        const token = authHeader.slice("Bearer ".length).trim();
        if (!token) {
            console.error("[decode-vin-cache] empty bearer token");
            return jsonResponse({ error: "Missing bearer token" }, 401);
        }

        const supabase = createClient(supabaseUrl, serviceRoleKey, {
            global: { headers: { Authorization: `Bearer ${token}` } },
            auth: { persistSession: false },
        });
        const { data: authData, error: authError } = await supabase.auth.getUser(token);
        const user = authData.user;

        if (authError || !user) {
            console.error("[decode-vin-cache] unauthorized", authError?.message ?? "no-user");
            return jsonResponse({ error: authError?.message ?? "Unauthorized" }, 401);
        }

        console.log("[decode-vin-cache] user", user.id);

        const { data: profile, error: profileError } = await supabase
            .from("profiles_kbuck")
            .select("role")
            .eq("id", user.id)
            .single();

        if (profileError) {
            console.error("[decode-vin-cache] profile lookup failed", profileError.message);
            return jsonResponse({ error: profileError.message || "Unable to resolve profile role" }, 403);
        }

        const normalizedRole = normalizeRole(profile?.role);
        console.log("[decode-vin-cache] role", profile?.role, "normalized", normalizedRole);
        if (normalizedRole !== "super_admin") {
            console.error("[decode-vin-cache] forbidden role", normalizedRole);
            return jsonResponse({ error: "Forbidden" }, 403);
        }

        const body = await req.json();
        const vin = normalizeVIN(String(body?.vin ?? ""));
        console.log("[decode-vin-cache] normalized vin", vin);
        if (vin.length !== 17) {
            console.error("[decode-vin-cache] invalid vin", vin);
            return jsonResponse({ error: "Invalid VIN" }, 400);
        }

        const { data: cachedRows, error: cacheError } = await supabase
            .from("global_vin_cache_kbuck")
            .select("vin, year, make, model, trim, engine_cylinders, engine_displacement_l, drive_type, body_class")
            .eq("vin", vin)
            .limit(1);

        if (cacheError) {
            console.error("[decode-vin-cache] cache lookup failed", cacheError.message);
            return jsonResponse({ error: cacheError.message }, 500);
        }

        const cachedRow = cachedRows?.[0] as CacheRow | undefined;
        if (cachedRow?.make && cachedRow?.model) {
            console.log("[decode-vin-cache] cache hit", JSON.stringify(cachedRow));
            return jsonResponse(buildResponse(cachedRow, "cache"));
        }

        const nhtsaURL = `https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/${vin}?format=json`;
        console.log("[decode-vin-cache] cache miss, fetching NHTSA", nhtsaURL);
        const nhtsaResponse = await fetch(nhtsaURL);

        if (!nhtsaResponse.ok) {
            console.error("[decode-vin-cache] NHTSA failed", nhtsaResponse.status);
            return jsonResponse({ error: `NHTSA decode failed with status ${nhtsaResponse.status}` }, 502);
        }

        const nhtsaPayload = (await nhtsaResponse.json()) as NHTSAResponse;
        const results = Array.isArray(nhtsaPayload.Results) ? nhtsaPayload.Results : [];

        const upsertRow: CacheRow = {
            vin,
            year: parseYear(getVariable(results, "Model Year")),
            make: titleCase(getVariable(results, "Make")),
            model: cleanModel(getVariable(results, "Model")),
            trim: titleCase(getVariable(results, "Trim")),
            engine_cylinders: getVariable(results, "Engine Number of Cylinders"),
            engine_displacement_l: getVariable(results, "Displacement (L)"),
            drive_type: titleCase(getVariable(results, "Drive Type")),
            body_class: titleCase(getVariable(results, "Body Class")),
        };

        console.log("[decode-vin-cache] decoded payload", JSON.stringify(upsertRow));

        if (!upsertRow.make || !upsertRow.model) {
            console.error("[decode-vin-cache] decode returned incomplete vehicle data");
            return jsonResponse({ error: "VIN could not be decoded from NHTSA" }, 422);
        }

        const { error: upsertError } = await supabase
            .from("global_vin_cache_kbuck")
            .upsert(upsertRow, { onConflict: "vin" });

        if (upsertError) {
            console.error("[decode-vin-cache] upsert failed", upsertError.message);
            return jsonResponse({ error: upsertError.message }, 500);
        }

        console.log("[decode-vin-cache] upsert success", vin);
        return jsonResponse(buildResponse(upsertRow, "nhtsa"));
    } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        console.error("[decode-vin-cache] unhandled error", message);
        return jsonResponse({ error: message }, 500);
    }
});
