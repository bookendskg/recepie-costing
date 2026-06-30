// Generate src/lib/data/produceAliases.ts from the verified reconciliation
// (scripts/.produce-reconcile.json). Maps recipe-ingredient spelling/prep variants
// to the canonical produce price-master name, so e.g. "Alfanso mango" prices as
// "Alphonso Mango". Only confidence ≥ 0.6 (verifier-confirmed) matches are baked in;
// low-confidence ones are left for manual review.
// Run: node scripts/gen-produce-aliases.mjs
import { readFileSync, writeFileSync } from "node:fs";

const d = JSON.parse(readFileSync("scripts/.produce-reconcile.json", "utf8"));
const norm = (s) => String(s).toLowerCase().replace(/\s+/g, " ").trim();

const map = {};
const low = [];
for (const r of d.reconcile) {
  if (!r.match) continue;
  if (r.confidence >= 0.6) map[norm(r.ingredient)] = r.match;
  else low.push({ ingredient: r.ingredient, match: r.match, confidence: r.confidence });
}

const header = `// AUTO-GENERATED from the produce reconciliation (scripts/gen-produce-aliases.mjs).
// recipe-ingredient name (normalised) → canonical produce price-master name.
// Only verifier-confirmed matches (confidence ≥ 0.6) are included.

export const PRODUCE_ALIASES: Record<string, string> = ${JSON.stringify(map, null, 2)};
`;

writeFileSync("src/lib/data/produceAliases.ts", header);
console.log(`Wrote ${Object.keys(map).length} produce aliases (skipped ${low.length} low-confidence: ${low.map((l) => l.ingredient).join(", ")})`);
