import { create } from "zustand";
import type { BrandSelection } from "./BrandFilter";

// Shared dashboard brand selection so the app layout can tint the whole UI to
// match the active brand.
interface BrandState {
  brand: BrandSelection;
  setBrand: (brand: BrandSelection) => void;
}

export const useDashboardBrand = create<BrandState>((set) => ({
  brand: "all",
  setBrand: (brand) => set({ brand }),
}));

/** Soft brand-tinted page background (light mode). */
export function brandBgClass(brand: BrandSelection): string {
  switch (brand) {
    case "capiche":
      return "bg-[#fef2f2]"; // soft Capiche red
    case "aiko":
      return "bg-[#fffbeb]"; // soft Aiko gold
    default:
      return "bg-[#eff6ff]"; // soft BOOKENDS blue
  }
}

/** Brand accent text colour (logos, headings, links). */
export function brandAccentText(brand: BrandSelection): string {
  switch (brand) {
    case "capiche":
      return "text-[#ed1c24]";
    case "aiko":
      return "text-amber-600";
    default:
      return "text-[#1b35a8]";
  }
}

/** Active sidebar nav item — light brand pill + brand text. */
export function brandActiveNav(brand: BrandSelection): string {
  switch (brand) {
    case "capiche":
      return "bg-[#fee2e2] text-[#ed1c24]";
    case "aiko":
      return "bg-amber-100 text-amber-800";
    default:
      return "bg-blue-100 text-blue-800";
  }
}

export const brandWordmark: Record<BrandSelection, string> = {
  all: "BOOKENDS",
  capiche: "CAPICHE",
  aiko: "AIKO",
};
