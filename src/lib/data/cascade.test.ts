import { describe, it, expect, beforeEach } from "vitest";
import { resetDb } from "./mock/db";
import { materialsRepo } from "./mock/materials";
import { recipesRepo } from "./mock/recipes";

// Validates the price cascade (PRD §4.5): updating an ingredient price
// recalculates every recipe that uses it and records cost history.
describe("price cascade", () => {
  beforeEach(() => {
    resetDb();
  });

  it("seed Chicken Alfredo totals ₹199.50", async () => {
    const r = await recipesRepo.getById("r-alfredo");
    expect(r?.total_cost).toBe(199.5);
  });

  it("raising Chicken price 250→300/KG cascades to the recipe", async () => {
    const chicken = await materialsRepo.getById("m-chicken");
    await materialsRepo.update(
      "m-chicken",
      {
        ingredient_name: chicken!.ingredient_name,
        category: chicken!.category,
        supplier_name: chicken!.supplier_name,
        purchase_price: 300,
        purchase_quantity: 1,
        purchase_unit: "KG",
        base_unit: "Gram",
      },
      "u-admin",
    );

    // 500g at the new ₹0.30/g = ₹150 (was ₹125), so total 199.50 → 224.50.
    const r = await recipesRepo.getById("r-alfredo");
    expect(r?.total_cost).toBe(224.5);

    const history = await recipesRepo.costHistory("r-alfredo");
    expect(history.length).toBe(1);
    expect(history[0].old_total_cost).toBe(199.5);
    expect(history[0].new_total_cost).toBe(224.5);

    const priceLog = await materialsRepo.priceHistory("m-chicken");
    expect(priceLog[0].old_price).toBe(250);
    expect(priceLog[0].new_price).toBe(300);
  });
});
