// Supabase-backed wastage repository (Phase 2). Mirrors the mock `wastageRepo`
// interface 1:1 so feature code is unchanged — selection happens in
// src/lib/data/index.ts by whether Supabase is configured. Backed by the
// `public.wastage_entries` table (db/migrations/0006 + 0008); access is enforced
// by the outlet-scoped RLS policies in 0008.
//
// Wastage has NO cost cascade — recording a wasted item does not change any
// material price or recipe cost, so we never call cascadeMaterial/recomputeRecipes.
// We mirror the mock's derived field exactly: total_cost = round2(quantity * unit_cost).

import type { WastageEntry } from "../types";
import { round2 } from "../../costing";
import type { WastageInput } from "../mock/wastage";
import { applicableUnitCost } from "../mock/wastage";
import { sb, fail, audit } from "./helpers";

// Re-export the pure §13 helper unchanged so index.ts can export it from either
// repo. It reads materials/recipes/yields the caller already has in memory; it
// performs no IO and so is identical in both backends.
export { applicableUnitCost };
export type { WastageInput };

export const supabaseWastageRepo = {
  async list(): Promise<WastageEntry[]> {
    const { data, error } = await sb()
      .from("wastage_entries")
      .select("*")
      .order("wastage_date", { ascending: false });
    if (error) fail("Load wastage", error.message);
    return (data ?? []) as WastageEntry[];
  },

  async getById(id: string): Promise<WastageEntry | null> {
    const { data, error } = await sb()
      .from("wastage_entries")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (error) fail("Load wastage entry", error.message);
    return (data as WastageEntry | null) ?? null;
  },

  async create(input: WastageInput, actorId: string): Promise<WastageEntry> {
    const total_cost = round2(input.quantity * input.unit_cost);
    const row = {
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
      total_cost,
      reason: input.reason ?? null,
      department: input.department,
      shift: input.shift ?? null,
      done_by: input.done_by ?? null,
      entered_by: actorId,
      approved_by: input.approved_by || null,
      notes: input.notes ?? null,
    };
    const { data, error } = await sb()
      .from("wastage_entries")
      .insert(row)
      .select("*")
      .single();
    if (error) fail("Record wastage", error.message);
    const entry = data as WastageEntry;
    await audit({
      entity_type: input.item_type === "recipe" ? "recipe" : "ingredient",
      entity_id: (input.recipe_id || input.ingredient_id) ?? entry.id,
      action: "create",
      new_values: { total_cost: entry.total_cost, outlet: entry.outlet_id },
      performed_by: actorId,
      notes: `Recorded wastage ₹${entry.total_cost} (${entry.wastage_type})`,
    });
    return entry;
  },

  async update(id: string, input: WastageInput, actorId: string): Promise<WastageEntry> {
    // Capture the prior total_cost for the audit old_values (mirrors the mock).
    const { data: prior, error: priorErr } = await sb()
      .from("wastage_entries")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (priorErr) fail("Load wastage entry", priorErr.message);
    if (!prior) fail("Update wastage", "Wastage entry not found");
    const before = { total_cost: (prior as WastageEntry).total_cost };

    const total_cost = round2(input.quantity * input.unit_cost);
    const row = {
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
      total_cost,
      reason: input.reason ?? null,
      department: input.department,
      shift: input.shift ?? null,
      done_by: input.done_by ?? null,
      approved_by: input.approved_by || null,
      notes: input.notes ?? null,
      updated_at: new Date().toISOString(),
    };
    const { data, error } = await sb()
      .from("wastage_entries")
      .update(row)
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Update wastage", error.message);
    const entry = data as WastageEntry;
    await audit({
      entity_type: entry.item_type === "recipe" ? "recipe" : "ingredient",
      entity_id: (entry.recipe_id || entry.ingredient_id) ?? entry.id,
      action: "update",
      old_values: before,
      new_values: { total_cost: entry.total_cost },
      performed_by: actorId,
      notes: `Updated wastage entry`,
    });
    return entry;
  },

  async remove(id: string, actorId: string): Promise<void> {
    // Read first so the audit row carries the same entity reference as the mock,
    // and so we can no-op cleanly when the entry is already gone.
    const { data: existing, error: readErr } = await sb()
      .from("wastage_entries")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (readErr) fail("Load wastage entry", readErr.message);
    if (!existing) return;
    const w = existing as WastageEntry;

    const { error } = await sb().from("wastage_entries").delete().eq("id", id);
    if (error) fail("Delete wastage", error.message);
    await audit({
      entity_type: w.item_type === "recipe" ? "recipe" : "ingredient",
      entity_id: (w.recipe_id || w.ingredient_id) ?? w.id,
      action: "delete",
      performed_by: actorId,
      notes: "Deleted wastage entry",
    });
  },
};
