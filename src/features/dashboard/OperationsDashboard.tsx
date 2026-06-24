import { useMemo } from "react";
import {
  PiggyBank,
  PackageX,
  Banknote,
  Timer,
  TrendingDown,
  TrendingUp,
  Calendar,
  FileDown,
  MoreVertical,
  Sparkles,
} from "lucide-react";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { cn, formatINR } from "@/lib/utils";
import type { Brand } from "@/lib/data/types";
import { BRANDS } from "@/lib/data/types";
import { useRecipes } from "@/features/recipes/hooks";
import { useFoodCostPct } from "@/features/settings/hooks";
import { useAllRecipeIngredients } from "@/features/reports/hooks";
import { foodCostPctOf, menuPriceOf } from "@/features/recipes/recipeMetrics";

// Brand accent theming for the operations dashboard.
const THEME: Record<Brand, { bar: string; aiCard: string; aiBtn: string; accentText: string; pill: string }> = {
  aiko: {
    bar: "bg-amber-400",
    aiCard: "bg-amber-400 text-amber-950",
    aiBtn: "bg-slate-900 text-white hover:bg-slate-800",
    accentText: "text-amber-600",
    pill: "bg-amber-400 text-amber-900",
  },
  capiche: {
    bar: "bg-[#ed1c24]",
    aiCard: "bg-[#ed1c24] text-white",
    aiBtn: "bg-white text-[#ed1c24] hover:bg-white/90",
    accentText: "text-[#ed1c24]",
    pill: "bg-[#ed1c24] text-white",
  },
};

// Illustrative ops figures (no POS/inventory feed in this build).
const LOW_STOCK = [
  { name: "Wagyu Ribeye (A5)", cat: "Proteins", level: "4.2 kg", reorder: "8.0 kg", status: "critical" },
  { name: "Truffle Oil (White)", cat: "Dry Store", level: "1.2 L", reorder: "2.5 L", status: "low" },
  { name: "San Marzano Tomatoes", cat: "Produce", level: "12 cases", reorder: "15 cases", status: "low" },
  { name: "Burrata (Artisanal)", cat: "Dairy", level: "15 units", reorder: "20 units", status: "atrisk" },
];
const STATUS_STYLE: Record<string, string> = {
  critical: "bg-red-600 text-white",
  low: "bg-amber-400 text-amber-900",
  atrisk: "bg-rose-100 text-rose-700",
};
const STATUS_LABEL: Record<string, string> = { critical: "Critical", low: "Low", atrisk: "At Risk" };

