// Excel export — PRD §6.3 / §13.2. Four sheets via SheetJS (xlsx).

import { calculateIngredientCost, round2 } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import { formatDate } from "@/lib/utils";
import type {
  IngredientPriceHistory,
  RawMaterial,
  Recipe,
  RecipeCostHistory,
  RecipeIngredientWithMaterial,
  User,
} from "@/lib/data/types";

export interface ExcelExportData {
  recipes: Recipe[];
  ingredients: RecipeIngredientWithMaterial[];
  costHistory: RecipeCostHistory[];
  priceHistory: IngredientPriceHistory[];
  usersById: Map<string, User>;
  materialsById: Map<string, RawMaterial>;
  foodCostPct: number;
}

export async function generateExcelReport(data: ExcelExportData, label: string) {
  const XLSX = await import("xlsx");
  const wb = XLSX.utils.book_new();
  const name = (id: string | null) => (id ? data.usersById.get(id)?.name ?? "—" : "—");
  const recipeName = (id: string) =>
    data.recipes.find((r) => r.id === id)?.recipe_name ?? "—";

  // Sheet 1 — Recipe Summary
  const summary = data.recipes.map((r) => {
    const perPortion = r.cost_per_portion ?? 0;
    const suggested = perPortion > 0 ? round2(perPortion / (data.foodCostPct / 100)) : 0;
    return {
      "Recipe Name": r.recipe_name,
      Category: r.category,
      "Serving Size": r.serving_size,
      "Total Cost": r.total_cost ?? 0,
      "Cost/Portion": perPortion,
      "Suggested Price": suggested,
      Status: r.status,
      "Approved By": name(r.approved_by),
      Date: formatDate(r.approved_at ?? r.created_at),
    };
  });

  // Sheet 2 — Ingredient Breakdown
  const totalByRecipe = new Map<string, number>();
  data.ingredients.forEach((i) => {
    const m = i.material;
    const cost =
      m && m.cost_per_base_unit !== null && canConvert(i.unit_used, m.base_unit)
        ? calculateIngredientCost(m.cost_per_base_unit, i.quantity_used, i.unit_used, m.base_unit)
        : 0;
    totalByRecipe.set(i.recipe_id, (totalByRecipe.get(i.recipe_id) ?? 0) + cost);
  });
  const breakdown = data.ingredients.map((i) => {
    const m = i.material;
    const cost =
      m && m.cost_per_base_unit !== null && canConvert(i.unit_used, m.base_unit)
        ? calculateIngredientCost(m.cost_per_base_unit, i.quantity_used, i.unit_used, m.base_unit)
        : 0;
    const total = totalByRecipe.get(i.recipe_id) ?? 0;
    return {
      "Recipe Name": recipeName(i.recipe_id),
      Ingredient: m?.ingredient_name ?? "—",
      Qty: i.quantity_used,
      Unit: i.unit_used,
      "Unit Cost": m?.cost_per_base_unit ?? 0,
      "Total Cost": round2(cost),
      "% of Total": total > 0 ? round2((cost / total) * 100) : 0,
    };
  });

  // Sheet 3 — Cost History
  const cost = data.costHistory.map((h) => ({
    "Recipe Name": recipeName(h.recipe_id ?? ""),
    "Old Cost": h.old_total_cost ?? 0,
    "New Cost": h.new_total_cost ?? 0,
    "Change %":
      h.old_total_cost && h.old_total_cost > 0
        ? round2((((h.new_total_cost ?? 0) - h.old_total_cost) / h.old_total_cost) * 100)
        : 0,
    "Changed By": name(h.changed_by),
    Date: formatDate(h.changed_at),
  }));

  // Sheet 4 — Ingredient Price Log
  const price = data.priceHistory.map((h) => ({
    Ingredient: data.materialsById.get(h.ingredient_id)?.ingredient_name ?? "—",
    "Old Price": h.old_price ?? 0,
    "New Price": h.new_price ?? 0,
    Unit: data.materialsById.get(h.ingredient_id)?.base_unit ?? "",
    "Changed By": name(h.changed_by),
    Date: formatDate(h.changed_at),
  }));

  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(summary), "Recipe Summary");
  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(breakdown), "Ingredient Detail");
  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(cost), "Cost History");
  XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(price), "Price History");

  XLSX.writeFile(wb, `RecipeCosting_Report_${label}.xlsx`);
}
