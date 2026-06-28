// Supabase-backed raw-materials (ingredients) repository (Phase 2). Mirrors the
// mock `materialsRepo` interface 1:1 so feature code is unchanged — src/lib/data/index.ts
// selects between mock and Supabase by whether Supabase is configured. Backed by
// public.raw_materials + public.ingredient_price_history (db/migrations/0001, 0008);
// access is enforced by RLS (can_write_catalog → admin/editor).
//
// A row's own derived field (cost_per_base_unit) is computed with the SAME pure
// helper the mock uses (calculateCostPerBaseUnit); the recipe price cascade reuses
// the shared cascadeMaterial() helper, which runs the verified mock recompute on a
// loaded costing snapshot and persists only the rows whose cost changed.

import { calculateCostPerBaseUnit } from "../../costing";
import type { ImportSummary } from "../../import/importTypes";
import type { IngredientPriceHistory, RawMaterial } from "../types";
import type { MaterialInput } from "../mock/materials";
import { audit, cascadeMaterial, fail, sb } from "./helpers";

/** Per-row derived field — mirrors the mock's computeCpu (uses the pure helper). */
function computeCpu(input: {
  purchase_price: number | null;
  purchase_quantity: number;
  purchase_unit: string;
  base_unit: string;
}): number | null {
  if (input.purchase_price === null) return null;
  return calculateCostPerBaseUnit(
    input.purchase_price,
    input.purchase_quantity,
    input.purchase_unit,
    input.base_unit,
  );
}

function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}

function nowISO(): string {
  return new Date().toISOString();
}

