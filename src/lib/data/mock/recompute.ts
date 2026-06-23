// Shared recompute + audit helpers used by the material and recipe repos.
// Centralises the "price cascade" (PRD §4.5) and recipe cost roll-up so both
// ingredient price updates and recipe edits stay consistent.

import { calculateIngredientCost, round2 } from "../../costing";
import type {
  AuditAction,
  AuditEntityType,
  AuditLog,
  RawMaterial,
} from "../types";
import { type MockDb, nowISO, uid } from "./db";

export function findMaterial(db: MockDb, id: string): RawMaterial | undefined {
  return db.raw_materials.find((m) => m.id === id);
}

/**
 * Recompute every line cost + the total/per-portion for one recipe from the
 * current raw material prices. Writes a recipe_cost_history row when the total
 * changed. Returns the percentage change in total cost.
 */
export function recomputeRecipe(
  db: MockDb,
  recipeId: string,
  actorId: string | null,
  reason: string,
): number {
  const recipe = db.recipes.find((r) => r.id === recipeId);
  if (!recipe) return 0;

  const lines = db.recipe_ingredients.filter((ri) => ri.recipe_id === recipeId);
  let total = 0;
  for (const line of lines) {
    const m = findMaterial(db, line.ingredient_id);
    if (!m || m.cost_per_base_unit === null) {
      line.calculated_cost = null;
      continue;
    }
    const cost = calculateIngredientCost(
      m.cost_per_base_unit,
      line.quantity_used,
      line.unit_used,
      m.base_unit,
    );
    line.calculated_cost = cost;
    total += cost;
  }

  const newTotal = round2(total);
  const newPerPortion =
    recipe.serving_size > 0 ? round2(newTotal / recipe.serving_size) : 0;

  const oldTotal = recipe.total_cost ?? 0;

  if (newTotal !== oldTotal) {
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

  if (oldTotal === 0) return newTotal === 0 ? 0 : 100;
  return round2(((newTotal - oldTotal) / oldTotal) * 100);
}

/** Recompute every recipe that uses a given ingredient (the price cascade). */
export function cascadeFromMaterial(
  db: MockDb,
  ingredientId: string,
  actorId: string | null,
  reason: string,
): void {
  const affected = new Set(
    db.recipe_ingredients
      .filter((ri) => ri.ingredient_id === ingredientId)
      .map((ri) => ri.recipe_id),
  );
  for (const recipeId of affected) {
    recomputeRecipe(db, recipeId, actorId, reason);
  }
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
