// supabase/functions/hpd-pipeline/index.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const HPD_URL =
  "https://www.houstontx.gov/police/auto_dealers_detail/Vehicles_Scheduled_For_Auction.htm";
const NHTSA_BASE = "https://vpic.nhtsa.dot.gov/api/vehicles/decodevin";
const NHTSA_DELAY_MS = 1_500;

// ─── VIN / value cleaners ────────────────────────────────────────────────────

function normalizeVIN(raw: string): string {
  const allowed = new Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789");
  return raw
    .toUpperCase()
    .split("")
    .filter((c) => allowed.has(c))
    .join("");
}

function cleanMake(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

function cleanModel(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .map((token) => {
      const up = token.toUpperCase();
      if (up === "CRV")  return "CR-V";
      if (up === "RAV4") return "RAV4";
      if (up === "F150") return "F-150";
      return token.charAt(0).toUpperCase() + token.slice(1);
    })
    .join(" ");
}

function cleanYear(raw: string): number | null {
  const t = raw.trim();
  const n = parseInt(t, 10);
  if (isNaN(n)) return null;
  if (t.length === 2) return n <= 24 ? 2000 + n : 1900 + n;
  return n >= 1900 && n <= 2100 ? n : null;
}

function cleanValue(v: string | null | undefined): string | null {
  if (!v) return null;
  const t = v.trim();
  if (!t) return null;
  const low = t.toLowerCase();
  if (low === "null" || low === "n/a" || low === "not applicable") return null;
  return t;
}

function cleanAuctionPrice(raw: string): number | null {
  const cleaned = raw.replace(/[^0-9.]/g, "").trim();
  if (!cleaned) return null;
  const n = parseFloat(cleaned);
  return isNaN(n) ? null : n;
}

// ─── HTML helpers ────────────────────────────────────────────────────────────

function stripTags(html: string): string {
  let s = html.replace(/<br\s*\/?>/gi, "\n");
  s = s.replace(/<[^>]+>/gs, "");
  return s
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi,  "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi,  "'")
    .trim();
}

// ─── HPD HTML parser ─────────────────────────────────────────────────────────

interface ParsedVehicle {
  vin:           string;
  auctionLotID:  string | null;
  auctionPrice:  number | null;
}

function canonicalHeader(raw: string): string | null {
  const t = raw.trim().toLowerCase().replace(/\s+/g, " ");
  if (
    (t.includes("date") && t.includes("scheduled")) ||
    t === "date" ||
    t.includes("auction date") ||
    t.includes("date/time") ||
    t.includes("scheduled date")
  ) return "date scheduled";
  if (
    t === "time" ||
    t.includes("start time") ||
    t.includes("begin time") ||
    t.includes("auction time") ||
    t.includes("estimated start time")
  ) return "time";
  if (t.includes("storage") && t.includes("name"))   return "storage lot name";
  if ((t.includes("lot") && t.includes("name")) ||
      (t.includes("location") && t.includes("name"))) return "storage lot name";
  if (t.includes("storage") && t.includes("address")) return "storage lot address";
  if (t.includes("address") ||
     (t.includes("location") && t.includes("address"))) return "storage lot address";
  if (t === "year"  || t.endsWith(" year"))           return "year";
  if (t === "make"  || t.endsWith(" make"))           return "make";
  if (t === "model" || t.endsWith(" model"))          return "model";
  if (t === "vin"   || t.includes("vin"))             return "vin";
  if (t === "plate" || t.includes("plate") || t.includes("tag")) return "plate";
  if (t.includes("price") || t.includes("bid") ||
      t.includes("reserve") || t.includes("value"))   return "price";
  return null;
}

function isVINLike(s: string): boolean {
  const t = s.trim();
  return t.length >= 8 && /^[A-Za-z0-9]{8,}$/.test(t);
}

function parseHPDHTML(html: string): ParsedVehicle[] {
  const rowRegex  = /<tr[^>]*>([\s\S]*?)<\/tr>/gi;
  const cellRegex = /<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi;

  const vehicles: ParsedVehicle[] = [];
  let headerIndex: Record<string, number> = {};

  let rowMatch: RegExpExecArray | null;
  while ((rowMatch = rowRegex.exec(html)) !== null) {
    const rowInner = rowMatch[1];
    const cells: string[] = [];

    cellRegex.lastIndex = 0;
    let cellMatch: RegExpExecArray | null;
    while ((cellMatch = cellRegex.exec(rowInner)) !== null) {
      cells.push(stripTags(cellMatch[1]));
    }

    if (cells.length === 0) continue;

    if (
      cells.length === 1 &&
      cells[0].toLowerCase().trim().startsWith("vehicles scheduled for auction")
    ) continue;

    if (Object.keys(headerIndex).length === 0) {
      const tempMap: Record<string, number> = {};
      cells.forEach((label, i) => {
        const key = canonicalHeader(label);
        if (key) tempMap[key] = i;
      });
      if (["year", "make", "model", "vin"].every((k) => k in tempMap)) {
        headerIndex = tempMap;
        continue;
      }
    }

    if (Object.keys(headerIndex).length > 0) {
      const cell = (key: string): string => {
        const idx = headerIndex[key];
        return idx !== undefined && idx < cells.length ? cells[idx].trim() : "";
      };

      const vin = cell("vin");
      if (!isVINLike(vin)) continue;

      const normalized = normalizeVIN(vin);
      if (normalized.length !== 17) continue;

      const rawPrice = cell("price");
      vehicles.push({
        vin:          normalized,
        auctionLotID: cell("storage lot name") || null,
        auctionPrice: rawPrice ? cleanAuctionPrice(rawPrice) : null,
      });
    }
  }

  return vehicles;
}

// ─── NHTSA decoder ───────────────────────────────────────────────────────────

interface NHTSARow {
  year:                  number | null;
  make:                  string | null;
  model:                 string | null;
  trim:                  string | null;
  body_class:            string | null;
  engine_displacement_l: string | null;
  engine_cylinders:      string | null;
  drive_type:            string | null;
}

async function decodeVIN(vin: string): Promise<NHTSARow> {
  const res = await fetch(`${NHTSA_BASE}/${vin}?format=json`);
  if (res.status === 429) throw new Error("NHTSA rate limited");
  if (!res.ok)            throw new Error(`NHTSA HTTP ${res.status}`);

  const json = await res.json();
  const results: Array<{ Variable: string; Value: string | null }> = json.Results ?? [];

  const get = (name: string): string | null => {
    const norm = name.trim().toLowerCase();
    const row  = results.find((r) => r.Variable.trim().toLowerCase() === norm);
    return cleanValue(row?.Value ?? null);
  };

  const rawMake  = get("Make");
  const rawModel = get("Model");
  const rawYear  = get("Model Year");
  const rawDrive = get("Drive Type");
  
  // Try Trim first, if null try Series
  const rawTrim  = get("Trim") || get("Series");
  const rawBody  = get("Body Class");

  return {
    year:                  rawYear  ? cleanYear(rawYear)  : null,
    make:                  rawMake  ? cleanMake(rawMake)  : null,
    model:
      rawMake && rawModel
        ? cleanModel(rawModel)
        : rawModel
        ? rawModel.charAt(0).toUpperCase() + rawModel.slice(1).toLowerCase()
        : null,
    trim:                  rawTrim  ? cleanMake(rawTrim)  : null,
    body_class:            rawBody  ? cleanMake(rawBody)  : null,
    engine_displacement_l: get("Displacement (L)"),
    engine_cylinders:      get("Engine Number of Cylinders"),
    drive_type:            rawDrive
      ? rawDrive.split(" ").map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join(" ")
      : null,
  };
}

// ─── EPA Fuel Economy API ────────────────────────────────────────────────────

interface EPARow {
  city_mpg: string | null;
  hwy_mpg:  string | null;
}

async function fetchEPA(year: number | null, make: string | null, model: string | null): Promise<EPARow> {
  if (!year || !make || !model) return { city_mpg: null, hwy_mpg: null };

  try {
    const searchUrl = `https://www.fueleconomy.gov/ws/rest/vehicle/menu/options?year=${year}&make=${encodeURIComponent(make)}&model=${encodeURIComponent(model)}`;
    const searchRes = await fetch(searchUrl, { headers: { "Accept": "application/json" } });
    if (!searchRes.ok) return { city_mpg: null, hwy_mpg: null };

    const text = await searchRes.text();
    if (!text) return { city_mpg: null, hwy_mpg: null };

    const searchData = JSON.parse(text);
    let vehicleId = null;

    if (searchData?.menuItem) {
      if (Array.isArray(searchData.menuItem) && searchData.menuItem.length > 0) {
        vehicleId = searchData.menuItem[0].value;
      } else if (searchData.menuItem.value) {
        vehicleId = searchData.menuItem.value;
      }
    }

    if (!vehicleId) return { city_mpg: null, hwy_mpg: null };

    const detailUrl = `https://www.fueleconomy.gov/ws/rest/vehicle/${vehicleId}`;
    const detailRes = await fetch(detailUrl, { headers: { "Accept": "application/json" } });
    if (!detailRes.ok) return { city_mpg: null, hwy_mpg: null };

    const detailData = await detailRes.json();
    return {
      city_mpg: detailData?.city08 ? String(detailData.city08) : null,
      hwy_mpg:  detailData?.highway08 ? String(detailData.highway08) : null,
    };
  } catch (err) {
    console.warn(`⚠️ EPA fetch failed gracefully for ${year} ${make} ${model}`);
    return { city_mpg: null, hwy_mpg: null };
  }
}

// ─── Entry point ─────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

Deno.serve(async (_req: Request) => {
  const supabaseURL    = Deno.env.get("HPD_PIPELINE_URL")!;
  const serviceRoleKey = Deno.env.get("HPD_PIPELINE_SERVICE_ROLE")!;

  const db = createClient(supabaseURL, serviceRoleKey, {
    auth: { persistSession: false },
  });

  try {
    console.log("🌐 Fetching HPD auction page…");
    const hpdRes = await fetch(HPD_URL);
    if (!hpdRes.ok) {
      return new Response(
        JSON.stringify({ error: `HPD fetch failed: ${hpdRes.status}` }),
        { status: 502, headers: { "Content-Type": "application/json" } }
      );
    }
    const html = await hpdRes.text();

    const vehicles = parseHPDHTML(html);
    console.log(`📋 Parsed ${vehicles.length} valid VINs from HPD page`);

    if (vehicles.length === 0) {
      return new Response(
        JSON.stringify({ message: "No vehicles found on HPD page", processed: 0 }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const allVINs = vehicles.map((v) => v.vin);
    const { data: existingRows, error: fetchErr } = await db
      .from("global_vin_cache_kbuck")
      .select("vin")
      .in("vin", allVINs);

    if (fetchErr) throw fetchErr;

    const cachedVINs = new Set((existingRows ?? []).map((r: { vin: string }) => r.vin));
    const pending    = vehicles.filter((v) => !cachedVINs.has(v.vin));

    console.log(`⏭️  Skipping ${cachedVINs.size} already cached — ${pending.length} remaining to decode`);

    if (pending.length === 0) {
      return new Response(
        JSON.stringify({ message: "All VINs already cached", skipped: cachedVINs.size }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    let succeeded = 0;
    let failed    = 0;

    for (let i = 0; i < pending.length; i++) {
      const v = pending[i];
      console.log(`🔎 [${i + 1}/${pending.length}] Decoding VIN ${v.vin}`);

      try {
        const decoded = await decodeVIN(v.vin);
        const epaData = await fetchEPA(decoded.year, decoded.make, decoded.model);

        const row = {
          vin:                   v.vin,
          year:                  decoded.year,
          make:                  decoded.make,
          model:                 decoded.model,
          trim:                  decoded.trim,
          body_class:            decoded.body_class,
          engine_cylinders:      decoded.engine_cylinders,
          engine_displacement_l: decoded.engine_displacement_l,
          drive_type:            decoded.drive_type,
          auction_lot_id:        v.auctionLotID,
          auction_price:         v.auctionPrice,
          city_mpg:              epaData.city_mpg,
          hwy_mpg:               epaData.hwy_mpg,
        };

        const { error } = await db
          .from("global_vin_cache_kbuck")
          .upsert(row, { onConflict: "vin" });

        if (error) throw error;

        console.log(`✅ [${i + 1}/${pending.length}] Upserted ${v.vin} (Trim: ${decoded.trim || 'N/A'}, Body: ${decoded.body_class || 'N/A'})`);
        succeeded++;
      } catch (err) {
        console.error(`🔴 [${i + 1}/${pending.length}] Failed for ${v.vin}: ${err}`);
        failed++;
      }

      if (i < pending.length - 1) {
        await sleep(NHTSA_DELAY_MS);
      }
    }

    console.log(`🏁 Pipeline complete — succeeded: ${succeeded}, failed: ${failed}, skipped: ${cachedVINs.size}`);

    return new Response(
      JSON.stringify({
        total:     vehicles.length,
        skipped:   cachedVINs.size,
        processed: pending.length,
        succeeded,
        failed,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("💥 Unhandled pipeline error:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});