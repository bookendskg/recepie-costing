import { useMemo } from "react";
import { useNavigate } from "react-router-dom";
import { PiggyBank, UtensilsCrossed, AlertTriangle, Coins, MoreVertical, Sprout, Trash2, ChevronRight, Store, Clock } from "lucide-react";
import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { cn, formatINR, formatDate } from "@/lib/utils";
import { BRANDS, outletById } from "@/lib/data/types";
import type { BrandSelection } from "./BrandFilter";
import { useRecipes } from "@/features/recipes/hooks";
import { useFoodCostPct, useAllSettings } from "@/features/settings/hooks";
import { useAllRecipeIngredients } from "@/features/reports/hooks";
import { useYields } from "@/features/yield/hooks";
import { useWastage } from "@/features/wastage/hooks";
import { useMaterials } from "@/features/raw-materials/hooks";
import {
  foodCostPctOf,
  menuPriceOf,
  profitMarginOf,
  fcTone,
  FC_TONE_STYLES,
} from "@/features/recipes/recipeMetrics";

// Brand accent theming for the dashboard data lines.
const THEME: Record<BrandSelection, { bar: string; accentText: string }> = {
  all: { bar: "bg-[#1b35a8]", accentText: "text-[#1b35a8]" }, // BOOKENDS blue
  capiche: { bar: "bg-[#ed1c24]", accentText: "text-[#ed1c24]" }, // Capiche red
  aiko: { bar: "bg-amber-400", accentText: "text-amber-600" }, // Aiko gold
};
const TONE_LABEL = { good: "On Target", warn: "Watch", bad: "Over" } as const;

