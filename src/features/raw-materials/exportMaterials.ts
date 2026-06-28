import { formatDate, formatQuantityWithUnit } from "@/lib/utils";
import type { RawMaterial } from "@/lib/data/types";

/** Export a list of raw materials to a single-sheet .xlsx (lazy-loads SheetJS). */
export async function exportMaterials(materials: RawMaterial[], label: string) {
  const XLSX = await import("xlsx");
  const rows = materials.map((m) => ({
    Ingredient: m.ingredient_name,
    Category: m.category,
    Supplier: m.supplier_name ?? "",
    "Purchase Price (₹)": m.purchase_price ?? "",
    Quantity: formatQuantityWithUnit(m.purchase_quantity, m.purchase_unit, { humanize: false }),
    "Base Unit": m.base_unit,
    "Cost / Base Unit (₹)": m.cost_per_base_unit ?? "",
    Status: m.status,
    Notes: m.notes ?? "",
    "Last Price Update": m.last_price_update ? formatDate(m.last_price_update) : "",
  }));
  const ws = XLSX.utils.json_to_sheet(rows);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Ingredients");
  XLSX.writeFile(wb, `Ingredients_${label}.xlsx`);
}
