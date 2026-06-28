// Supabase-backed ingredient-yields repository (Phase 2). Mirrors the mock
// `yieldsRepo` interface 1:1 so feature code is unchanged — selection happens in
// src/lib/data/index.ts by whether Supabase is configured. Backed by the
// `public.ingredient_yields` table (db/migrations/0005 + 0008 RLS).
//
// Derived fields (usable qty, %s, adjusted unit cost) are computed by the SAME
// pure engine the mock uses (src/lib/yield.ts → computeYield); we do NOT
// re-derive cost math here. After any write, recipe costs that depend on the
// affected ingredient are recomputed + persisted via cascadeMaterial().

import type { IngredientYield } from "../types";
import type { ImportSummary } from "../../import/importTypes";
import { computeYield } from "../../yield";
import { getUnitFamily } from "../../units";
import type { YieldInput, ImportYieldRow } from "../mock/yields";
import { sb, fail, cascadeMaterial, audit } from "./helpers";

/** Today as an ISO date (YYYY-MM-DD) — matches the mock's todayISO(). */
function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Base unit label for the purchase unit's family. */
function baseUnitLabel(unit: string): string {
  const fam = getUnitFamily(unit);
  return fam === "weight" ? "Gram" : fam === "volume" ? "ML" : unit;
}

/** Derive the full stored yield record from raw inputs (reuses computeYield). */
function derive(input: YieldInput): Omit<IngredientYield, "id" | "created_at" | "updated_at" | "created_by"> {
  const r = computeYield({
    purchaseCost: input.purchase_cost,
    purchaseQuantity: input.purchase_quantity,
    purchaseUnit: input.purchase_unit,
    wastageQty: input.wastage_quantity,
  });
  return {
    ingredient_id: input.ingredient_id,
    purchase_cost: input.purchase_cost,
    purchase_quantity: input.purchase_quantity,
    purchase_unit: input.purchase_unit,
    raw_quantity: r.rawQtyBase,
    raw_unit: baseUnitLabel(input.purchase_unit),
    wastage_quantity: input.wastage_quantity,
    wastage_unit: input.wastage_unit || baseUnitLabel(input.purchase_unit),
    usable_quantity: r.usableQty,
    wastage_percentage: r.wastagePct,
    yield_percentage: r.yieldPct,
    original_unit_cost: r.originalUnitCost,
    yield_adjusted_unit_cost: r.yieldAdjustedUnitCost,
    effective_from: input.effective_from ?? todayISO(),
    notes: input.notes ?? null,
  };
}

