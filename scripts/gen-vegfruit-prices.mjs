// Generate src/lib/data/vegFruitPrices.ts from assets/Surat_VegFruits_PriceMaster.xlsx.
// Produces a name→₹/g price map (overrides the older costing book for produce) and
// the item list (so genuinely-new produce can be added as raw materials).
// Run: node scripts/gen-vegfruit-prices.mjs
import * as XLSX from "xlsx";
import { readFileSync, writeFileSync } from "node:fs";

const wb = XLSX.read(readFileSync("assets/Surat_VegFruits_PriceMaster.xlsx"), { type: "buffer", raw: true });
const rows = XLSX.utils.sheet_to_json(wb.Sheets["Price Master"], { header: 1, defval: null, blankrows: false });

const norm = (s) => String(s).toLowerCase().replace(/\s+/g, " ").trim();
const num = (v) => {
  if (v === null || v === undefined) return null;
  const n = parseFloat(String(v).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : null;
};

const map = {};
const items = [];
for (let i = 1; i < rows.length; i++) {
  const [name, category, , pack, price, costBase] = rows[i];
  if (name == null) continue;
  const nm = String(name).replace(/\s+/g, " ").trim();
  const packG = num(pack) || 1000;
  const perGram = num(costBase) ?? (num(price) != null ? num(price) / packG : null);
  if (perGram == null || perGram < 0) continue;
  map[norm(nm)] = perGram;
  items.push({ name: nm, category: String(category ?? "Vegetables").trim(), perGram });
}

const header = `// AUTO-GENERATED from assets/Surat_VegFruits_PriceMaster.xlsx (sheet "Price Master").
// Regenerate with: node scripts/gen-vegfruit-prices.mjs  — do not edit by hand.
// ₹ per gram for produce; this is the authoritative produce price (overrides the
// older costing book for the items it lists).

/** Normalised produce name → ₹ per gram. */
export const VEG_FRUIT_PRICES: Record<string, number> = ${JSON.stringify(map, null, 2)};

export interface VegFruitItem { name: string; category: string; perGram: number }

/** Full produce list — used to add any item not already in the catalogue. */
export const VEG_FRUIT_ITEMS: VegFruitItem[] = ${JSON.stringify(items, null, 2)};
`;

writeFileSync("src/lib/data/vegFruitPrices.ts", header);
console.log(`Wrote ${items.length} produce prices to src/lib/data/vegFruitPrices.ts`);
console.log("Categories:", [...new Set(items.map((i) => i.category))].join(", "));
