import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Card } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { cn, formatINR, formatDate } from "@/lib/utils";
import { round2 } from "@/lib/costing";
import { canConvert, getConversionFactor } from "@/lib/units";
import { useRecipes } from "@/features/recipes/hooks";
import { useAllRecipeIngredients } from "@/features/reports/hooks";
import { brandWordmark, brandAccentText } from "./brandTheme";
import type { BrandSelection } from "./BrandFilter";

// §16 Master Costing dashboard — Food + Packaging + Pricing control, modelled on
// the BOOKENDS master costing sheet. Every figure is derived from real recipe
// data (no seeded/placeholder numbers); empty until recipes exist. Re-scopes on
// the header brand toggle: BOOKENDS = both brands, Capiche / Aiko = that brand.

const HIGH_FC = 35; // ">35% High" band from the sheet legend
const MODERATE_FC = 25; // "25%–35% Moderate"

type Tone = "good" | "moderate" | "high" | "missing";
function fcBand(fc: number | null): Tone {
  if (fc == null) return "missing";
  if (fc > HIGH_FC) return "high";
  if (fc >= MODERATE_FC) return "moderate";
  return "good";
}
const TONE_CELL: Record<Tone, string> = {
  good: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
  moderate: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
  high: "bg-red-500/15 text-red-600 dark:text-red-400 font-semibold",
  missing: "text-muted-foreground",
};

interface Row {
  id: string;
  name: string;
  category: string;
  making: number;
  pkg: number;
  selling: number;
  fcWith: number | null;
  fcWithout: number | null;
  weight: number;
  missing: boolean;
}

