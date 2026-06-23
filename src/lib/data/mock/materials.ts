import { calculateCostPerBaseUnit } from "../../costing";
import type { IngredientPriceHistory, RawMaterial } from "../types";
import { delay, getDb, mutate, nowISO, todayISO, uid } from "./db";
import { cascadeFromMaterial, recordAudit } from "./recompute";

export interface MaterialInput {
  ingredient_name: string;
  category: string;
  supplier_name?: string | null;
  purchase_price: number | null;
  purchase_quantity: number;
  purchase_unit: string;
  base_unit: string;
}

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

export const materialsRepo = {
  async list(): Promise<RawMaterial[]> {
    return delay([...getDb().raw_materials]);
  },

  async getById(id: string): Promise<RawMaterial | null> {
    return delay(getDb().raw_materials.find((m) => m.id === id) ?? null);
  },

  async create(input: MaterialInput, actorId: string): Promise<RawMaterial> {
    return delay(
      mutate((db) => {
        if (
          db.raw_materials.some(
            (m) =>
              m.ingredient_name.toLowerCase() === input.ingredient_name.toLowerCase(),
          )
        ) {
          throw new Error("An ingredient with this name already exists");
        }
        const cpu = computeCpu(input);
        const material: RawMaterial = {
          id: uid(),
          ingredient_name: input.ingredient_name,
          category: input.category,
          supplier_name: input.supplier_name ?? null,
          purchase_price: input.purchase_price,
          purchase_quantity: input.purchase_quantity,
          purchase_unit: input.purchase_unit,
          base_unit: input.base_unit,
          cost_per_base_unit: cpu,
          last_price_update: input.purchase_price === null ? null : todayISO(),
          status: "active",
          created_by: actorId,
          created_at: nowISO(),
        };
        db.raw_materials.push(material);
        recordAudit(db, {
          entity_type: "ingredient",
          entity_id: material.id,
          action: "create",
          new_values: { name: material.ingredient_name, price: material.purchase_price },
          performed_by: actorId,
          notes: `Created ingredient ${material.ingredient_name}`,
        });
        return material;
      }),
    );
  },

  async update(id: string, input: MaterialInput, actorId: string): Promise<RawMaterial> {
    return delay(
      mutate((db) => {
        const m = db.raw_materials.find((x) => x.id === id);
        if (!m) throw new Error("Ingredient not found");
        if (
          db.raw_materials.some(
            (x) =>
              x.id !== id &&
              x.ingredient_name.toLowerCase() === input.ingredient_name.toLowerCase(),
          )
        ) {
          throw new Error("An ingredient with this name already exists");
        }

        const oldPrice = m.purchase_price;
        const oldCpu = m.cost_per_base_unit;

        m.ingredient_name = input.ingredient_name;
        m.category = input.category;
        m.supplier_name = input.supplier_name ?? null;
        m.purchase_price = input.purchase_price;
        m.purchase_quantity = input.purchase_quantity;
        m.purchase_unit = input.purchase_unit;
        m.base_unit = input.base_unit;
        const newCpu = computeCpu(input);
        m.cost_per_base_unit = newCpu;

        const priceChanged = oldPrice !== input.purchase_price || oldCpu !== newCpu;
        if (priceChanged) {
          m.last_price_update = input.purchase_price === null ? m.last_price_update : todayISO();
          db.ingredient_price_history.push({
            id: uid(),
            ingredient_id: m.id,
            old_price: oldPrice,
            new_price: input.purchase_price,
            old_cost_per_base_unit: oldCpu,
            new_cost_per_base_unit: newCpu,
            changed_by: actorId,
            changed_at: nowISO(),
          } satisfies IngredientPriceHistory);

          // Price cascade — PRD §4.5.
          cascadeFromMaterial(db, m.id, actorId, "Ingredient price update");
        }

        recordAudit(db, {
          entity_type: "ingredient",
          entity_id: m.id,
          action: "update",
          old_values: { price: oldPrice },
          new_values: { price: input.purchase_price },
          performed_by: actorId,
          notes: priceChanged
            ? `Updated ${m.ingredient_name} price ${oldPrice ?? "—"}→${input.purchase_price ?? "—"}`
            : `Updated ${m.ingredient_name}`,
        });
        return m;
      }),
    );
  },

  /** Soft delete — PRD only ever deactivates (set status inactive). */
  async setStatus(
    id: string,
    status: "active" | "inactive",
    actorId: string,
  ): Promise<RawMaterial> {
    return delay(
      mutate((db) => {
        const m = db.raw_materials.find((x) => x.id === id);
        if (!m) throw new Error("Ingredient not found");
        m.status = status;
        recordAudit(db, {
          entity_type: "ingredient",
          entity_id: m.id,
          action: status === "inactive" ? "delete" : "update",
          performed_by: actorId,
          notes: `${status === "inactive" ? "Deactivated" : "Reactivated"} ${m.ingredient_name}`,
        });
        return m;
      }),
    );
  },

  /** All ingredient price-history rows (for bulk Excel export). */
  async allPriceHistory(): Promise<IngredientPriceHistory[]> {
    return delay(
      [...getDb().ingredient_price_history].sort((a, b) =>
        b.changed_at.localeCompare(a.changed_at),
      ),
    );
  },

  async priceHistory(id: string): Promise<IngredientPriceHistory[]> {
    return delay(
      getDb()
        .ingredient_price_history.filter((h) => h.ingredient_id === id)
        .sort((a, b) => b.changed_at.localeCompare(a.changed_at)),
    );
  },
};
