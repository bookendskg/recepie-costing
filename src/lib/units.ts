// Unit conversion engine — PRD §4.2 (Unit Conversion Matrix) & §10.1.
// Pure, backend-agnostic. Never changes when Supabase is added.

export const WEIGHT_UNITS = ["KG", "Gram"] as const;
export const VOLUME_UNITS = ["Litre", "ML"] as const;
export const COUNT_UNITS = ["Piece", "Packet", "Bottle", "Can"] as const;

export const PURCHASE_UNITS = [
  "KG",
  "Gram",
  "Litre",
  "ML",
  "Piece",
  "Packet",
  "Bottle",
  "Can",
] as const;

export const BASE_UNITS = [
  "Gram",
  "ML",
  "Piece",
  "Packet",
  "Bottle",
  "Can",
] as const;

export type Unit = (typeof PURCHASE_UNITS)[number];

type UnitFamily = "weight" | "volume" | "count";

export function getUnitFamily(unit: string): UnitFamily | null {
  if ((WEIGHT_UNITS as readonly string[]).includes(unit)) return "weight";
  if ((VOLUME_UNITS as readonly string[]).includes(unit)) return "volume";
  if ((COUNT_UNITS as readonly string[]).includes(unit)) return "count";
  return null;
}

/**
 * Returns true if a quantity in `from` can be converted into `to`.
 * Weight units interchange; volume units interchange; count units only
 * convert to themselves (Piece→Piece, etc.) — never across families.
 */
export function canConvert(from: string, to: string): boolean {
  const f = getUnitFamily(from);
  const t = getUnitFamily(to);
  if (!f || !t) return false;
  if (f !== t) return false;
  if (f === "count") return from === to;
  return true;
}

/**
 * Units a recipe line may use given the ingredient's base unit. Weight base
 * accepts KG/Gram; volume base accepts Litre/ML; count base accepts only itself.
 */
export function compatibleUnits(baseUnit: string): string[] {
  const family = getUnitFamily(baseUnit);
  if (family === "weight") return ["Gram", "KG"];
  if (family === "volume") return ["ML", "Litre"];
  return [baseUnit];
}

/**
 * Conversion factor to multiply a quantity in `from` to express it in `to`.
 * PRD §4.2: KG→Gram ×1000, Litre→ML ×1000, same→same ×1, etc.
 * Throws on an invalid/incompatible pair.
 */
export function getConversionFactor(from: string, to: string): number {
  if (from === to) return 1;
  if (from === "KG" && to === "Gram") return 1000;
  if (from === "Gram" && to === "KG") return 1 / 1000;
  if (from === "Litre" && to === "ML") return 1000;
  if (from === "ML" && to === "Litre") return 1 / 1000;
  throw new Error(`Invalid unit conversion: ${from} → ${to}`);
}