export function OperationsDashboard({ brand }: { brand: Brand }) {
  const t = THEME[brand];
  const brandLabel = BRANDS.find((b) => b.value === brand)?.label ?? brand;
  const { data: recipes = [] } = useRecipes();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const ingredients = useAllRecipeIngredients();

  const items = useMemo(() => recipes.filter((r) => r.brand === brand && !r.is_prep), [recipes, brand]);
  const itemIds = useMemo(() => new Set(items.map((r) => r.id)), [items]);

  const avgFc = useMemo(() => {
    const fcs = items.map((r) => foodCostPctOf(r, foodCostPct));
    return fcs.length ? fcs.reduce((a, b) => a + b, 0) / fcs.length : 0;
  }, [items, foodCostPct]);

  const byCategory = useMemo(() => {
    const map = new Map<string, number>();
    (ingredients.data ?? []).forEach((i) => {
      if (!itemIds.has(i.recipe_id) || !i.material || i.calculated_cost == null) return;
      map.set(i.material.category, (map.get(i.material.category) ?? 0) + i.calculated_cost);
    });
    const total = [...map.values()].reduce((a, b) => a + b, 0) || 1;
    return [...map.entries()]
      .map(([name, cost]) => ({ name, pct: Math.round((cost / total) * 100) }))
      .sort((a, b) => b.pct - a.pct)
      .slice(0, 4);
  }, [ingredients.data, itemIds]);

  const lossLeaders = useMemo(
    () =>
      [...items]
        .map((r) => {
          const menu = menuPriceOf(r, foodCostPct);
          const margin = menu > 0 ? Math.round(((menu - (r.cost_per_portion ?? 0)) / menu) * 100) : 0;
          return { name: r.recipe_name, menu, margin };
        })
        .sort((a, b) => a.margin - b.margin)
        .slice(0, 3),
    [items, foodCostPct],
  );

  return (
    <>
      {/* Header */}
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Operations Dashboard</h1>
          <p className="text-sm opacity-80">Real-time performance metrics for {brandLabel}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" className="bg-white/90 text-slate-900">
            <Calendar className="h-4 w-4" /> Last 24 Hours
          </Button>
          <Button variant="outline" className="bg-white/90 text-slate-900">
            <FileDown className="h-4 w-4" /> Export PDF
          </Button>
        </div>
      </div>

      {/* KPI cards */}
      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Kpi icon={<PiggyBank className={cn("h-5 w-5", t.accentText)} />} label="Food Cost %" value={`${avgFc.toFixed(1)}%`} delta={{ text: "1.2%", good: true }}>
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-muted">
            <div className={cn("h-full rounded-full", t.bar)} style={{ width: `${Math.min(100, avgFc * 2)}%` }} />
          </div>
        </Kpi>
        <Kpi icon={<PackageX className="h-5 w-5 text-red-500" />} label="Low Stock Alerts" value="12" delta={{ text: "4 today", good: false }}>
          <p className="mt-3 text-xs text-muted-foreground">4 critical actions required</p>
        </Kpi>
        <Kpi icon={<Banknote className="h-5 w-5 text-emerald-600" />} label="Daily Revenue" value={formatINR(482900).replace(".00", "")} delta={{ text: "8% vs Prev Sat", good: true }} />
        <Kpi icon={<Timer className="h-5 w-5 text-slate-500" />} label="Avg Ticket Time" value="14.2m" delta={{ text: "0.5m", good: true }}>
          <p className="mt-3 text-xs text-muted-foreground">Target: 15m</p>
        </Kpi>
      </div>

      {/* AI insight + Cost by category */}
      <div className="mb-6 grid gap-4 lg:grid-cols-3">
        <Card className={cn("flex flex-col border-0 p-6 lg:col-span-2", t.aiCard)}>
          <p className="flex items-center gap-2 text-sm font-semibold">
            <Sparkles className="h-4 w-4" /> AI Operation Insight
          </p>
          <p className="mt-4 text-lg font-semibold leading-relaxed">
            "Current inventory velocity suggests a potential <span className="underline">Truffle Oil shortage</span> by Tuesday.
            Recommended order volume: 15 units. We've also noticed a 12% lag in ticket times between 8:00 PM and 9:30 PM."
          </p>
          <div className="mt-6 flex gap-2">
            <Button className={t.aiBtn}>Review Order</Button>
            <Button variant="outline" className="border-white/40 bg-white/10 text-current hover:bg-white/20">Optimize Stations</Button>
          </div>
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
            <p className="flex items-center gap-2"><span className={cn("h-2 w-2 rounded-full", t.bar)} /> Theoretical Food Cost: {foodCostPct.toFixed(1)}%</p>
            <p className="flex items-center gap-2"><span className="h-2 w-2 rounded-full bg-slate-900" /> Actual Food Cost: {avgFc.toFixed(1)}%</p>
            <p className="pt-1 italic text-muted-foreground">
              Variance: {avgFc - foodCostPct >= 0 ? "+" : ""}{(avgFc - foodCostPct).toFixed(1)}% (Check Waste Logs)
            </p>
          </div>
        </Card>
      </div>

      {/* Inventory + Margin watch */}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="p-5 lg:col-span-2">
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm font-semibold">Inventory Depletion Alerts</p>
            <span className={cn("text-[11px] font-bold uppercase", t.accentText)}>View All Alerts</span>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Item Name</TableHead>
                <TableHead>Stock Level</TableHead>
                <TableHead>Reorder Point</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {LOW_STOCK.map((s) => (
                <TableRow key={s.name}>
                  <TableCell className="font-medium">{s.name}</TableCell>
                  <TableCell className="font-mono">{s.level}</TableCell>
                  <TableCell className="font-mono text-muted-foreground">{s.reorder}</TableCell>
                  <TableCell>
                    <span className={cn("rounded px-2 py-0.5 text-[10px] font-bold uppercase", STATUS_STYLE[s.status])}>
                      {STATUS_LABEL[s.status]}
                    </span>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>

        <Card className="p-5">
          <p className="text-sm font-semibold">Recipe Margin Watch</p>
          <p className="mb-4 text-[11px] font-bold uppercase tracking-wide text-muted-foreground">Top Loss Leaders</p>
          <div className="space-y-3">
            {lossLeaders.map((r) => (
              <div key={r.name} className="flex items-center justify-between border-b pb-2 last:border-0">
                <div>
                  <p className="font-semibold">{r.name}</p>
                  <p className="text-[11px] text-muted-foreground">Margin: {r.margin}%</p>
                </div>
                <span className={cn("font-mono font-bold", t.accentText)}>{formatINR(r.menu).replace(".00", "")}</span>
              </div>
            ))}
          </div>
          <Button variant="outline" className={cn("mt-4 w-full", t.accentText)}>Recalculate Margins</Button>
        </Card>
      </div>
    </>
  );
}

function Kpi({
  icon,
  label,
  value,
  delta,
  children,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  delta: { text: string; good: boolean };
  children?: React.ReactNode;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-start justify-between">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
        {icon}
      </div>
      <div className="mt-2 flex items-baseline gap-2">
        <span className="text-2xl font-bold">{value}</span>
        <span className={cn("inline-flex items-center gap-0.5 text-xs font-semibold", delta.good ? "text-emerald-600" : "text-red-600")}>
          {delta.good ? <TrendingDown className="h-3 w-3" /> : <TrendingUp className="h-3 w-3" />}
          {delta.good ? "-" : "+"}{delta.text}
        </span>
      </div>
      {children}
    </Card>
  );
}
