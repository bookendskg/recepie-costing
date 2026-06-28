// One-off generator: builds the mock catalogue via buildSeed() and emits a Supabase
// seed SQL (db/migrations/0009_seed_catalog.sql) with fresh UUIDs + remapped links.
// Run: npx vite-node scripts/genseed.ts
import { writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { buildSeed } from "@/lib/data/seed";

const db = buildSeed();

// Stable mock-id → uuid map (materials + recipes share the namespace; recipe lines
// reference whichever applies).
const idMap = new Map<string, string>();
const U = (id: string): string => {
  let v = idMap.get(id);
  if (!v) { v = randomUUID(); idMap.set(id, v); }
  return v;
};

const q = (s: unknown): string =>
  s === null || s === undefined ? "null" : `'${String(s).replace(/'/g, "''")}'`;
const num = (x: unknown): string => (x === null || x === undefined ? "null" : String(x));
const boolean = (b: unknown): string => (b ? "true" : "false");
const arr = (a: unknown): string =>
  Array.isArray(a) && a.length ? `ARRAY[${a.map(q).join(",")}]::text[]` : "'{}'::text[]";

const out: string[] = [];
out.push(`-- 0009_seed_catalog.sql — catalogue data for the Supabase data layer (Phase 2).`);
out.push(`-- Generated from the mock seed. Run AFTER 0001,0004,0005,0006,0007,0008.`);
out.push(`-- Idempotent (on conflict do nothing). actor columns left null.`);
out.push(`begin;`);

// ── raw_materials ──
out.push(`\n-- raw_materials (${db.raw_materials.length})`);
out.push(
  `insert into public.raw_materials (id, ingredient_name, category, supplier_name, purchase_price, purchase_quantity, purchase_unit, base_unit, cost_per_base_unit, last_price_update, status, notes, created_at) values`,
);
out.push(
  db.raw_materials
    .map(
      (m) =>
        `(${q(U(m.id))}, ${q(m.ingredient_name)}, ${q(m.category)}, ${q(m.supplier_name)}, ${num(m.purchase_price)}, ${num(m.purchase_quantity)}, ${q(m.purchase_unit)}, ${q(m.base_unit)}, ${num(m.cost_per_base_unit)}, ${q(m.last_price_update)}, ${q(m.status)}, ${q(m.notes)}, ${q(m.created_at)})`,
    )
    .join(",\n") + "\non conflict (id) do nothing;",
);

// ── recipes (parent_recipe_id linked afterwards to avoid FK ordering) ──
out.push(`\n-- recipes (${db.recipes.length})`);
out.push(
  `insert into public.recipes (id, recipe_name, category, brand, description, image_url, preparation_time, serving_size, status, total_cost, cost_per_portion, selling_price, packaging_cost, wastage_pct, is_prep, yield_quantity, yield_unit, version_no, method, size_code, size_label, approved_at, rejection_note, created_at, updated_at) values`,
);
out.push(
  db.recipes
    .map(
      (r) =>
        `(${q(U(r.id))}, ${q(r.recipe_name)}, ${q(r.category)}, ${q(r.brand)}, ${q(r.description)}, ${q(r.image_url)}, ${num(r.preparation_time)}, ${num(r.serving_size)}, ${q(r.status)}, ${num(r.total_cost)}, ${num(r.cost_per_portion)}, ${num(r.selling_price)}, ${num(r.packaging_cost)}, ${num(r.wastage_pct)}, ${boolean(r.is_prep)}, ${num(r.yield_quantity)}, ${q(r.yield_unit)}, ${num(r.version_no)}, ${arr(r.method)}, ${q(r.size_code)}, ${q(r.size_label)}, ${q(r.approved_at)}, ${q(r.rejection_note)}, ${q(r.created_at)}, ${q(r.updated_at)})`,
    )
    .join(",\n") + "\non conflict (id) do nothing;",
);

const links = db.recipes.filter((r) => r.parent_recipe_id);
if (links.length) {
  out.push(`\n-- pizza variant → master links`);
  for (const r of links) {
    out.push(`update public.recipes set parent_recipe_id = ${q(U(r.parent_recipe_id!))} where id = ${q(U(r.id))};`);
  }
}

// ── recipe_ingredients ──
out.push(`\n-- recipe_ingredients (${db.recipe_ingredients.length})`);
out.push(
  `insert into public.recipe_ingredients (id, recipe_id, ingredient_id, component_type, quantity_used, unit_used, calculated_cost, sort_order, wastage_override_pct, cut_type) values`,
);
out.push(
  db.recipe_ingredients
    .map(
      (ri) =>
        `(${q(U(ri.id))}, ${q(U(ri.recipe_id))}, ${q(U(ri.ingredient_id))}, ${q(ri.component_type)}, ${num(ri.quantity_used)}, ${q(ri.unit_used)}, ${num(ri.calculated_cost)}, ${num(ri.sort_order)}, ${num(ri.wastage_override_pct)}, ${q(ri.cut_type)})`,
    )
    .join(",\n") + "\non conflict (id) do nothing;",
);

// ── ingredient_yields ──
if (db.ingredient_yields.length) {
  out.push(`\n-- ingredient_yields (${db.ingredient_yields.length})`);
  out.push(
    `insert into public.ingredient_yields (id, ingredient_id, purchase_cost, purchase_quantity, purchase_unit, raw_quantity, raw_unit, wastage_quantity, wastage_unit, usable_quantity, wastage_percentage, yield_percentage, original_unit_cost, yield_adjusted_unit_cost, effective_from, notes, created_at, updated_at) values`,
  );
  out.push(
    db.ingredient_yields
      .map(
        (y) =>
          `(${q(U(y.id))}, ${q(U(y.ingredient_id))}, ${num(y.purchase_cost)}, ${num(y.purchase_quantity)}, ${q(y.purchase_unit)}, ${num(y.raw_quantity)}, ${q(y.raw_unit)}, ${num(y.wastage_quantity)}, ${q(y.wastage_unit)}, ${num(y.usable_quantity)}, ${num(y.wastage_percentage)}, ${num(y.yield_percentage)}, ${num(y.original_unit_cost)}, ${num(y.yield_adjusted_unit_cost)}, ${q(y.effective_from)}, ${q(y.notes)}, ${q(y.created_at)}, ${q(y.updated_at)})`,
      )
      .join(",\n") + "\non conflict (id) do nothing;",
  );
}

out.push(`\ncommit;`);

writeFileSync("db/migrations/0009_seed_catalog.sql", out.join("\n"), "utf8");
console.log(
  `Wrote db/migrations/0009_seed_catalog.sql — materials=${db.raw_materials.length} recipes=${db.recipes.length} lines=${db.recipe_ingredients.length} yields=${db.ingredient_yields.length}`,
);
