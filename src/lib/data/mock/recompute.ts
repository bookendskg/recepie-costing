// Shared recompute + audit helpers used by the material and recipe repos.
// Centralises the cost roll-up (PRD §4.5) including sub-recipe (in-house prep)
// components, so ingredient price changes and recipe edits stay consistent.

import { calculateIngredientCost, prepUnitCostFrom, round2 } from "../../costing";
import { canConvert, getConversionFactor } from "../../units";
import { activeYield, effectiveCostPerBaseUnit } from "../../yield";
import type {
  AuditAction,
  AuditEntityType,
  AuditLog,
  RawMaterial,
  Recipe,
} from "../types";
import { type MockDb, nowISO, uid } from "./db";

export function findMaterial(db: MockDb, id: string): RawMaterial | undefined {
  return db.raw_materials.find((m) => m.id === id);
}

/** A prep recipe's cost per unit of its yield (pre-wastage; ₹/gram). */
export function prepUnitCost(recipe: Recipe): number {
  return prepUnitCostFrom(recipe.total_cost ?? 0, recipe.yield_quantity, recipe.wastage_pct ?? 0);
}

/** Cost of one recipe line — a raw material or a sub-recipe (prep). */
function lineCost(
  db: MockDb,
  line: { ingredient_id: string; component_type: string; quantity_used: number; unit_used: string; wastage_override_pct?: number | null },
): number | null {
  if (line.component_type === "recipe") {
    const sub = db.recipes.find((r) => r.id === line.ingredient_id);
    // Unconvertible unit → unknown cost (never silently assume factor 1).
    if (!sub || !canConvert(line.unit_used, sub.yield_unit)) return null;
    const factor = getConversionFactor(line.unit_used, sub.yield_unit);
    return round2(prepUnitCost(sub) * line.quantity_used * factor);
  }
  const m = findMaterial(db, line.ingredient_id);
  // Guard the unit pair so an invalid conversion can never throw mid-recompute.
  if (!m || !canConvert(line.unit_used, m.base_unit)) return null;
  // §9: use the yield-adjusted rate when yield data exists, else the purchase rate.
  const yieldRec = activeYield(db.ingredient_yields, m.id);
  const rate = effectiveCostPerBaseUnit(m.cost_per_base_unit, yieldRec, line.wastage_override_pct);
  if (rate === null) return null; // no price and no yield
  return calculateIngredientCost(rate, line.quantity_used, line.unit_used, m.base_unit);
}

/**
 * Recompute every line cost + the total/per-portion for one recipe. Writes a
 * recipe_cost_history row when the total changed. Returns whether it changed.
 */
export function recomputeRecipe(
  db: MockDb,
  recipeId: string,
  actorId: string | null,
  reason: string,
): boolean {
  const recipe = db.recipes.find((r) => r.id === recipeId);
  if (!recipe) return false;

  const lines = db.recipe_ingredients.filter((ri) => ri.recipe_id === recipeId);
  let rawTotal = 0;
  for (const line of lines) {
    const cost = lineCost(db, line);
    line.calculated_cost = cost;
    if (cost !== null) rawTotal += cost;
  }

  // Add wastage on top of the raw ingredient cost (compounds through preps).
  const newTotal = round2(rawTotal * (1 + (recipe.wastage_pct ?? 0) / 100));
  const newPerPortion = recipe.serving_size > 0 ? round2(newTotal / recipe.serving_size) : 0;
  const oldTotal = recipe.total_cost ?? 0;
  const changed = newTotal !== oldTotal;

  if (changed) {
    db.recipe_cost_history.push({
      id: uid(),
      recipe_id: recipeId,
      old_total_cost: recipe.total_cost,
      new_total_cost: newTotal,
      old_cost_per_portion: recipe.cost_per_portion,
      new_cost_per_portion: newPerPortion,
      change_reason: reason,
      changed_by: actorId,
      changed_at: nowISO(),
    });
  }

  recipe.total_cost = newTotal;
  recipe.cost_per_portion = newPerPortion;
  recipe.updated_at = nowISO();
  return changed;
}

/**
 * Recompute the given recipes and propagate up through any recipe that uses
 * them as a sub-recipe component. Cycle-guarded so malformed nesting can't loop.
 */
export function recomputeAndPropagate(
  db: MockDb,
  seedRecipeIds: string[],
  actorId: string | null,
  reason: string,
): void {
  const queue = [...new Set(seedRecipeIds)];
  const guard = new Map<string, number>();
  while (queue.length) {
    const id = queue.shift()!;
    const count = guard.get(id) ?? 0;
    if (count > 6) continue; // runaway / cycle guard
    guard.set(id, count + 1);
    const changed = recomputeRecipe(db, id, actorId, reason);
    if (changed) {
      const parents = db.recipe_ingredients
        .filter((ri) => ri.component_type === "recipe" && ri.ingredient_id === id)
        .map((ri) => ri.recipe_id);
      for (const p of parents) queue.push(p);
    }
  }
}

/** Recompute every recipe that uses a given ingredient (the price cascade). */
export function cascadeFromMaterial(
  db: MockDb,
  ingredientId: string,
  actorId: string | null,
  reason: string,
): void {
  const affected = [
    ...new Set(
      db.recipe_ingredients
        .filter((ri) => ri.component_type !== "recipe" && ri.ingredient_id === ingredientId)
        .map((ri) => ri.recipe_id),
    ),
  ];
  recomputeAndPropagate(db, affected, actorId, reason);
}

export function recordAudit(
  db: MockDb,
  entry: {
    entity_type: AuditEntityType;
    entity_id: string;
    action: AuditAction;
    old_values?: unknown;
    new_values?: unknown;
    performed_by: string | null;
    notes?: string | null;
  },
): AuditLog {
  const log: AuditLog = {
    id: uid(),
    entity_type: entry.entity_type,
    entity_id: entry.entity_id,
    action: entry.action,
    old_values: entry.old_values ?? null,
    new_values: entry.new_values ?? null,
    performed_by: entry.performed_by,
    performed_at: nowISO(),
    notes: entry.notes ?? null,
  };
  db.audit_logs.push(log);
  return log;
}
