// PDF export — PRD §6.2 / §13.1. Uses pdfmake. Cost columns are omitted when
// the viewer's visibility hides them (Capiche view).

import type { TDocumentDefinitions } from "pdfmake/interfaces";
import { calculateIngredientCost, round2 } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import { formatDate, formatINR } from "@/lib/utils";
import type { Recipe, RecipeIngredientWithMaterial } from "@/lib/data/types";
import type { ViewVisibility } from "@/lib/auth/permissions";

/** Lazy-load pdfmake + fonts only when an export is requested. */
async function loadPdfMake() {
  const [{ default: pdfMake }, fonts] = await Promise.all([
    import("pdfmake/build/pdfmake"),
    import("pdfmake/build/vfs_fonts"),
  ]);
  const pdfFonts = fonts as unknown as {
    pdfMake?: { vfs: Record<string, string> };
    vfs?: Record<string, string>;
  };
  const vfs = pdfFonts.pdfMake?.vfs ?? pdfFonts.vfs;
  (pdfMake as unknown as { vfs: Record<string, string> }).vfs = vfs!;
  return pdfMake;
}

export async function generateRecipePdf(
  recipe: Recipe,
  ingredients: RecipeIngredientWithMaterial[],
  foodCostPct: number,
  visibility?: ViewVisibility,
) {
  const showCost = visibility ? visibility.totalCost : true;
  const showUnitCost = visibility ? visibility.unitCosts : true;
  const showPrice = visibility ? visibility.sellingPrice : true;

  const headRow = ["#", "Ingredient", "Qty", "Unit"];
  if (showUnitCost) headRow.push("Unit Cost");
  if (showCost) headRow.push("Total");

  const body: string[][] = [headRow];
  ingredients.forEach((ing, idx) => {
    const m = ing.material;
    const cost =
      m && m.cost_per_base_unit !== null && canConvert(ing.unit_used, m.base_unit)
        ? calculateIngredientCost(m.cost_per_base_unit, ing.quantity_used, ing.unit_used, m.base_unit)
        : null;
    const row = [
      String(idx + 1),
      m?.ingredient_name ?? "—",
      String(ing.quantity_used),
      ing.unit_used,
    ];
    if (showUnitCost) row.push(formatINR(m?.cost_per_base_unit ?? null));
    if (showCost) row.push(formatINR(cost));
    body.push(row);
  });

  const total = recipe.total_cost ?? 0;
  const perPortion = recipe.cost_per_portion ?? 0;
  const suggested = perPortion > 0 ? round2(perPortion / (foodCostPct / 100)) : 0;
  const grossProfit = round2(suggested - perPortion);
  const grossMargin = suggested > 0 ? round2((grossProfit / suggested) * 100) : 0;

  const summary: [string, string][] = [];
  if (showCost) {
    summary.push(["Total Recipe Cost", formatINR(total)]);
    summary.push(["Cost Per Portion", formatINR(perPortion)]);
  }
  if (showPrice) {
    summary.push(["Food Cost %", `${foodCostPct}%`]);
    summary.push(["Suggested Selling Price", formatINR(suggested)]);
    summary.push(["Gross Profit", formatINR(grossProfit)]);
    summary.push(["Gross Margin", `${grossMargin}%`]);
  }

  const doc: TDocumentDefinitions = {
    pageMargins: [40, 40, 40, 50],
    content: [
      { text: "RECIPE COSTING SHEET", style: "title" },
      {
        style: "meta",
        columns: [
          [
            { text: `Recipe: ${recipe.recipe_name}`, bold: true },
            `Category: ${recipe.category}`,
            `Serving Size: ${recipe.serving_size} portions`,
          ],
          [
            `Status: ${recipe.status.toUpperCase()}`,
            recipe.approved_at ? `Approved On: ${formatDate(recipe.approved_at)}` : "",
            `Generated: ${formatDate(new Date())}`,
          ],
        ],
      },
      { text: "Ingredients", style: "section" },
      {
        table: { headerRows: 1, widths: tableWidths(headRow.length), body },
        layout: "lightHorizontalLines",
      },
      ...(summary.length
        ? [
            { text: "Cost Summary", style: "section" },
            {
              table: {
                widths: ["*", "auto"],
                body: summary.map(([k, v]) => [
                  { text: k, color: "#64748b" },
                  { text: v, alignment: "right" as const, bold: true },
                ]),
              },
              layout: "noBorders",
            },
          ]
        : []),
      { text: "Confidential", style: "footer", margin: [0, 20, 0, 0] },
    ],
    styles: {
      title: { fontSize: 16, bold: true, margin: [0, 0, 0, 12] },
      meta: { fontSize: 9, margin: [0, 0, 0, 12], lineHeight: 1.3 },
      section: { fontSize: 12, bold: true, margin: [0, 14, 0, 6] },
      footer: { fontSize: 8, color: "#94a3b8", alignment: "center" },
    },
    defaultStyle: { fontSize: 10 },
  };

  const filename = `${recipe.recipe_name.replace(/\s+/g, "")}_${formatDate(new Date()).replace(/[\s,]+/g, "")}_Costing.pdf`;
  const pdfMake = await loadPdfMake();
  pdfMake.createPdf(doc).download(filename);
}

function tableWidths(cols: number): (string | number)[] {
  // first col narrow, ingredient flexible, rest auto
  const widths: (string | number)[] = [18, "*"];
  for (let i = 2; i < cols; i++) widths.push("auto");
  return widths;
}