export function MasterCostingDashboard({ brand }: { brand: BrandSelection }) {
  const navigate = useNavigate();
  const [showMissing, setShowMissing] = useState(false);
  const { data: recipes = [], isLoading } = useRecipes();
  const { data: allIngredients = [] } = useAllRecipeIngredients();

  // Dish weight (g) = sum of gram-convertible ingredient/prep lines per recipe.
  const weightByRecipe = useMemo(() => {
    const m = new Map<string, number>();
    for (const ri of allIngredients) {
      if (!canConvert(ri.unit_used, "Gram")) continue;
      const grams = ri.quantity_used * getConversionFactor(ri.unit_used, "Gram");
      m.set(ri.recipe_id, (m.get(ri.recipe_id) ?? 0) + grams);
    }
    return m;
  }, [allIngredients]);

  const data = useMemo(() => {
    // One row per recipe — exclude size-variant children (the 11" that pairs each
    // 15" master) so pizzas don't appear as duplicate entries.
    const items = recipes.filter((r) => !r.is_prep && !r.parent_recipe_id && (brand === "all" || r.brand === brand));
    const rows: Row[] = items.map((r) => {
      const making = r.cost_per_portion ?? 0;
      const pkg = r.packaging_cost ?? 0;
      const selling = r.selling_price ?? 0;
      const hasData = making > 0 && selling > 0;
      return {
        id: r.id,
        name: r.recipe_name,
        category: r.category || "Uncategorised",
        making,
        pkg,
        selling,
        fcWith: hasData ? round2(((making + pkg) / selling) * 100) : null,
        fcWithout: hasData ? round2((making / selling) * 100) : null,
        weight: weightByRecipe.get(r.id) ?? 0,
        missing: !hasData,
      };
    });

    const avg = (arr: Row[], pick: (r: Row) => number | null) => {
      const vals = arr.map(pick).filter((v): v is number => v != null);
      return vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : 0;
    };

    const byCat = new Map<string, Row[]>();
    for (const row of rows) {
      const list = byCat.get(row.category) ?? [];
      list.push(row);
      byCat.set(row.category, list);
    }
    const categories = [...byCat.entries()]
      .map(([name, list]) => ({
        name,
        rows: list,
        count: list.length,
        avgWith: avg(list, (r) => r.fcWith),
        avgWithout: avg(list, (r) => r.fcWithout),
      }))
      .sort((a, b) => a.name.localeCompare(b.name));

    const lastUpdated = rows.length
      ? recipes
          .filter((r) => !r.is_prep && !r.parent_recipe_id && (brand === "all" || r.brand === brand))
          .reduce((acc, r) => (r.updated_at > acc ? r.updated_at : acc), "")
      : "";

    return {
      categories,
      totalItems: rows.length,
      avgWith: avg(rows, (r) => r.fcWith),
      avgWithout: avg(rows, (r) => r.fcWithout),
      highCost: rows.filter((r) => r.fcWith != null && r.fcWith > HIGH_FC).length,
      missing: rows.filter((r) => r.missing).length,
      missingItems: rows.filter((r) => r.missing).map((r) => ({ id: r.id, name: r.name, category: r.category })),
      lastUpdated,
    };
  }, [recipes, brand, weightByRecipe]);

  const title = `${brandWordmark[brand]} MASTER COSTING`;
  const accent = brandAccentText(brand);

  return (
    <div className="space-y-4">
      {/* Header bar */}
      <Card className="overflow-hidden border-0 bg-slate-900 text-white dark:bg-slate-950">
        <div className="flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-4">
            <div className={cn("rounded-md bg-white px-4 py-2 text-xl font-extrabold tracking-wide shadow-sm", accent)}>
              {brandWordmark[brand]}
            </div>
            <div>
              <p className="text-base font-bold sm:text-lg">{title}</p>
              <p className="text-xs text-slate-300">Food + Packaging + Pricing Control</p>
            </div>
          </div>
          <div className="text-left sm:text-right">
            <p className="text-[11px] uppercase tracking-wide text-slate-400">Last Updated</p>
            <p className="text-sm font-semibold">{data.lastUpdated ? formatDate(data.lastUpdated) : "—"}</p>
          </div>
        </div>
      </Card>

      {/* KPI row */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <Kpi label="Total Items" value={String(data.totalItems)} accent={accent} />
        <Kpi label="Avg FC % With Pkg" value={`${data.avgWith.toFixed(2)}%`} accent={accent} />
        <Kpi label="Avg FC % Without Pkg" value={`${data.avgWithout.toFixed(2)}%`} accent={accent} />
        <Kpi label="High Cost Items" value={String(data.highCost)} tone={data.highCost > 0 ? "high" : undefined} />
        <Kpi
          label="Missing Data"
          value={String(data.missing)}
          tone={data.missing > 0 ? "warn" : undefined}
          onClick={data.missing > 0 ? () => setShowMissing(true) : undefined}
        />
      </div>

      {/* Drill-in: the recipes counted as "Missing Data" */}
      <Dialog open={showMissing} onOpenChange={setShowMissing}>
        <DialogContent className="max-h-[80vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Missing data — {data.missing} recipe(s)</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            No food cost or selling price yet, so these are excluded from the averages. Tap one to open and fix it.
          </p>
          <ul className="divide-y">
            {data.missingItems.map((r) => (
              <li key={r.id}>
                <button
                  type="button"
                  onClick={() => { setShowMissing(false); navigate(`/recipes/${r.id}`); }}
                  className="flex w-full items-center justify-between gap-3 py-2 text-left text-sm hover:text-emerald-700"
                >
                  <span className="font-medium">{r.name}</span>
                  <span className="shrink-0 text-xs text-muted-foreground">{r.category}</span>
                </button>
              </li>
            ))}
          </ul>
        </DialogContent>
      </Dialog>

      <div className="grid gap-4 xl:grid-cols-[2fr_1fr]">
        {/* Costing table */}
        <Card className="overflow-hidden">
          {isLoading ? (
            <div className="p-8 text-center text-sm text-muted-foreground">Loading costing…</div>
          ) : data.totalItems === 0 ? (
            <div className="p-10 text-center">
              <p className="font-semibold">No menu items costed yet</p>
              <p className="mt-1 text-sm text-muted-foreground">
                Add recipes with a making cost and selling price to populate the {brandWordmark[brand]} master costing.
              </p>
            </div>
          ) : (
            <div className="max-h-[640px] overflow-auto">
              <table className="w-full border-collapse text-sm">
                <thead className="sticky top-0 z-10 bg-muted/95 backdrop-blur">
                  <tr className="text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                    <th className="w-8 px-2 py-2 text-right">#</th>
                    <th className="px-2 py-2">Food Name</th>
                    <th className="px-2 py-2 text-right">Making ₹</th>
                    <th className="px-2 py-2 text-right">Pkg ₹</th>
                    <th className="px-2 py-2 text-right">Selling ₹</th>
                    <th className="px-2 py-2 text-right">FC % w/ Pkg</th>
                    <th className="px-2 py-2 text-right">FC % w/o Pkg</th>
                    <th className="px-2 py-2 text-right">Weight</th>
                  </tr>
                </thead>
                <tbody>
                  {(() => {
                    let n = 0;
                    return data.categories.map((cat) => (
                      <CategoryGroup key={cat.name} name={cat.name}>
                        {cat.rows.map((row) => {
                          n += 1;
                          const tone = fcBand(row.fcWith);
                          return (
                            <tr
                              key={row.id}
                              onClick={() => navigate(`/recipes/${row.id}`)}
                              className={cn(
                                "cursor-pointer border-b border-border/60 hover:bg-muted/50",
                                row.missing && "bg-red-500/5",
                              )}
                            >
                              <td className="px-2 py-1.5 text-right text-muted-foreground">{n}</td>
                              <td className="px-2 py-1.5 font-medium">{row.name}</td>
                              <td className="px-2 py-1.5 text-right font-mono">{row.making > 0 ? formatINR(row.making) : "—"}</td>
                              <td className="px-2 py-1.5 text-right font-mono text-muted-foreground">{row.pkg > 0 ? formatINR(row.pkg) : "—"}</td>
                              <td className="px-2 py-1.5 text-right font-mono">{row.selling > 0 ? formatINR(row.selling) : "—"}</td>
                              <td className={cn("px-2 py-1.5 text-right font-mono", TONE_CELL[tone])}>
                                {row.fcWith != null ? `${row.fcWith.toFixed(2)}%` : "—"}
                              </td>
                              <td className={cn("px-2 py-1.5 text-right font-mono", TONE_CELL[fcBand(row.fcWithout)])}>
                                {row.fcWithout != null ? `${row.fcWithout.toFixed(2)}%` : "—"}
                              </td>
                              <td className="px-2 py-1.5 text-right text-muted-foreground">{row.weight > 0 ? `${Math.round(row.weight)}g` : "—"}</td>
                            </tr>
                          );
                        })}
                      </CategoryGroup>
                    ));
                  })()}
                </tbody>
              </table>
            </div>
          )}
        </Card>

        {/* Sidebar panels */}
        <div className="space-y-4">
          <Card className="overflow-hidden">
            <p className="border-b bg-muted/60 px-4 py-2 text-sm font-semibold">Category Summary</p>
            {data.categories.length === 0 ? (
              <p className="p-4 text-sm text-muted-foreground">No categories yet.</p>
            ) : (
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                    <th className="px-3 py-1.5">Category</th>
                    <th className="px-3 py-1.5 text-right">Items</th>
                    <th className="px-3 py-1.5 text-right">w/ Pkg</th>
                    <th className="px-3 py-1.5 text-right">w/o Pkg</th>
                  </tr>
                </thead>
                <tbody>
                  {data.categories.map((c) => (
                    <tr key={c.name} className="border-t">
                      <td className="px-3 py-1.5">{c.name}</td>
                      <td className="px-3 py-1.5 text-right font-mono">{c.count}</td>
                      <td className="px-3 py-1.5 text-right font-mono">{c.avgWith.toFixed(2)}%</td>
                      <td className="px-3 py-1.5 text-right font-mono">{c.avgWithout.toFixed(2)}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </Card>

          <Card className="p-4">
            <p className="mb-2 text-sm font-semibold">Cost % Legend</p>
            <ul className="space-y-1.5 text-sm">
              <LegendRow swatch="bg-emerald-500/20" label="0% – 25%" tag="Good" />
              <LegendRow swatch="bg-amber-500/20" label="25% – 35%" tag="Moderate" />
              <LegendRow swatch="bg-red-500/25" label="> 35%" tag="High" />
              <LegendRow swatch="bg-muted" label="No cost / price" tag="Missing Data" />
            </ul>
          </Card>

          <Card className="p-4">
            <p className="mb-2 text-sm font-semibold">Formula Reference</p>
            <div className="space-y-1.5 text-xs text-muted-foreground">
              <p><span className="font-medium text-foreground">FC % With Pkg</span> = (Making Cost + Packaging) / Selling Price</p>
              <p><span className="font-medium text-foreground">FC % Without Pkg</span> = Making Cost / Selling Price</p>
            </div>
          </Card>

          <Card className="p-4">
            <p className="mb-2 text-sm font-semibold">Notes</p>
            <ul className="list-disc space-y-1 pl-4 text-xs text-muted-foreground">
              <li>High food cost items require recipe review and cost optimisation.</li>
              <li>Update making cost, packaging and selling price regularly.</li>
              <li>Final weight helps portion control and consistency.</li>
              <li>Missing data is excluded from the average food-cost figures.</li>
            </ul>
          </Card>
        </div>
      </div>
    </div>
  );
}

function CategoryGroup({ name, children }: { name: string; children: React.ReactNode }) {
  return (
    <>
      <tr className="bg-muted/40">
        <td colSpan={8} className="px-2 py-1.5 text-xs font-bold uppercase tracking-wide text-foreground">
          {name}
        </td>
      </tr>
      {children}
    </>
  );
}

function Kpi({ label, value, accent, tone, onClick }: { label: string; value: string; accent?: string; tone?: "high" | "warn"; onClick?: () => void }) {
  const valueColor = tone === "high" ? "text-red-600 dark:text-red-400" : tone === "warn" ? "text-amber-600 dark:text-amber-400" : accent;
  return (
    <Card
      className={cn("p-4", onClick && "cursor-pointer transition-colors hover:bg-muted/50")}
      onClick={onClick}
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onClick(); } } : undefined}
    >
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}{onClick && <span className="ml-1 text-muted-foreground/70">›</span>}</p>
      <p className={cn("mt-1 text-2xl font-bold", valueColor)}>{value}</p>
    </Card>
  );
}

function LegendRow({ swatch, label, tag }: { swatch: string; label: string; tag: string }) {
  return (
    <li className="flex items-center gap-2">
      <span className={cn("h-3.5 w-6 shrink-0 rounded", swatch)} />
      <span className="font-medium">{label}</span>
      <span className="ml-auto text-muted-foreground">{tag}</span>
    </li>
  );
}
