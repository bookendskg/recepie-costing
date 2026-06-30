// Generate src/lib/data/pankilPrices.ts from assets/Pankil pricing.xls.
// Pankil is the authoritative general master price list (food + non-food). We take
// the FOOD, weight/volume-priced items: a name→₹/g override map (PANKIL_PRICES) and
// the food item list (PANKIL_ITEMS) to add any not already in the catalogue.
// Run: node scripts/gen-pankil-prices.mjs
import * as XLSX from "xlsx";
import { readFileSync, writeFileSync } from "node:fs";

const wb = XLSX.read(readFileSync("assets/Pankil pricing.xls"), { type: "buffer" });
const rows = XLSX.utils.sheet_to_json(wb.Sheets["Price Master"], { header: 1, defval: null, blankrows: false });

const norm = (s) => String(s).toLowerCase().replace(/\s+/g, " ").trim();
const num = (v) => {
  if (v === null || v === undefined || v === "") return null;
  const n = parseFloat(String(v).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : null;
};
const round = (n) => parseFloat(n.toFixed(5));

// Non-food categories never become recipe ingredients.
const NON_FOOD = new Set(["Housekeeping", "Packing Materials", "Stationery", "Kitchen Equipment", "Assets"]);
const WEIGHT = new Set(["kg", "g", "gm", "gram", "grams"]);
const VOL = new Set(["ltr", "l", "ml", "litre", "liter"]);

const map = {};
const items = [];
let skippedPcs = 0, noPrice = 0;
for (let i = 1; i < rows.length; i++) {
  const [name, category, unit, pack, price] = rows[i];
  if (name == null) continue;
  const nm = String(name).replace(/\s+/g, " ").trim();
  const cat = String(category ?? "Others").trim();
  const u = String(unit ?? "").toLowerCase().trim();
  const pk = num(pack) || 1;
  const pr = num(price);
  if (pr == null) { noPrice++; continue; }
  let perGram = null;
  if (WEIGHT.has(u)) perGram = u === "kg" ? pr / (pk * 1000) : pr / pk;
  else if (VOL.has(u)) perGram = u === "ml" ? pr / pk : pr / (pk * 1000); // ltr/l → per ml≈g
  else { skippedPcs++; continue; } // pcs etc. — not gram-based (packing/assets/eggs)
  if (perGram == null || perGram < 0) continue;
  map[norm(nm)] = round(perGram);
  if (!NON_FOOD.has(cat)) items.push({ name: nm, category: cat, perGram: round(perGram) });
}

const header = `// AUTO-GENERATED from assets/Pankil pricing.xls (sheet "Price Master").
// Regenerate with: node scripts/gen-pankil-prices.mjs  — do not edit by hand.
// Authoritative general master price list. ₹ per gram for weight/volume-priced items
// (pcs items — packing/assets/eggs — are excluded as they are not gram-based).

/** Normalised ingredient name → ₹ per gram (food + non-food weight/volume items). */
export const PANKIL_PRICES: Record<string, number> = ${JSON.stringify(map, null, 2)};

export interface PankilItem { name: string; category: string; perGram: number }

/** FOOD items only — used to add any not already in the catalogue. */
export const PANKIL_ITEMS: PankilItem[] = ${JSON.stringify(items, null, 2)};
`;

writeFileSync("src/lib/data/pankilPrices.ts", header);
console.log(`Wrote ${Object.keys(map).length} Pankil prices (${items.length} food items) — skipped ${skippedPcs} pcs, ${noPrice} no-price`);
