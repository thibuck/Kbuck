import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function decodeAppleReceipt(jws: string) {
    try {
        const base64Url = jws.split('.')[1];
        const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
        const jsonPayload = decodeURIComponent(atob(base64).split('').map(function(c) {
            return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
        }).join(''));
        return JSON.parse(jsonPayload);
    } catch (e) {
        return null;
    }
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    try {
        const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
        const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

        const authHeader = req.headers.get("Authorization") ?? req.headers.get("authorization");
        if (!authHeader?.startsWith("Bearer ")) {
            return new Response(JSON.stringify({ error: "Missing bearer token" }), {
                status: 401,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        const token = authHeader.slice("Bearer ".length).trim();
        if (!token) {
            return new Response(JSON.stringify({ error: "Missing bearer token" }), {
                status: 401,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        const supabase = createClient(supabaseUrl, supabaseServiceKey);
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);

        if (authError || !user) {
            return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
        }

        const body = await req.json();
        const jws = body.jws;

        if (!jws) {
            return new Response(JSON.stringify({ error: "Missing Apple JWS receipt" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
        }

        const receiptData = decodeAppleReceipt(jws);
        if (!receiptData || !receiptData.productId) {
            return new Response(JSON.stringify({ error: "Invalid receipt" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
        }

        const productID = receiptData.productId;
        let tier = "";
        if (productID === "com.kbuck.platinum.monthly") tier = "platinum";
        else if (productID === "com.kbuck.gold.monthly") tier = "gold";
        else if (productID === "com.kbuck.silver.monthly") tier = "silver";
        else {
            return new Response(JSON.stringify({ error: "Unknown product" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
        }

        const { error: updateError } = await supabase
            .from("profiles_kbuck")
            .update({ plan_tier: tier })
            .eq("id", user.id);

        if (updateError) throw updateError;

        return new Response(JSON.stringify({ success: true, tier: tier }), { 
            headers: { ...corsHeaders, "Content-Type": "application/json" } 
        });

    } catch (err: any) {
        return new Response(JSON.stringify({ error: err.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
});