export function OperationsDashboard({ brand }: { brand: BrandSelection }) {
  const t = THEME[brand];
  const navigate = useNavigate();
  const brandLabel = brand === "all" ? "BOOKENDS" : BRANDS.find((b) => b.value === brand)?.label ?? brand;
  const { data: recipes = [] } = useRecipes();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { data: settings = [] } = useAllSettings();
  const ingredients = useAllRecipeIngredients();
  const { data: yields = [] } = useYields();
  const { data: wastage = [] } = useWastage();
  const { data: materials = [] } = useMaterials();

  const criticalPct = Number(settings.find((s) => s.key === "margin_alert_pct")?.value ?? 35);

  // §16 Operational insights: missing prices, high-wastage ingredients, recent updates, outlet comparison.
  const insights = useMemo(() => {
    const matById = new Map(materials.map((m) => [m.id, m.ingredient_name]));
    const scoped = brand === "all" ? wastage : wastage.filter((w) => w.brand === brand);

    const missingPrices = materials.filter((m) => m.status === "active" && m.purchase_price == null);

    const wByIng = new Map<string, number>();
    scoped.filter((w) => w.item_type === "ingredient").forEach((w) => {
      const k = matById.get(w.ingredient_id ?? "") ?? "—";
      wByIng.set(k, (wByIng.get(k) ?? 0) + w.total_cost);
    });
    const highWastage = [...wByIng.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);

    const wByOutlet = new Map<string, number>();
    scoped.forEach((w) => wByOutlet.set(w.outlet_id, (wByOutlet.get(w.outlet_id) ?? 0) + w.total_cost));
    const maxOutlet = Math.max(1, ...[...wByOutlet.values()]);
    const outletCompare = [...wByOutlet.entries()]
      .map(([id, cost]) => ({ name: outletById(id)?.name ?? id, cost, pct: Math.round((cost / maxOutlet) * 100) }))
      .sort((a, b) => b.cost - a.cost);

    const recentRecipes = [...recipes]
      .filter((r) => !r.is_prep && (brand === "all" || r.brand === brand))
      .sort((a, b) => (b.updated_at ?? "").localeCompare(a.updated_at ?? ""))
      .slice(0, 5);

    return { missingPrices, highWastage, outletCompare, recentRecipes };
  }, [materials, wastage, recipes, brand]);

  // §16 Yield Management summary.
  const yieldStats = useMemo(() => {
    const n = yields.length;
    const avgYield = n ? yields.reduce((s, y) => s + y.yield_percentage, 0) / n : 0;
    const estWaste = yields.reduce((s, y) => s + y.wastage_quantity * y.original_unit_cost, 0);
    return { n, avgYield, estWaste };
  }, [yields]);

  // §16 Wastage Management summary (scoped to the selected brand).
  const wastageStats = useMemo(() => {
    const month = new Date().toISOString().slice(0, 7);
    const scoped = brand === "all" ? wastage : wastage.filter((w) => w.brand === brand);
    const monthCost = scoped.filter((w) => w.wastage_date.slice(0, 7) === month).reduce((s, w) => s + w.total_cost, 0);
    const total = scoped.reduce((s, w) => s + w.total_cost, 0);
    const byOutlet = new Map<string, number>();
    scoped.forEach((w) => byOutlet.set(w.outlet_id, (byOutlet.get(w.outlet_id) ?? 0) + w.total_cost));
    const topOutlet = [...byOutlet.entries()].sort((a, b) => b[1] - a[1])[0];
    return {
      monthCost,
      total,
      topOutlet: topOutlet ? outletById(topOutlet[0])?.name ?? "—" : "—",
      recent: scoped.slice(0, 5),
    };
  }, [wastage, brand]);

  // Real menu recipes for the selected brand (deduped by id; preps excluded).
  const items = useMemo(() => {
    const seen = new Set<string>();
    return recipes.filter((r) => {
      if (r.is_prep) return false;
      if (brand !== "all" && r.brand !== brand) return false;
      if (seen.has(r.id)) return false;
      seen.add(r.id);
      return true;
    });
  }, [recipes, brand]);
  const itemIds = useMemo(() => new Set(items.map((r) => r.id)), [items]);

  const rows = useMemo(
    () =>
      items
        .map((r) => ({
          id: r.id,
          name: r.recipe_name,
          category: r.category,
          cost: r.cost_per_portion ?? 0,
          price: menuPriceOf(r, foodCostPct),
          margin: profitMarginOf(r, foodCostPct),
          fc: foodCostPctOf(r, foodCostPct),
        }))
        .sort((a, b) => b.fc - a.fc),
    [items, foodCostPct],
  );

  const avgFc = rows.length ? rows.reduce((s, r) => s + r.fc, 0) / rows.length : 0;
  const avgCost = rows.length ? rows.reduce((s, r) => s + r.cost, 0) / rows.length : 0;
  const overTarget = rows.filter((r) => r.fc > criticalPct).length;

  // Cost by ingredient category, summed across the selected brand's recipes (real).
  const byCategory = useMemo(() => {
    const map = new Map<string, number>();
    (ingredients.data ?? []).forEach((i) => {
      if (!itemIds.has(i.recipe_id) || !i.material || i.calculated_cost == null) return;
      map.set(i.material.category, (map.get(i.material.category) ?? 0) + i.calculated_cost);
    });
    const total = [...map.values()].reduce((a, b) => a + b, 0) || 1;
    return [...map.entries()]
      .map(([name, cost]) => ({ name, cost, pct: Math.round((cost / total) * 100) }))
      .sort((a, b) => b.cost - a.cost);
  }, [ingredients.data, itemIds]);

  return (
    <>
      {/* Header */}
      <div className="mb-6">
        <h1 className="text-3xl font-bold tracking-tight">Costing Dashboard</h1>
        <p className="text-sm opacity-80">Recipe cost &amp; margin overview — {brandLabel}</p>
      </div>

      {/* KPI cards (all derived from your recipe data) */}
      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Kpi icon={<PiggyBank className={cn("h-5 w-5", t.accentText)} />} label="Avg Food Cost %" value={`${avgFc.toFixed(1)}%`}>
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-muted">
            <div className={cn("h-full rounded-full", t.bar)} style={{ width: `${Math.min(100, avgFc * 2)}%` }} />
          </div>
          <p className="mt-2 text-xs text-muted-foreground">Target {foodCostPct.toFixed(0)}%</p>
        </Kpi>
        <Kpi icon={<UtensilsCrossed className={cn("h-5 w-5", t.accentText)} />} label="Menu Items" value={`${rows.length}`}>
          <p className="mt-3 text-xs text-muted-foreground">Active recipes ({brandLabel})</p>
        </Kpi>
        <Kpi icon={<AlertTriangle className="h-5 w-5 text-red-500" />} label="Over Target" value={`${overTarget}`}>
          <p className="mt-3 text-xs text-muted-foreground">Above {criticalPct}% food cost</p>
        </Kpi>
        <Kpi icon={<Coins className="h-5 w-5 text-emerald-600" />} label="Avg Dish Cost" value={formatINR(avgCost).replace(".00", "")}>
          <p className="mt-3 text-xs text-muted-foreground">Cost per portion</p>
        </Kpi>
      </div>

      {/* Recipe cost breakdown (left) + Cost by Category (right) */}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="p-5 lg:col-span-2">
          <p className="mb-3 text-sm font-semibold">Recipe Cost Breakdown</p>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Recipe</TableHead>
                <TableHead className="text-right">Cost / Portion</TableHead>
                <TableHead className="text-right">Menu Price</TableHead>
                <TableHead className="text-right">Margin</TableHead>
                <TableHead className="text-right">Food Cost %</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} className="text-center text-muted-foreground">No recipes for this brand.</TableCell>
                </TableRow>
              ) : (
                rows.map((r) => {
                  const tone = fcTone(r.fc, criticalPct);
                  return (
                    <TableRow key={r.id} className="cursor-pointer transition-colors hover:bg-muted/50" onClick={() => navigate(`/recipes/${r.id}`)}>
                      <TableCell>
                        <p className="font-medium">{r.name}</p>
                        <p className="text-[11px] text-muted-foreground">{r.category}</p>
                      </TableCell>
                      <TableCell className="text-right font-mono">{formatINR(r.cost).replace(".00", "")}</TableCell>
                      <TableCell className="text-right font-mono">{formatINR(r.price).replace(".00", "")}</TableCell>
                      <TableCell className="text-right font-mono">{formatINR(r.margin).replace(".00", "")}</TableCell>
                      <TableCell className="text-right">
                        <span className={cn("rounded px-2 py-0.5 text-xs font-semibold", FC_TONE_STYLES[tone].badge)}>
                          {r.fc.toFixed(1)}% · {TONE_LABEL[tone]}
                        </span>
                      </TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </Card>

        <Card className="p-5">
          <div className="mb-4 flex items-center justify-between">
            <p className="text-sm font-semibold">Cost by Category</p>
            <MoreVertical className="h-4 w-4 text-muted-foreground" />
          </div>
          <div className="space-y-4">
            {byCategory.length === 0 ? (
              <p className="text-sm text-muted-foreground">No data.</p>
            ) : (
              byCategory.map((c) => (
                <div key={c.name}>
                  <div className="mb-1 flex items-center justify-between text-sm">
                    <span>{c.name}</span>
                    <span className="font-semibold">{c.pct}%</span>
                  </div>
                  <div className="h-1.5 overflow-hidden rounded-full bg-muted">
                    <div className={cn("h-full rounded-full", t.bar)} style={{ width: `${c.pct}%` }} />
                  </div>
                </div>
              ))
            )}
          </div>
          <div className="mt-5 space-y-1 border-t pt-4 text-xs">
            <p className="flex items-center gap-2"><span className={cn("h-2 w-2 rounded-full", t.bar)} /> Target Food Cost: {foodCostPct.toFixed(1)}%</p>
            <p className="flex items-center gap-2"><span className="h-2 w-2 rounded-full bg-slate-900" /> Actual Food Cost: {avgFc.toFixed(1)}%</p>
            <p className="pt-1 italic text-muted-foreground">
              Variance: {avgFc - foodCostPct >= 0 ? "+" : ""}{(avgFc - foodCostPct).toFixed(1)}%
            </p>
          </div>
        </Card>
      </div>

      {/* §16 Yield & Wastage summaries */}
      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <button onClick={() => navigate("/yield")} className="text-left">
          <Card className="h-full p-5 transition-shadow hover:shadow-md">
            <div className="mb-3 flex items-center justify-between">
              <p className="flex items-center gap-2 text-sm font-semibold"><Sprout className={cn("h-4 w-4", t.accentText)} /> Yield Management</p>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
            <div className="grid grid-cols-2 gap-3 text-sm">
              <Mini label="Avg Yield" value={`${yieldStats.avgYield.toFixed(1)}%`} />
              <Mini label="Ingredients" value={String(yieldStats.n)} />
              <Mini label="Est. Wastage Cost" value={formatINR(yieldStats.estWaste)} wide />
            </div>
          </Card>
        </button>

        <button onClick={() => navigate("/wastage")} className="text-left">
          <Card className="h-full p-5 transition-shadow hover:shadow-md">
            <div className="mb-3 flex items-center justify-between">
              <p className="flex items-center gap-2 text-sm font-semibold"><Trash2 className={cn("h-4 w-4", t.accentText)} /> Wastage — {brandLabel}</p>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
            <div className="grid grid-cols-2 gap-3 text-sm">
              <Mini label="This Month" value={formatINR(wastageStats.monthCost)} />
              <Mini label="All-Time" value={formatINR(wastageStats.total)} />
              <Mini label="Top Outlet" value={wastageStats.topOutlet} wide />
            </div>
          </Card>
        </button>

        <Card className="p-5">
          <p className="mb-3 text-sm font-semibold">Recent Wastage Entries</p>
          {wastageStats.recent.length === 0 ? (
            <p className="text-sm text-muted-foreground">No wastage recorded.</p>
          ) : (
            <div className="space-y-2">
              {wastageStats.recent.map((w) => (
                <div key={w.id} className="flex items-center justify-between gap-2 border-b border-dashed pb-1.5 text-sm last:border-0">
                  <div className="min-w-0">
                    <p className="truncate">{outletById(w.outlet_id)?.name ?? w.outlet_id}</p>
                    <p className="text-[11px] text-muted-foreground">{w.wastage_type} · {formatDate(w.wastage_date)}</p>
                  </div>
                  <span className="shrink-0 font-mono font-semibold">{formatINR(w.total_cost)}</span>
                </div>
              ))}
            </div>
          )}
        </Card>
      </div>

      {/* §16 Operational insights */}
      <div className="mt-4 grid gap-4 lg:grid-cols-2 xl:grid-cols-4">
        <Card className="p-5">
          <p className="mb-3 flex items-center gap-2 text-sm font-semibold"><AlertTriangle className="h-4 w-4 text-amber-500" /> Missing Ingredient Prices</p>
          {insights.missingPrices.length === 0 ? (
            <p className="text-sm text-muted-foreground">All active ingredients are priced. ✓</p>
          ) : (
            <>
              <p className="mb-2 text-2xl font-bold">{insights.missingPrices.length}</p>
              <div className="space-y-1">
                {insights.missingPrices.slice(0, 4).map((m) => (
                  <button key={m.id} onClick={() => navigate("/materials")} className="block w-full truncate text-left text-sm text-muted-foreground hover:text-foreground hover:underline">
                    {m.ingredient_name}
                  </button>
                ))}
                {insights.missingPrices.length > 4 && <p className="text-xs text-muted-foreground">+{insights.missingPrices.length - 4} more</p>}
              </div>
            </>
          )}
        </Card>

        <Card className="p-5">
          <p className="mb-3 flex items-center gap-2 text-sm font-semibold"><Trash2 className={cn("h-4 w-4", t.accentText)} /> High-Wastage Ingredients</p>
          {insights.highWastage.length === 0 ? (
            <p className="text-sm text-muted-foreground">No ingredient wastage recorded.</p>
          ) : (
            <div className="space-y-2">
              {insights.highWastage.map(([name, cost]) => (
                <div key={name} className="flex items-center justify-between gap-2 text-sm">
                  <span className="min-w-0 truncate">{name}</span>
                  <span className="shrink-0 font-mono font-semibold">{formatINR(cost)}</span>
                </div>
              ))}
            </div>
          )}
        </Card>

        <Card className="p-5">
          <p className="mb-3 flex items-center gap-2 text-sm font-semibold"><Store className={cn("h-4 w-4", t.accentText)} /> Outlet Comparison</p>
          {insights.outletCompare.length === 0 ? (
            <p className="text-sm text-muted-foreground">No wastage recorded.</p>
          ) : (
            <div className="space-y-2.5">
              {insights.outletCompare.map((o) => (
                <div key={o.name}>
                  <div className="mb-1 flex items-center justify-between text-xs">
                    <span className="truncate">{o.name}</span>
                    <span className="font-semibold">{formatINR(o.cost)}</span>
                  </div>
                  <div className="h-1.5 overflow-hidden rounded-full bg-muted">
                    <div className={cn("h-full rounded-full", t.bar)} style={{ width: `${o.pct}%` }} />
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>

        <Card className="p-5">
          <p className="mb-3 flex items-center gap-2 text-sm font-semibold"><Clock className="h-4 w-4 text-muted-foreground" /> Recent Recipe Updates</p>
          {insights.recentRecipes.length === 0 ? (
            <p className="text-sm text-muted-foreground">No recipes yet.</p>
          ) : (
            <div className="space-y-2">
              {insights.recentRecipes.map((r) => (
                <button key={r.id} onClick={() => navigate(`/recipes/${r.id}`)} className="flex w-full items-center justify-between gap-2 text-left text-sm hover:underline">
                  <span className="min-w-0 truncate">{r.recipe_name}</span>
                  <span className="shrink-0 text-[11px] text-muted-foreground">{formatDate(r.updated_at)}</span>
                </button>
              ))}
            </div>
          )}
        </Card>
      </div>
    </>
  );
}

function Mini({ label, value, wide }: { label: string; value: string; wide?: boolean }) {
  return (
    <div className={cn("rounded-md bg-muted/50 p-2.5", wide && "col-span-2")}>
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="mt-0.5 truncate text-base font-bold">{value}</p>
    </div>
  );
}

function Kpi({
  icon,
  label,
  value,
  children,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  children?: React.ReactNode;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-start justify-between">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
        {icon}
      </div>
      <div className="mt-2 text-2xl font-bold">{value}</div>
      {children}
    </Card>
  );
}
