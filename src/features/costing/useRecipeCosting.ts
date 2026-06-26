import { useMemo } from "react";
import { calculateIngredientCost, prepUnitCostFrom, round2, type RecipeCostingResult } from "@/lib/costing";
import { canConvert, getConversionFactor } from "@/lib/units";
import { activeYield, effectiveCostPerBaseUnit } from "@/lib/yield";
import type { IngredientYield, RawMaterial, Recipe } from "@/lib/data/types";

export interface EditorLine {
  ingredient_id: string;
  component_type?: "material" | "recipe";
  quantity_used: number;
  unit_used: string;
  /** Recipe-specific wastage % override (§10); null → standard yield. */
  wastage_override_pct?: number | null;
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
  /** Per-portion packaging cost passed in. */
  packagingCost: number;
  /** cost_per_portion + packaging — what the menu price must cover. */
  fullCostPerPortion: number;
}

/** A prep recipe's cost per unit of its yield (pre-wastage; ₹/gram). */
function prepUnitCost(r: Recipe): number {
  return prepUnitCostFrom(r.total_cost ?? 0, r.yield_quantity, r.wastage_pct ?? 0);
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
  packagingCost = 0,
  yields: IngredientYield[] = [],
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
      const yieldRec = material ? activeYield(yields, material.id) : null;
      // §9: yield-adjusted rate when yield exists, else the purchase rate.
      const rate = material ? effectiveCostPerBaseUnit(material.cost_per_base_unit, yieldRec, l.wastage_override_pct) : null;
      const missingPrice = !!material && rate === null;
      const unitMismatch = !!material && !canConvert(l.unit_used, material.base_unit);
      const cost =
        material && rate !== null && !unitMismatch && l.quantity_used > 0
          ? calculateIngredientCost(rate, l.quantity_used, l.unit_used, material.base_unit)
          : null;
      return { ...l, material, subRecipe: null, cost, missingPrice, unitMismatch };
    });

    const rawCost = costed.reduce((s, l) => s + (l.cost ?? 0), 0);
    const totalCost = round2(rawCost * (1 + wastagePct / 100));
    const serving = servingSize > 0 ? servingSize : 1;
    const rawCpp = totalCost / serving;
    // Packaging is a per-portion cost the price must also cover.
    const rawFullCpp = rawCpp + packagingCost;
    const rawSuggested = foodCostPct > 0 ? rawFullCpp / (foodCostPct / 100) : 0;
    const rawProfit = rawSuggested - rawFullCpp;
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
      packagingCost,
      fullCostPerPortion: round2(rawFullCpp),
    };
  }, [lines, materialsById, prepsById, servingSize, foodCostPct, wastagePct, packagingCost, yields]);
}
