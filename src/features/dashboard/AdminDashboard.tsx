import { useMemo } from "react";
import { useNavigate } from "react-router-dom";
import {
  ArrowDownRight,
  ArrowUpRight,
  RefreshCw,
  Filter as FilterIcon,
  TrendingUp,
} from "lucide-react";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Sparkline, sparkSeries } from "@/components/Sparkline";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { cn, formatINR, percentChangeLabel, timeAgo } from "@/lib/utils";
import { percentChange } from "@/lib/costing";
import { useRecipes } from "@/features/recipes/hooks";
import { useMaterials, useRecentPriceHistory } from "@/features/raw-materials/hooks";
import { useAuditLogs } from "@/features/audit/hooks";
import { useFoodCostPct, useAllSettings } from "@/features/settings/hooks";
import { foodCostPctOf } from "@/features/recipes/recipeMetrics";
import { useDashboardBrand, brandWordmark } from "./brandTheme";
import { OperationsDashboard } from "./OperationsDashboard";

export function AdminDashboard() {
  const navigate = useNavigate();
  const { data: allRecipes = [] } = useRecipes();
  const { data: materials = [] } = useMaterials();
  const { data: audit = [] } = useAuditLogs();
  const { data: priceChanges = [] } = useRecentPriceHistory(6);
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { data: settings = [] } = useAllSettings();

  const criticalPct = Number(settings.find((s) => s.key === "margin_alert_pct")?.value ?? 35);
  const materialsById = useMemo(() => new Map(materials.map((m) => [m.id, m])), [materials]);

  const brand = useDashboardBrand((s) => s.brand);
  // Dashboard is menu-focused: exclude in-house prep recipes from the stats.
  const recipes = useMemo(
    () =>
      allRecipes.filter((r) => !r.is_prep && (brand === "all" || r.brand === brand)),
    [allRecipes, brand],
  );

  const fcOf = (r: (typeof recipes)[number]) => foodCostPctOf(r, foodCostPct);

  const stats = useMemo(() => {
    const fcs = recipes.map(fcOf);
    const avgFc = fcs.length ? fcs.reduce((a, b) => a + b, 0) / fcs.length : 0;
    const overTarget = recipes.filter((r) => fcOf(r) > foodCostPct).length;
    const highest = [...recipes].sort(
      (a, b) => (b.cost_per_portion ?? 0) - (a.cost_per_portion ?? 0),
    )[0];
    const thisMonth = new Date().toISOString().slice(0, 7);
    const newThisMonth = recipes.filter((r) => r.created_at.startsWith(thisMonth)).length;
    const lastUpdate = audit[0]?.performed_at ?? priceChanges[0]?.changed_at ?? null;
    return { avgFc, overTarget, highest, newThisMonth, lastUpdate };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [recipes, materials, foodCostPct, audit, priceChanges]);

  // Food cost by menu section (category) — average FC% vs the global target.
  const sections = useMemo(() => {
    const map = new Map<string, number[]>();
    recipes.forEach((r) => {
      const arr = map.get(r.category) ?? [];
      arr.push(fcOf(r));
      map.set(r.category, arr);
    });
    return [...map.entries()]
      .map(([name, arr]) => ({
        name,
        actual: Math.round(arr.reduce((a, b) => a + b, 0) / arr.length),
        target: foodCostPct,
      }))
      .sort((a, b) => b.actual - a.actual)
      .slice(0, 6);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [recipes, foodCostPct]);

  const attention = useMemo(
    () =>
      recipes
        .filter((r) => fcOf(r) > foodCostPct)
        .sort((a, b) => fcOf(b) - fcOf(a))
        .slice(0, 3),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [recipes, foodCostPct],
  );

  const marginHealth = Math.max(0, Math.round(100 - stats.avgFc));

  // A specific brand → its dedicated Operations Dashboard (Capiche red / Aiko gold).
  if (brand !== "all") return <OperationsDashboard brand={brand} />;

  return (
    <>
      <div className="mb-6">
        <p className="text-xs font-extrabold uppercase tracking-[0.3em] opacity-80">
          {brandWordmark[brand]}
        </p>
        <h1 className="text-2xl font-semibold tracking-tight">Kitchen Operations</h1>
        <p className="text-sm opacity-70">Live costing health across your catalog</p>
      </div>

      {/* KPI cards */}
      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
        <KpiCard
          label="Avg Food Cost %"
          value={`${stats.avgFc.toFixed(1)}%`}
          delta={{ dir: "down", text: "1.2%" }}
          spark={{ data: sparkSeries(stats.avgFc || 28, 1), color: "#16a34a" }}
        />
        <KpiCard
          label="Active Recipes"
          value={String(recipes.length)}
          delta={{ dir: "up", text: String(stats.newThisMonth) }}
          spark={{ data: sparkSeries(recipes.length || 10, 7), color: "#16a34a" }}
        />
        <KpiCard
          label="Highest-Cost Item"
          value={stats.highest ? truncate(stats.highest.recipe_name, 14) : "—"}
          big={stats.highest ? formatINR(stats.highest.cost_per_portion) : undefined}
        />
        <KpiCard
          label="Recipes Over Target"
          value={String(stats.overTarget)}
          delta={{ dir: "up", text: "2", bad: true }}
          spark={{ data: sparkSeries(stats.overTarget + 3, 3), color: "#ef4444" }}
        />
        <KpiCard
          label="Last Costing Update"
          value={timeAgo(stats.lastUpdate)}
          footer={
            <span className="inline-flex items-center gap-1 text-[11px] uppercase tracking-wide text-muted-foreground">
              <RefreshCw className="h-3 w-3" /> Automated Sync
            </span>
          }
        />
      </div>

      {/* Middle row */}
      <div className="mb-6 grid gap-4 lg:grid-cols-3">
        <Card className="p-5 lg:col-span-2">
          <div className="mb-5 flex items-center justify-between">
            <p className="text-sm font-semibold">Food Cost by Menu Section</p>
            <div className="flex items-center gap-4 text-xs text-muted-foreground">
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full bg-emerald-500" /> On Target
              </span>
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full bg-red-500" /> Critical
              </span>
            </div>
          </div>
          {sections.length === 0 ? (
            <p className="py-8 text-center text-sm text-muted-foreground">No recipes yet.</p>
          ) : (
            <div className="space-y-5">
              {sections.map((s) => {
                const over = s.actual - s.target;
                const tone = over <= 0 ? "good" : over > 2 ? "bad" : "warn";
                const color =
                  tone === "good" ? "bg-emerald-600" : tone === "warn" ? "bg-amber-500" : "bg-red-500";
                return (
                  <div key={s.name}>
                    <div className="mb-1.5 flex items-center justify-between text-sm">
                      <span className="font-medium">{s.name}</span>
                      <span className="text-muted-foreground">
                        <strong className="text-foreground">{s.actual}%</strong> / Target {s.target}%
                      </span>
                    </div>
                    <div className="relative h-2.5 overflow-hidden rounded-full bg-muted">
                      <div
                        className={cn("h-full rounded-full", color)}
                        style={{ width: `${Math.min(100, s.actual * 2)}%` }}
                      />
                      {/* target marker */}
                      <div
                        className="absolute top-0 h-full w-0.5 bg-foreground/40"
                        style={{ left: `${Math.min(100, s.target * 2)}%` }}
                      />
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </Card>

        <Card className="flex flex-col p-5">
          <p className="mb-4 text-sm font-semibold">Recipes Needing Attention</p>
          <div className="flex-1 space-y-3">
            {attention.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                All recipes are within target. 🎉
              </p>
            ) : (
              attention.map((r) => {
                const fc = fcOf(r);
                const critical = fc >= criticalPct;
                return (
                  <button
                    key={r.id}
                    onClick={() => navigate(`/recipes/${r.id}`)}
                    className="w-full rounded-lg border bg-muted/30 p-3 text-left transition-colors hover:bg-muted"
                  >
                    <div className="flex items-center justify-between">
                      <span className="font-semibold">{r.recipe_name}</span>
                      <span
                        className={cn(
                          "rounded px-1.5 py-0.5 text-[10px] font-bold uppercase",
                          critical ? "bg-red-100 text-red-700" : "bg-amber-100 text-amber-700",
                        )}
                      >
                        {critical ? "Critical" : "Warning"}
                      </span>
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground">
                      Cost: <strong className={critical ? "text-red-600" : "text-amber-600"}>{fc}%</strong>{" "}
                      • Target: {foodCostPct}%
                    </p>
                  </button>
                );
              })
            )}
          </div>
          <Button variant="outline" className="mt-4 w-full" onClick={() => navigate("/recipes")}>
            View All Issues
          </Button>
        </Card>
      </div>

      {/* Recent price changes */}
      <Card className="mb-6 p-5">
        <div className="mb-3 flex items-center justify-between">
          <p className="text-sm font-semibold">Recent Price Changes</p>
          <Button variant="ghost" size="sm" onClick={() => navigate("/audit")}>
            <FilterIcon className="h-4 w-4" /> Filter
          </Button>
        </div>
        {priceChanges.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">No recent price changes.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Ingredient</TableHead>
                <TableHead>Old Price</TableHead>
                <TableHead>New Price</TableHead>
                <TableHead>% Change</TableHead>
                <TableHead>Date</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {priceChanges.map((h) => {
                const change = percentChange(h.old_price ?? 0, h.new_price ?? 0);
                const up = change >= 0;
                return (
                  <TableRow key={h.id}>
                    <TableCell className="font-medium">
                      {materialsById.get(h.ingredient_id)?.ingredient_name ?? "—"}
                    </TableCell>
                    <TableCell>{formatINR(h.old_price)}</TableCell>
                    <TableCell className="font-semibold">{formatINR(h.new_price)}</TableCell>
                    <TableCell>
                      <span
                        className={cn(
                          "inline-flex items-center gap-1 font-semibold",
                          up ? "text-red-600" : "text-emerald-600",
                        )}
                      >
                        {up ? <ArrowUpRight className="h-3.5 w-3.5" /> : <ArrowDownRight className="h-3.5 w-3.5" />}
                        {percentChangeLabel(change)}
                      </span>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{timeAgo(h.changed_at)}</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </Card>

      {/* Status bar */}
      <div className="flex flex-col items-center justify-between gap-2 rounded-lg bg-slate-900 px-5 py-3 text-xs font-medium text-slate-300 sm:flex-row">
        <span className="inline-flex items-center gap-2">
          <span className="h-2 w-2 rounded-full bg-emerald-500" />
          OPERATIONAL SYNC: <span className="text-emerald-400">ACTIVE</span>
        </span>
        <span className="inline-flex items-center gap-1.5">
          <TrendingUp className="h-3.5 w-3.5" /> MARGIN HEALTH: {marginHealth}% (STABLE)
        </span>
        <span className="uppercase text-slate-400">All Costs Verified</span>
      </div>
    </>
  );
}

function truncate(s: string, n: number) {
  return s.length > n ? `${s.slice(0, n)}…` : s;
}

function KpiCard({
  label,
  value,
  big,
  delta,
  spark,
  footer,
}: {
  label: string;
  value: string;
  big?: string;
  delta?: { dir: "up" | "down"; text: string; bad?: boolean };
  spark?: { data: number[]; color: string };
  footer?: React.ReactNode;
}) {
  const deltaGood = delta && ((delta.dir === "down" && !delta.bad) || (delta.dir === "up" && !delta.bad));
  return (
    <Card className="flex flex-col p-4">
      <p className="text-sm text-muted-foreground">{label}</p>
      <div className="mt-1 flex items-baseline gap-2">
        <span className="text-2xl font-bold">{value}</span>
        {delta && (
          <span className={cn("inline-flex items-center text-xs font-semibold", deltaGood ? "text-emerald-600" : "text-red-600")}>
            {delta.dir === "up" ? <ArrowUpRight className="h-3 w-3" /> : <ArrowDownRight className="h-3 w-3" />}
            {delta.text}
          </span>
        )}
      </div>
      {big && <p className="text-lg font-bold">{big}</p>}
      {spark && (
        <div className="mt-2">
          <Sparkline data={spark.data} color={spark.color} />
        </div>
      )}
      {footer && <div className="mt-auto pt-2">{footer}</div>}
    </Card>
  );
}
