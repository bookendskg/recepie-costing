import { useMemo } from "react";
import { calculateRecipeCosting, type RecipeCostingResult } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import type { RawMaterial } from "@/lib/data/types";

export interface EditorLine {
  ingredient_id: string;
  quantity_used: number;
  unit_used: string;
}

export interface CostedLine extends EditorLine {
  material: RawMaterial | null;
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

/**
 * Live recipe costing for the editor (PRD §4.3). Pure derivation from the
 * current lines, the materials map, serving size, and the global food cost %.
 */
export function useRecipeCosting(
  lines: EditorLine[],
  materialsById: Map<string, RawMaterial>,
  servingSize: number,
  foodCostPct: number,
): RecipeCostingView {
  return useMemo(() => {
    const costed: CostedLine[] = lines.map((l) => {
      const material = materialsById.get(l.ingredient_id) ?? null;
      const missingPrice = !!material && material.cost_per_base_unit === null;
      const unitMismatch = !!material && !canConvert(l.unit_used, material.base_unit);
      return { ...l, material, cost: null, missingPrice, unitMismatch };
    });

    const costable = costed.filter(
      (l) => l.material && l.material.cost_per_base_unit !== null && !l.unitMismatch,
    );

    const result = calculateRecipeCosting(
      costable.map((l) => ({
        costPerBaseUnit: l.material!.cost_per_base_unit!,
        quantityUsed: l.quantity_used || 0,
        unitUsed: l.unit_used,
        baseUnit: l.material!.base_unit,
      })),
      servingSize > 0 ? servingSize : 1,
      foodCostPct,
    );

    // map per-line costs back onto the costable lines
    costable.forEach((l, i) => {
      l.cost = result.lineCosts[i];
    });

    return {
      ...result,
      lines: costed,
      hasMissingPrice: costed.some((l) => l.missingPrice),
    };
  }, [lines, materialsById, servingSize, foodCostPct]);
}
