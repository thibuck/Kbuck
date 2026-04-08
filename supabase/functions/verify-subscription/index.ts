import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { compactVerify, importX509 } from "npm:jose";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const APPLE_ROOT_CA_FINGERPRINTS = new Set([
    "b52cb02fd567e0359fe8fa4d4c41037970fe01b0c9c5f5200fa0cc9d82b58a3e",
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
]);

const PRODUCT_TIER_MAP: Record<string, string> = {
    "com.kbuck.platinum.monthly": "platinum",
    "com.kbuck.gold.monthly": "gold",
    "com.kbuck.silver.monthly": "silver",
};

function derToPem(base64Der: string): string {
    const lines = base64Der.match(/.{1,64}/g)?.join("\n") ?? base64Der;
    return `-----BEGIN CERTIFICATE-----\n${lines}\n-----END CERTIFICATE-----`;
}

async function certFingerprint(base64Der: string): Promise<string> {
    const der = Uint8Array.from(atob(base64Der), (c) => c.charCodeAt(0));
    const hash = await crypto.subtle.digest("SHA-256", der);
    return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function verifyAppleJWS(jws: string): Promise<Record<string, unknown>> {
    const [rawHeader] = jws.split(".");
    const paddedHeader = rawHeader + "=".repeat((4 - (rawHeader.length % 4)) % 4);
    const headerJson = new TextDecoder().decode(Uint8Array.from(atob(paddedHeader.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)));
    const header = JSON.parse(headerJson);
    const x5c: string[] | undefined = header.x5c;
    if (!x5c || x5c.length < 2) throw new Error("JWS header missing x5c chain");
    const rootFingerprint = await certFingerprint(x5c[x5c.length - 1]);
    if (!APPLE_ROOT_CA_FINGERPRINTS.has(rootFingerprint)) throw new Error(`Untrusted root: ${rootFingerprint}`);
    const leafKey = await importX509(derToPem(x5c[0]), "ES256");
    const { payload } = await compactVerify(jws, leafKey);
    return JSON.parse(new TextDecoder().decode(payload));
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
        return new Response(JSON.stringify({ error: "No Auth" }), { status: 401, headers: corsHeaders });
    }
    const token = authHeader.slice(7);

    try {
        const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);
        if (authError || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

        // ── 2.5. BUSCAR ESTADO VIP (NUEVO) ──
        const { data: profile } = await supabase
            .from("profiles_kbuck")
            .select("is_vip_override, plan_tier")
            .eq("id", user.id)
            .single();

        if (profile?.is_vip_override) {
            return new Response(
                JSON.stringify({ success: true, message: "VIP Bypass Active", tier: profile.plan_tier }),
                { headers: { ...corsHeaders, "Content-Type": "application/json" } }
            );
        }

        const body = await req.json();
        const jws = body.jws;
        if (!jws) return new Response(JSON.stringify({ error: "Missing JWS" }), { status: 400, headers: corsHeaders });

        const applePayload = await verifyAppleJWS(jws);
        const planTier = PRODUCT_TIER_MAP[applePayload.productId as string];
        let nextRenewalDate = applePayload.expiresDate ? new Date(applePayload.expiresDate as number).toISOString() : null;

        const { error: updateError } = await supabase
            .from("profiles_kbuck")
            .update({ plan_tier: planTier, next_renewal_date: nextRenewalDate })
            .eq("id", user.id);

        if (updateError) throw updateError;

        return new Response(JSON.stringify({ success: true, tier: planTier }), { headers: corsHeaders });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), { status: 500, headers: corsHeaders });
    }
});