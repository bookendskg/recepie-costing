import { describe, it, expect, beforeEach } from "vitest";
import { resetDb } from "./mock/db";
import { materialsRepo } from "./mock/materials";
import { recipesRepo } from "./mock/recipes";

// Validates nested (in-house prep) sub-recipes: a menu recipe references prep
// recipes as components, and a leaf material price change rolls up prep → menu.
describe("sub-recipe (in-house prep) costing", () => {
  beforeEach(() => {
    resetDb();
  });

  it("Chilli Crunch Pizza references prep recipes as components", async () => {
    const data = await recipesRepo.getWithIngredients("r-chilli-crunch-pizza");
    expect(data).toBeTruthy();
    const dough = data!.ingredients.find((i) => i.ingredient_id === "r-prep-pizza-dough");
    expect(dough?.component_type).toBe("recipe");
    expect(dough?.subRecipe?.recipe_name).toBe("Pizza Dough");
    expect(data!.recipe.total_cost!).toBeGreaterThan(0);
  });

  it("prep recipes are flagged is_prep with a positive yield", async () => {
    const dough = await recipesRepo.getById("r-prep-pizza-dough");
    expect(dough?.is_prep).toBe(true);
    expect(dough!.yield_quantity).toBeGreaterThan(0);
  });

  it("raising a leaf material price rolls up through the prep to the menu item", async () => {
    const flour = await materialsRepo.getById("m-00-flour");
    const doughBefore = (await recipesRepo.getById("r-prep-pizza-dough"))!.total_cost!;
    const pizzaBefore = (await recipesRepo.getById("r-chilli-crunch-pizza"))!.total_cost!;

    // Double the flour price — dough is mostly flour, so both must increase.
    await materialsRepo.update(
      "m-00-flour",
      {
        ingredient_name: flour!.ingredient_name,
        category: flour!.category,
        supplier_name: flour!.supplier_name,
        purchase_price: flour!.purchase_price! + 200,
        purchase_quantity: 1,
        purchase_unit: "KG",
        base_unit: "Gram",
      },
      "u-admin",
    );

    const doughAfter = (await recipesRepo.getById("r-prep-pizza-dough"))!.total_cost!;
    const pizzaAfter = (await recipesRepo.getById("r-chilli-crunch-pizza"))!.total_cost!;

    expect(doughAfter).toBeGreaterThan(doughBefore);
    expect(pizzaAfter).toBeGreaterThan(pizzaBefore); // prep → menu roll-up
  });
});