export const supabaseYieldsRepo = {
  async list(): Promise<IngredientYield[]> {
    const { data, error } = await sb().from("ingredient_yields").select("*");
    if (error) fail("Load yields", error.message);
    return (data ?? []) as IngredientYield[];
  },

  async getById(id: string): Promise<IngredientYield | null> {
    const { data, error } = await sb()
      .from("ingredient_yields")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (error) fail("Load yield", error.message);
    return (data ?? null) as IngredientYield | null;
  },

  async listForIngredient(ingredientId: string): Promise<IngredientYield[]> {
    const { data, error } = await sb()
      .from("ingredient_yields")
      .select("*")
      .eq("ingredient_id", ingredientId)
      .order("effective_from", { ascending: false });
    if (error) fail("Load yields for ingredient", error.message);
    return (data ?? []) as IngredientYield[];
  },

  async create(input: YieldInput, actorId: string): Promise<IngredientYield> {
    const c = sb();
    const eff = input.effective_from ?? todayISO();
    // Mirror the mock's friendly duplicate guard (table also enforces unique).
    const { data: existing, error: dupErr } = await c
      .from("ingredient_yields")
      .select("id")
      .eq("ingredient_id", input.ingredient_id)
      .eq("effective_from", eff)
      .maybeSingle();
    if (dupErr) fail("Create yield", dupErr.message);
    if (existing) fail("Create yield", "A yield record already exists for this ingredient on that effective date");

    const { data, error } = await c
      .from("ingredient_yields")
      .insert({ ...derive({ ...input, effective_from: eff }), created_by: actorId })
      .select("*")
      .single();
    if (error) fail("Create yield", error.message);
    const row = data as IngredientYield;

    await audit({
      entity_type: "ingredient",
      entity_id: input.ingredient_id,
      action: "create",
      new_values: { yield_pct: row.yield_percentage, adj_cost: row.yield_adjusted_unit_cost },
      performed_by: actorId,
      notes: `Added yield (${row.yield_percentage}% yield)`,
    });
    await cascadeMaterial(input.ingredient_id, actorId, "Yield added");
    return row;
  },

  async update(id: string, input: YieldInput, actorId: string): Promise<IngredientYield> {
    const c = sb();
    const { data: before, error: beforeErr } = await c
      .from("ingredient_yields")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (beforeErr) fail("Update yield", beforeErr.message);
    if (!before) fail("Update yield", "Yield record not found");
    const prev = before as IngredientYield;

    const { data, error } = await c
      .from("ingredient_yields")
      .update({ ...derive(input), updated_at: new Date().toISOString() })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Update yield", error.message);
    const row = data as IngredientYield;

    await audit({
      entity_type: "ingredient",
      entity_id: row.ingredient_id,
      action: "update",
      old_values: { yield_pct: prev.yield_percentage, adj_cost: prev.yield_adjusted_unit_cost },
      new_values: { yield_pct: row.yield_percentage, adj_cost: row.yield_adjusted_unit_cost },
      performed_by: actorId,
      notes: `Updated yield (${row.yield_percentage}% yield)`,
    });
    // Recompute the new ingredient; if the row was repointed, the old one too.
    await cascadeMaterial(row.ingredient_id, actorId, "Yield updated");
    if (prev.ingredient_id !== row.ingredient_id) {
      await cascadeMaterial(prev.ingredient_id, actorId, "Yield updated");
    }
    return row;
  },

  /**
   * Bulk yield import. Ingredients are resolved by name (must already exist).
   * Upserts by (ingredient, effective_from); recipe costs using each affected
   * ingredient are recomputed via the yield-adjusted cost cascade.
   */
  async importYields(
    mode: "add" | "update" | "upsert",
    rows: ImportYieldRow[],
    actorId: string,
  ): Promise<ImportSummary> {
    const c = sb();
    const S: ImportSummary = { total: 0, imported: 0, updated: 0, skipped: 0, failed: 0, errors: [] };

    // Resolve ingredients by name (matches the mock's case-insensitive map).
    const { data: mats, error: matErr } = await c
      .from("raw_materials")
      .select("id, ingredient_name");
    if (matErr) fail("Import yields", matErr.message);
    const matByName = new Map(
      (mats ?? []).map((m: { id: string; ingredient_name: string }) => [m.ingredient_name.toLowerCase(), m]),
    );

    const affected = new Set<string>();
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      S.total++;
      try {
        const mat = matByName.get(row.ingredient_name.trim().toLowerCase());
        if (!mat) {
          S.failed++;
          S.errors.push({ row: i + 1, message: `Ingredient not found: "${row.ingredient_name}"` });
          continue;
        }
        const eff = row.effective_from || todayISO();
        const input: YieldInput = {
          ingredient_id: mat.id,
          purchase_cost: row.purchase_cost,
          purchase_quantity: row.purchase_quantity,
          purchase_unit: row.purchase_unit,
          wastage_quantity: row.wastage_quantity,
          wastage_unit: baseUnitLabel(row.purchase_unit),
          effective_from: eff,
          notes: row.notes ?? null,
        };
        const derived = derive(input);
        if (!(derived.usable_quantity > 0)) {
          S.failed++;
          S.errors.push({ row: i + 1, message: `${row.ingredient_name}: wastage exceeds the raw quantity` });
          continue;
        }

        const { data: existing, error: exErr } = await c
          .from("ingredient_yields")
          .select("id")
          .eq("ingredient_id", mat.id)
          .eq("effective_from", eff)
          .maybeSingle();
        if (exErr) throw new Error(exErr.message);

        if (existing) {
          if (mode === "add") {
            S.skipped++;
            continue;
          }
          const { error: upErr } = await c
            .from("ingredient_yields")
            .update({ ...derived, updated_at: new Date().toISOString() })
            .eq("id", (existing as { id: string }).id);
          if (upErr) throw new Error(upErr.message);
          S.updated++;
        } else {
          if (mode === "update") {
            S.skipped++;
            continue;
          }
          const { error: insErr } = await c
            .from("ingredient_yields")
            .insert({ ...derived, created_by: actorId });
          if (insErr) throw new Error(insErr.message);
          S.imported++;
        }
        affected.add(mat.id);
      } catch (e) {
        S.failed++;
        S.errors.push({ row: i + 1, message: e instanceof Error ? e.message : "Failed" });
      }
    }

    for (const id of affected) await cascadeMaterial(id, actorId, "Yield import");
    await audit({
      entity_type: "ingredient",
      entity_id: "import",
      action: "create",
      new_values: { added: S.imported, updated: S.updated },
      performed_by: actorId,
      notes: `Imported yields — ${S.imported} added, ${S.updated} updated`,
    });
    return S;
  },

  async remove(id: string, actorId: string): Promise<void> {
    const c = sb();
    // Need the ingredient_id (for the cascade + audit) before deleting; mirror
    // the mock's silent no-op when the row doesn't exist.
    const { data: existing, error: getErr } = await c
      .from("ingredient_yields")
      .select("ingredient_id")
      .eq("id", id)
      .maybeSingle();
    if (getErr) fail("Delete yield", getErr.message);
    if (!existing) return;
    const ingredientId = (existing as { ingredient_id: string }).ingredient_id;

    const { error } = await c.from("ingredient_yields").delete().eq("id", id);
    if (error) fail("Delete yield", error.message);

    await audit({
      entity_type: "ingredient",
      entity_id: ingredientId,
      action: "delete",
      performed_by: actorId,
      notes: "Deleted yield record",
    });
    await cascadeMaterial(ingredientId, actorId, "Yield removed");
  },
};
