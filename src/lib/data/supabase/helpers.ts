// Shared plumbing for the Supabase data repos (Phase 2). The cost cascade reuses
// the SAME verified recompute logic as the mock layer (src/lib/data/mock/recompute):
// load the costing-relevant rows into a MockDb-shaped snapshot, recompute on it,
// then persist only the rows whose cost actually changed.

import { supabase } from "@/lib/supabase/client";
import type { MockDb } from "../mock/db";
import { cascadeFromMaterial, recomputeAndPropagate } from "../mock/recompute";

/** Non-null Supabase client (Phase 2 repos are only selected when configured). */
export function sb() {
  if (!supabase) throw new Error("Supabase is not configured");
  return supabase;
}

export function fail(context: string, message?: string): never {
  throw new Error(message || `${context} failed`);
}

const EMPTY_DB: MockDb = {
  users: [], raw_materials: [], recipes: [], recipe_ingredients: [],
  recipe_cost_history: [], ingredient_price_history: [], ingredient_yields: [],
  wastage_entries: [], recipe_versions: [], user_recipe_views: [], audit_logs: [],
  system_settings: [],
};

/** Load the costing slice (materials + recipes + lines + yields) as a MockDb. */
export async function loadCostingDb(): Promise<MockDb> {
  const c = sb();
  const [mats, recs, lines, yields] = await Promise.all([
    c.from("raw_materials").select("*"),
    c.from("recipes").select("*"),
    c.from("recipe_ingredients").select("*"),
    c.from("ingredient_yields").select("*"),
  ]);
  for (const r of [mats, recs, lines, yields]) if (r.error) fail("Load costing data", r.error.message);
  return {
    ...EMPTY_DB,
    raw_materials: (mats.data ?? []) as MockDb["raw_materials"],
    recipes: (recs.data ?? []) as MockDb["recipes"],
    recipe_ingredients: (lines.data ?? []) as MockDb["recipe_ingredients"],
    ingredient_yields: (yields.data ?? []) as MockDb["ingredient_yields"],
  };
}

function snapshotBefore(db: MockDb) {
  return {
    recipes: new Map(db.recipes.map((r) => [r.id, { tc: r.total_cost, cpp: r.cost_per_portion }])),
    lines: new Map(db.recipe_ingredients.map((ri) => [ri.id, ri.calculated_cost])),
  };
}

async function persistCostChanges(
  before: ReturnType<typeof snapshotBefore>,
  db: MockDb,
): Promise<void> {
  const c = sb();
  const changedRecipes = db.recipes.filter((r) => {
    const b = before.recipes.get(r.id);
    return b && (b.tc !== r.total_cost || b.cpp !== r.cost_per_portion);
  });
  for (const r of changedRecipes) {
    const { error } = await c
      .from("recipes")
      .update({ total_cost: r.total_cost, cost_per_portion: r.cost_per_portion, updated_at: r.updated_at })
      .eq("id", r.id);
    if (error) fail("Update recipe cost", error.message);
  }
  const changedLines = db.recipe_ingredients.filter((ri) => before.lines.get(ri.id) !== ri.calculated_cost);
  for (const ri of changedLines) {
    const { error } = await c
      .from("recipe_ingredients")
      .update({ calculated_cost: ri.calculated_cost })
      .eq("id", ri.id);
    if (error) fail("Update line cost", error.message);
  }
}

/** Recompute + persist every recipe that uses a material (the price cascade). */
export async function cascadeMaterial(ingredientId: string, actorId: string, reason: string): Promise<void> {
  const db = await loadCostingDb();
  const before = snapshotBefore(db);
  cascadeFromMaterial(db, ingredientId, actorId, reason);
  await persistCostChanges(before, db);
}

/** Recompute + persist specific recipes (after a recipe edit or yield change). */
export async function recomputeRecipes(seedRecipeIds: string[], actorId: string, reason: string): Promise<void> {
  const db = await loadCostingDb();
  const before = snapshotBefore(db);
  recomputeAndPropagate(db, seedRecipeIds, actorId, reason);
  await persistCostChanges(before, db);
}

/** Append an audit row (best-effort; never blocks the main mutation). */
export async function audit(entry: {
  entity_type: string;
  entity_id: string;
  action: string;
  old_values?: unknown;
  new_values?: unknown;
  performed_by: string | null;
  notes?: string | null;
}): Promise<void> {
  try {
    await sb().from("audit_logs").insert({
      entity_type: entry.entity_type,
      entity_id: entry.entity_id,
      action: entry.action,
      old_values: entry.old_values ?? null,
      new_values: entry.new_values ?? null,
      performed_by: entry.performed_by,
      notes: entry.notes ?? null,
    });
  } catch (e) {
    console.error("Audit insert failed:", e);
  }
}
