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

  it("seed Aglio Olio has a positive single-portion cost", async () => {
    const r = await recipesRepo.getById("r-aglio-olio");
    expect(r).toBeTruthy();
    expect(r!.total_cost!).toBeGreaterThan(0);
    // serving size is 1, so cost per portion equals the total cost.
    expect(r!.cost_per_portion).toBe(r!.total_cost);
  });

  it("raising Olive Oil price cascades to recipes that use it", async () => {
    const before = (await recipesRepo.getById("r-aglio-olio"))!.total_cost!;
    const oil = await materialsRepo.getById("m-olive-oil");
    const origPrice = oil!.purchase_price!;
    const newPrice = origPrice + 1000;

    // +₹1000/KG = +₹1/g; Aglio Olio uses 15 g → +₹15.00.
    await materialsRepo.update(
      "m-olive-oil",
      {
        ingredient_name: oil!.ingredient_name,
        category: oil!.category,
        supplier_name: oil!.supplier_name,
        purchase_price: newPrice,
        purchase_quantity: 1,
        purchase_unit: "KG",
        base_unit: "Gram",
      },
      "u-admin",
    );

    const after = (await recipesRepo.getById("r-aglio-olio"))!.total_cost!;
    expect(after - before).toBeCloseTo(15, 1);

    const history = await recipesRepo.costHistory("r-aglio-olio");
    expect(history.length).toBe(1);
    expect(history[0].old_total_cost).toBe(before);
    expect(history[0].new_total_cost).toBe(after);

    const priceLog = await materialsRepo.priceHistory("m-olive-oil");
    expect(priceLog[0].old_price).toBe(origPrice);
    expect(priceLog[0].new_price).toBe(newPrice);
  });
});