export const supabaseMaterialsRepo = {
  async list(): Promise<RawMaterial[]> {
    const { data, error } = await sb()
      .from("raw_materials")
      .select("*")
      .order("created_at", { ascending: false });
    if (error) fail("Load ingredients", error.message);
    return (data ?? []) as RawMaterial[];
  },

  async getById(id: string): Promise<RawMaterial | null> {
    const { data, error } = await sb()
      .from("raw_materials")
      .select("*")
      .eq("id", id)
      .maybeSingle();
    if (error) fail("Load ingredient", error.message);
    return (data as RawMaterial | null) ?? null;
  },

  async create(input: MaterialInput, actorId: string): Promise<RawMaterial> {
    const cpu = computeCpu(input);
    const { data, error } = await sb()
      .from("raw_materials")
      .insert({
        ingredient_name: input.ingredient_name,
        category: input.category,
        supplier_name: input.supplier_name ?? null,
        notes: input.notes ?? null,
        purchase_price: input.purchase_price,
        purchase_quantity: input.purchase_quantity,
        purchase_unit: input.purchase_unit,
        base_unit: input.base_unit,
        cost_per_base_unit: cpu,
        last_price_update: input.purchase_price === null ? null : todayISO(),
        status: "active",
        created_by: actorId,
      })
      .select("*")
      .single();
    if (error) {
      // Unique-constraint on ingredient_name → friendly message (mirrors the mock).
      if (error.code === "23505") fail("Create ingredient", "An ingredient with this name already exists");
      fail("Create ingredient", error.message);
    }
    const material = data as RawMaterial;

    await audit({
      entity_type: "ingredient",
      entity_id: material.id,
      action: "create",
      new_values: { name: material.ingredient_name, price: material.purchase_price },
      performed_by: actorId,
      notes: `Created ingredient ${material.ingredient_name}`,
    });

    return material;
  },

  async update(id: string, input: MaterialInput, actorId: string): Promise<RawMaterial> {
    const existing = await this.getById(id);
    if (!existing) fail("Update ingredient", "Ingredient not found");

    const oldPrice = existing.purchase_price;
    const oldCpu = existing.cost_per_base_unit;
    const newCpu = computeCpu(input);
    const priceChanged = oldPrice !== input.purchase_price || oldCpu !== newCpu;

    const { data, error } = await sb()
      .from("raw_materials")
      .update({
        ingredient_name: input.ingredient_name,
        category: input.category,
        supplier_name: input.supplier_name ?? null,
        notes: input.notes ?? null,
        purchase_price: input.purchase_price,
        purchase_quantity: input.purchase_quantity,
        purchase_unit: input.purchase_unit,
        base_unit: input.base_unit,
        cost_per_base_unit: newCpu,
        last_price_update:
          priceChanged && input.purchase_price !== null ? todayISO() : existing.last_price_update,
      })
      .eq("id", id)
      .select("*")
      .single();
    if (error) {
      if (error.code === "23505") fail("Update ingredient", "An ingredient with this name already exists");
      fail("Update ingredient", error.message);
    }
    const material = data as RawMaterial;

    if (priceChanged) {
      const { error: histErr } = await sb().from("ingredient_price_history").insert({
        ingredient_id: material.id,
        old_price: oldPrice,
        new_price: input.purchase_price,
        old_cost_per_base_unit: oldCpu,
        new_cost_per_base_unit: newCpu,
        changed_by: actorId,
        changed_at: nowISO(),
      });
      if (histErr) fail("Record price history", histErr.message);

      // Price cascade — PRD §4.5 (recompute + persist affected recipes).
      await cascadeMaterial(material.id, actorId, "Ingredient price update");
    }

    await audit({
      entity_type: "ingredient",
      entity_id: material.id,
      action: "update",
      old_values: { price: oldPrice },
      new_values: { price: input.purchase_price },
      performed_by: actorId,
      notes: priceChanged
        ? `Updated ${material.ingredient_name} price ${oldPrice ?? "—"}→${input.purchase_price ?? "—"}`
        : `Updated ${material.ingredient_name}`,
    });

    return material;
  },

  /** Bulk import (§35): upsert ingredients by name, then cascade prices to recipes. */
  async importMaterials(
    mode: "add" | "update" | "upsert",
    rows: MaterialInput[],
    actorId: string,
  ): Promise<ImportSummary> {
    const summary: ImportSummary = {
      total: rows.length,
      imported: 0,
      updated: 0,
      skipped: 0,
      failed: 0,
      errors: [],
    };

    // Existing rows by lowercased name (mirrors the mock's by-name upsert key).
    const existingList = await this.list();
    const byName = new Map(existingList.map((m) => [m.ingredient_name.toLowerCase(), m]));
    const changed = new Set<string>();
    const c = sb();

    for (let i = 0; i < rows.length; i++) {
      const input = rows[i];
      try {
        const existing = byName.get(input.ingredient_name.toLowerCase());
        const cpu = computeCpu(input);
        if (existing) {
          if (mode === "add") {
            summary.skipped++;
            continue;
          }
          const { data, error } = await c
            .from("raw_materials")
            .update({
              category: input.category || existing.category,
              supplier_name: input.supplier_name ?? existing.supplier_name,
              notes: input.notes ?? existing.notes,
              purchase_price: input.purchase_price,
              purchase_quantity: input.purchase_quantity,
              purchase_unit: input.purchase_unit,
              base_unit: input.base_unit,
              cost_per_base_unit: cpu,
              last_price_update:
                input.purchase_price === null ? existing.last_price_update : todayISO(),
            })
            .eq("id", existing.id)
            .select("*")
            .single();
          if (error) throw new Error(error.message);
          byName.set(input.ingredient_name.toLowerCase(), data as RawMaterial);
          changed.add(existing.id);
          summary.updated++;
        } else {
          if (mode === "update") {
            summary.skipped++;
            continue;
          }
          const { data, error } = await c
            .from("raw_materials")
            .insert({
              ingredient_name: input.ingredient_name,
              category: input.category,
              supplier_name: input.supplier_name ?? null,
              notes: input.notes ?? null,
              purchase_price: input.purchase_price,
              purchase_quantity: input.purchase_quantity,
              purchase_unit: input.purchase_unit,
              base_unit: input.base_unit,
              cost_per_base_unit: cpu,
              last_price_update: input.purchase_price === null ? null : todayISO(),
              status: "active",
              created_by: actorId,
            })
            .select("*")
            .single();
          if (error) throw new Error(error.message);
          const material = data as RawMaterial;
          byName.set(material.ingredient_name.toLowerCase(), material);
          changed.add(material.id);
          summary.imported++;
        }
      } catch (e) {
        summary.failed++;
        summary.errors.push({ row: i + 2, message: e instanceof Error ? e.message : "Failed" });
      }
    }

    // Cascade once per changed ingredient (recompute + persist affected recipes).
    for (const id of changed) await cascadeMaterial(id, actorId, "Ingredient import");

    await audit({
      entity_type: "ingredient",
      entity_id: "import",
      action: "update",
      new_values: { added: summary.imported, updated: summary.updated },
      performed_by: actorId,
      notes: `Imported ingredients — ${summary.imported} added, ${summary.updated} updated`,
    });

    return summary;
  },

  /** Soft delete — PRD only ever deactivates (set status inactive). */
  async setStatus(
    id: string,
    status: "active" | "inactive",
    actorId: string,
  ): Promise<RawMaterial> {
    const { data, error } = await sb()
      .from("raw_materials")
      .update({ status })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Update ingredient status", error.message);
    const material = data as RawMaterial;

    await audit({
      entity_type: "ingredient",
      entity_id: material.id,
      action: status === "inactive" ? "delete" : "update",
      performed_by: actorId,
      notes: `${status === "inactive" ? "Deactivated" : "Reactivated"} ${material.ingredient_name}`,
    });

    return material;
  },

  /** Bulk activate/deactivate (bulk delete = bulk deactivate, soft delete). */
  async bulkSetStatus(
    ids: string[],
    status: "active" | "inactive",
    actorId: string,
  ): Promise<number> {
    const c = sb();
    let n = 0;
    for (const id of ids) {
      // Skip rows already in the target status (mirrors the mock's no-op guard).
      const { data, error } = await c
        .from("raw_materials")
        .update({ status })
        .eq("id", id)
        .neq("status", status)
        .select("*")
        .maybeSingle();
      if (error) fail("Bulk update ingredient status", error.message);
      if (!data) continue;
      const material = data as RawMaterial;
      n++;
      await audit({
        entity_type: "ingredient",
        entity_id: material.id,
        action: status === "inactive" ? "delete" : "update",
        performed_by: actorId,
        notes: `${status === "inactive" ? "Deactivated" : "Reactivated"} ${material.ingredient_name} (bulk)`,
      });
    }
    return n;
  },

  /** All ingredient price-history rows (for bulk Excel export). */
  async allPriceHistory(): Promise<IngredientPriceHistory[]> {
    const { data, error } = await sb()
      .from("ingredient_price_history")
      .select("*")
      .order("changed_at", { ascending: false });
    if (error) fail("Load price history", error.message);
    return (data ?? []) as IngredientPriceHistory[];
  },

  /** Most recent price changes across all ingredients (dashboard feed). */
  async recentPriceHistory(limit = 10): Promise<IngredientPriceHistory[]> {
    const { data, error } = await sb()
      .from("ingredient_price_history")
      .select("*")
      .order("changed_at", { ascending: false })
      .limit(limit);
    if (error) fail("Load price history", error.message);
    return (data ?? []) as IngredientPriceHistory[];
  },

  async priceHistory(id: string): Promise<IngredientPriceHistory[]> {
    const { data, error } = await sb()
      .from("ingredient_price_history")
      .select("*")
      .eq("ingredient_id", id)
      .order("changed_at", { ascending: false });
    if (error) fail("Load price history", error.message);
    return (data ?? []) as IngredientPriceHistory[];
  },
};
