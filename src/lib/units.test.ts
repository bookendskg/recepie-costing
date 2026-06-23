import { describe, it, expect } from "vitest";
import {
  canConvert,
  compatibleUnits,
  getConversionFactor,
  getUnitFamily,
} from "./units";

describe("getUnitFamily", () => {
  it("classifies weight/volume/count", () => {
    expect(getUnitFamily("KG")).toBe("weight");
    expect(getUnitFamily("ML")).toBe("volume");
    expect(getUnitFamily("Piece")).toBe("count");
    expect(getUnitFamily("Nonsense")).toBeNull();
  });
});

describe("getConversionFactor — all valid pairs (PRD §4.2)", () => {
  it("weight pairs", () => {
    expect(getConversionFactor("KG", "Gram")).toBe(1000);
    expect(getConversionFactor("Gram", "KG")).toBe(1 / 1000);
    expect(getConversionFactor("Gram", "Gram")).toBe(1);
  });
  it("volume pairs", () => {
    expect(getConversionFactor("Litre", "ML")).toBe(1000);
    expect(getConversionFactor("ML", "Litre")).toBe(1 / 1000);
  });
  it("count identity", () => {
    expect(getConversionFactor("Piece", "Piece")).toBe(1);
  });
  it("throws on cross-family", () => {
    expect(() => getConversionFactor("Gram", "ML")).toThrow();
    expect(() => getConversionFactor("Piece", "Packet")).toThrow();
  });
});

describe("canConvert", () => {
  it("permits same-family, blocks cross-family and count cross", () => {
    expect(canConvert("KG", "Gram")).toBe(true);
    expect(canConvert("Litre", "ML")).toBe(true);
    expect(canConvert("Piece", "Piece")).toBe(true);
    expect(canConvert("Piece", "Bottle")).toBe(false);
    expect(canConvert("Gram", "Litre")).toBe(false);
  });
});

describe("compatibleUnits", () => {
  it("returns the family options for the line unit dropdown", () => {
    expect(compatibleUnits("Gram")).toEqual(["Gram", "KG"]);
    expect(compatibleUnits("ML")).toEqual(["ML", "Litre"]);
    expect(compatibleUnits("Piece")).toEqual(["Piece"]);
  });
});
