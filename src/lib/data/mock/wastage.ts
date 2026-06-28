import type { Brand, Department, RawMaterial, Recipe, WastageEntry, WastageType } from "../types";
import { round2 } from "../../costing";
import { activeYield, effectiveCostPerBaseUnit } from "../../yield";
import { delay, getDb, mutate, nowISO, uid } from "./db";
import { recordAudit } from "./recompute";

export interface WastageInput {
  wastage_date: string;
  brand: Brand;
  outlet_id: string;
  wastage_type: WastageType;
  item_type: "ingredient" | "recipe";
  ingredient_id: string | null;
  recipe_id: string | null;
  quantity: number;
  unit: string;
  unit_cost: number;
  reason?: string | null;
  department: Department;
  shift?: string | null;
  done_by?: string | null;
  approved_by?: string | null;
  notes?: string | null;
}

/**
 * §13 applicable unit cost for a wasted item:
 *  1. finished recipe  → recipe cost per portion
 *  2. ingredient w/ yield → yield-adjusted cost per base unit
 *  3. ingredient (no yield) → standard cost per base unit
 */
export function applicableUnitCost(
  itemType: "ingredient" | "recipe",
  id: string | null,
  materials: RawMaterial[],
  recipes: Recipe[],
  yields: import("../types").IngredientYield[],
): number {
  if (!id) return 0;
  if (itemType === "recipe") {
    return recipes.find((r) => r.id === id)?.cost_per_portion ?? 0;
  }
  const m = materials.find((x) => x.id === id);
  if (!m) return 0;
  return effectiveCostPerBaseUnit(m.cost_per_base_unit, activeYield(yields, id)) ?? 0;
}

export const wastageRepo = {
  async list(): Promise<WastageEntry[]> {
    return delay([...getDb().wastage_entries].sort((a, b) => b.wastage_date.localeCompare(a.wastage_date)));
  },

  async getById(id: string): Promise<WastageEntry | null> {
    return delay(getDb().wastage_entries.find((w) => w.id === id) ?? null);
  },

  async create(input: WastageInput, actorId: string): Promise<WastageEntry> {
    return delay(
      mutate((db) => {
        const entry: WastageEntry = {
          id: uid(),
          wastage_date: input.wastage_date,
          brand: input.brand,
          outlet_id: input.outlet_id,
          wastage_type: input.wastage_type,
          item_type: input.item_type,
          ingredient_id: input.item_type === "ingredient" ? input.ingredient_id : null,
          recipe_id: input.item_type === "recipe" ? input.recipe_id : null,
          quantity: input.quantity,
          unit: input.unit,
          unit_cost: input.unit_cost,
          total_cost: round2(input.quantity * input.unit_cost),
          reason: input.reason ?? null,
          department: input.department,
          shift: input.shift ?? null,
          done_by: input.done_by ?? null,
          entered_by: actorId,
          approved_by: input.approved_by || null,
          notes: input.notes ?? null,
          created_at: nowISO(),
          updated_at: nowISO(),
        };
        db.wastage_entries.push(entry);
        recordAudit(db, {
          entity_type: input.item_type === "recipe" ? "recipe" : "ingredient",
          entity_id: (input.recipe_id || input.ingredient_id) ?? entry.id,
          action: "create",
          new_values: { total_cost: entry.total_cost, outlet: entry.outlet_id },
          performed_by: actorId,
          notes: `Recorded wastage ₹${entry.total_cost} (${entry.wastage_type})`,
        });
        return entry;
      }),
    );
  },

  async update(id: string, input: WastageInput, actorId: string): Promise<WastageEntry> {
    return delay(
      mutate((db) => {
        const w = db.wastage_entries.find((x) => x.id === id);
        if (!w) throw new Error("Wastage entry not found");
        const before = { total_cost: w.total_cost };
        Object.assign(w, {
          wastage_date: input.wastage_date,
          brand: input.brand,
          outlet_id: input.outlet_id,
          wastage_type: input.wastage_type,
          item_type: input.item_type,
          ingredient_id: input.item_type === "ingredient" ? input.ingredient_id : null,
          recipe_id: input.item_type === "recipe" ? input.recipe_id : null,
          quantity: input.quantity,
          unit: input.unit,
          unit_cost: input.unit_cost,
          total_cost: round2(input.quantity * input.unit_cost),
          reason: input.reason ?? null,
          department: input.department,
          shift: input.shift ?? null,
          done_by: input.done_by ?? null,
          approved_by: input.approved_by || null,
          notes: input.notes ?? null,
          updated_at: nowISO(),
        });
        recordAudit(db, {
          entity_type: w.item_type === "recipe" ? "recipe" : "ingredient",
          entity_id: (w.recipe_id || w.ingredient_id) ?? w.id,
          action: "update",
          old_values: before,
          new_values: { total_cost: w.total_cost },
          performed_by: actorId,
          notes: `Updated wastage entry`,
        });
        return w;
      }),
    );
  },

  async remove(id: string, actorId: string): Promise<void> {
    return delay(
      mutate((db) => {
        const w = db.wastage_entries.find((x) => x.id === id);
        if (!w) return;
        db.wastage_entries = db.wastage_entries.filter((x) => x.id !== id);
        recordAudit(db, {
          entity_type: w.item_type === "recipe" ? "recipe" : "ingredient",
          entity_id: (w.recipe_id || w.ingredient_id) ?? w.id,
          action: "delete",
          performed_by: actorId,
          notes: "Deleted wastage entry",
        });
      }),
    );
  },
};
