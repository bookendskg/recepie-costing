import { create } from "zustand";
import type { BrandSelection } from "./BrandFilter";

// Shared dashboard brand selection so the app layout can paint the whole
// dashboard background to match the active brand.
interface BrandState {
  brand: BrandSelection;
  setBrand: (brand: BrandSelection) => void;
}

export const useDashboardBrand = create<BrandState>((set) => ({
  brand: "all",
  setBrand: (brand) => set({ brand }),
}));

/** Full-page background class for the selected brand (matches brand logos). */
export function brandBgClass(brand: BrandSelection): string {
  switch (brand) {
    case "capiche":
      return "bg-[#ed1c24]"; // Capiche red
    case "aiko":
      return "bg-[#e8b923]"; // Aiko gold
    default:
      return "bg-[#1b35a8]"; // BOOKENDS blue (All Brands)
  }
}

/** Soft brand tint for non-dashboard pages (low-opacity brand over the base). */
export function brandTintClass(brand: BrandSelection): string {
  switch (brand) {
    case "capiche":
      return "bg-[#ed1c24]/[0.06]";
    case "aiko":
      return "bg-[#e8b923]/[0.12]";
    default:
      return "bg-[#1b35a8]/[0.05]";
  }
}

/** Aiko's gold is light → needs dark foreground text; the others use white. */
export function brandIsLight(brand: BrandSelection): boolean {
  return brand === "aiko";
}

export const brandWordmark: Record<BrandSelection, string> = {
  all: "BOOKENDS",
  capiche: "CAPICHE",
  aiko: "AIKO",
};
