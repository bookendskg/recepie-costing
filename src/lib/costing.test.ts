import { describe, it, expect } from "vitest";
import {
  calculateCostPerBaseUnit,
  calculateIngredientCost,
  calculateCostPerPortion,
  calculateSuggestedPrice,
  calculateProfitMetrics,
  calculateRecipeCosting,
  percentChange,
} from "./costing";
import { getConversionFactor, canConvert } from "./units";

describe("getConversionFactor (PRD §4.2)", () => {
  it("converts KG → Gram ×1000", () => {
    expect(getConversionFactor("KG", "Gram")).toBe(1000);
  });
  it("converts Litre → ML ×1000", () => {
    expect(getConversionFactor("Litre", "ML")).toBe(1000);
  });
  it("returns 1 for same unit", () => {
    expect(getConversionFactor("Piece", "Piece")).toBe(1);
  });
  it("throws on invalid pair", () => {
    expect(() => getConversionFactor("KG", "ML")).toThrow();
  });
});

describe("canConvert compatibility rules (PRD §4.2)", () => {
  it("weight units interchange", () => {
    expect(canConvert("KG", "Gram")).toBe(true);
  });
  it("volume units interchange", () => {
    expect(canConvert("Litre", "ML")).toBe(true);
  });
  it("count units do not cross", () => {
    expect(canConvert("Piece", "Packet")).toBe(false);
    expect(canConvert("Piece", "Piece")).toBe(true);
  });
  it("weight and volume do not mix", () => {
    expect(canConvert("Gram", "ML")).toBe(false);
  });
});

describe("calculateCostPerBaseUnit (PRD §4.4 examples)", () => {
  it("Onion: ₹100 / 1KG → ₹0.10/gram", () => {
    expect(calculateCostPerBaseUnit(100, 1, "KG", "Gram")).toBeCloseTo(0.1, 4);
  });
  it("Milk: ₹80 / 1L → ₹0.08/ml", () => {
    expect(calculateCostPerBaseUnit(80, 1, "Litre", "ML")).toBeCloseTo(0.08, 4);
  });
});

describe("calculateIngredientCost (PRD §4.4)", () => {
  it("200g Onion @ ₹0.10/g = ₹20.00", () => {
    expect(calculateIngredientCost(0.1, 200, "Gram", "Gram")).toBe(20);
  });
  it("500ml Milk @ ₹0.08/ml = ₹40.00", () => {
    expect(calculateIngredientCost(0.08, 500, "ML", "ML")).toBe(40);
  });
});

describe("Full recipe costing — Chicken Alfredo (PRD §4.4 Example 3)", () => {
  const result = calculateRecipeCosting(
    [
      { costPerBaseUnit: 0.25, quantityUsed: 500, unitUsed: "Gram", baseUnit: "Gram" },
      { costPerBaseUnit: 0.18, quantityUsed: 200, unitUsed: "Gram", baseUnit: "Gram" },
      { costPerBaseUnit: 0.12, quantityUsed: 150, unitUsed: "ML", baseUnit: "ML" },
      { costPerBaseUnit: 0.4, quantityUsed: 50, unitUsed: "Gram", baseUnit: "Gram" },
      { costPerBaseUnit: 0.05, quantityUsed: 10, unitUsed: "Gram", baseUnit: "Gram" },
    ],
    4,
    30,
  );

  it("line costs match", () => {
    expect(result.lineCosts).toEqual([125, 36, 18, 20, 0.5]);
  });
  it("total recipe cost = ₹199.50", () => {
    expect(result.totalCost).toBe(199.5);
  });
  it("cost per portion = ₹49.88", () => {
    expect(result.costPerPortion).toBe(49.88);
  });
  it("suggested price at 30% = ₹166.25", () => {
    expect(result.suggestedPrice).toBe(166.25);
  });
  it("gross profit = ₹116.38 (₹166.25 − ₹49.875; PRD prints 116.37 via double-rounding)", () => {
    expect(result.grossProfit).toBe(116.38);
  });
  it("gross margin = 70%", () => {
    expect(result.grossMarginPct).toBe(70);
  });
});

describe("price / profit helpers", () => {
  it("suggested price at 25% and 35%", () => {
    expect(calculateSuggestedPrice(50, 25)).toBe(200);
    expect(calculateSuggestedPrice(35, 35)).toBe(100);
  });
  it("cost per portion guards divide-by-zero", () => {
    expect(calculateCostPerPortion(100, 0)).toBe(0);
  });
  it("profit metrics with zero selling price", () => {
    expect(calculateProfitMetrics(0, 0)).toEqual({ grossProfit: 0, grossMarginPct: 0 });
  });
  it("percentChange +20% on price bump 100→120", () => {
    expect(percentChange(100, 120)).toBe(20);
  });
});
