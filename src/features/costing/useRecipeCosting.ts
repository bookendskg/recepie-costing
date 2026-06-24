import { useMemo } from "react";
import { calculateIngredientCost, round2, type RecipeCostingResult } from "@/lib/costing";
import { canConvert, getConversionFactor } from "@/lib/units";
import type { RawMaterial, Recipe } from "@/lib/data/types";

export interface EditorLine {
  ingredient_id: string;
  component_type?: "material" | "recipe";
  quantity_used: number;
  unit_used: string;
}

export interface CostedLine extends EditorLine {
  material: RawMaterial | null;
  subRecipe: Recipe | null;
  cost: number | null;
  /** True when the line has a material with no price (blocks approval). */
  missingPrice: boolean;
  /** True when the chosen unit can't convert to the material's base unit. */
  unitMismatch: boolean;
}

export interface RecipeCostingView extends RecipeCostingResult {
  lines: CostedLine[];
  hasMissingPrice: boolean;
}

/** A prep recipe's cost per unit of its yield (e.g. ₹/gram). */
function prepUnitCost(r: Recipe): number {
  return r.yield_quantity > 0 ? (r.total_cost ?? 0) / r.yield_quantity : 0;
}

/**
 * Live recipe costing for the editor (PRD §4.3). Handles both raw-material and
 * sub-recipe (in-house prep) components.
 */
export function useRecipeCosting(
  lines: EditorLine[],
  materialsById: Map<string, RawMaterial>,
  prepsById: Map<string, Recipe>,
  servingSize: number,
  foodCostPct: number,
  wastagePct = 0,
): RecipeCostingView {
  return useMemo(() => {
    const costed: CostedLine[] = lines.map((l) => {
      if (l.component_type === "recipe") {
        const subRecipe = prepsById.get(l.ingredient_id) ?? null;
        let cost: number | null = null;
        if (subRecipe) {
          const factor = canConvert(l.unit_used, subRecipe.yield_unit)
            ? getConversionFactor(l.unit_used, subRecipe.yield_unit)
            : 1;
          cost = round2(prepUnitCost(subRecipe) * (l.quantity_used || 0) * factor);
        }
        return { ...l, material: null, subRecipe, cost, missingPrice: false, unitMismatch: false };
      }
      const material = materialsById.get(l.ingredient_id) ?? null;
      const missingPrice = !!material && material.cost_per_base_unit === null;
      const unitMismatch = !!material && !canConvert(l.unit_used, material.base_unit);
      const cost =
        material && material.cost_per_base_unit !== null && !unitMismatch && l.quantity_used > 0
          ? calculateIngredientCost(material.cost_per_base_unit, l.quantity_used, l.unit_used, material.base_unit)
          : null;
      return { ...l, material, subRecipe: null, cost, missingPrice, unitMismatch };
    });

    const rawCost = costed.reduce((s, l) => s + (l.cost ?? 0), 0);
    const totalCost = round2(rawCost * (1 + wastagePct / 100));
    const serving = servingSize > 0 ? servingSize : 1;
    const rawCpp = totalCost / serving;
    const rawSuggested = foodCostPct > 0 ? rawCpp / (foodCostPct / 100) : 0;
    const rawProfit = rawSuggested - rawCpp;
    const rawMargin = rawSuggested > 0 ? (rawProfit / rawSuggested) * 100 : 0;

    return {
      lineCosts: costed.map((l) => l.cost ?? 0),
      totalCost,
      costPerPortion: round2(rawCpp),
      suggestedPrice: round2(rawSuggested),
      grossProfit: round2(rawProfit),
      grossMarginPct: round2(rawMargin),
      lines: costed,
      hasMissingPrice: costed.some((l) => l.missingPrice),
    };
  }, [lines, materialsById, prepsById, servingSize, foodCostPct, wastagePct]);
}
