import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  ArrowDown,
  ArrowUp,
  ArrowUpDown,
  Calculator,
  MoreVertical,
  Percent,
  Plus,
  Sprout,
  TriangleAlert,
  Trash2,
  ChefHat,
  Upload,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { TableSkeleton } from "@/components/TableSkeleton";
import { Pagination } from "@/components/Pagination";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cn, formatINR, formatDate } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { can } from "@/lib/auth/permissions";
import type { IngredientYield, RawMaterial } from "@/lib/data/types";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useRecipes } from "@/features/recipes/hooks";
import { useAllRecipeIngredients } from "@/features/reports/hooks";
import { useYields, useDeleteYield } from "./hooks";
import { YieldForm } from "./YieldForm";
import { YieldBreakdownDialog } from "./YieldBreakdownDialog";
import { toast } from "@/components/ui/use-toast";
import { useQueryClient } from "@tanstack/react-query";
import { ImportDialog } from "@/components/ImportDialog";
import { yieldsRepo, type ImportYieldRow } from "@/lib/data";
import { pick, toNum, toText, type ImportConfig } from "@/lib/import/importTypes";
import { PURCHASE_UNITS } from "@/lib/units";

const PAGE_SIZE = 10;
type SortKey = "name" | "wastage" | "yield" | "cost";

export function YieldPage() {
  const user = useSession((s) => s.user)!;
  const navigate = useNavigate();
  const canEdit = can(user.role, "yield.manage");
  const { data: yields = [], isLoading } = useYields();
  const { data: materials = [] } = useMaterials();
  const { data: recipes = [] } = useRecipes();
  const { data: recipeIngredients = [] } = useAllRecipeIngredients();
  const queryClient = useQueryClient();
  const [importOpen, setImportOpen] = useState(false);

  const importConfig = useMemo<ImportConfig<ImportYieldRow>>(() => ({
    title: "Import Yields",
    columns: [
      { label: "Ingredient", required: true },
      { label: "Purchase Cost", required: true },
      { label: "Purchase Quantity", required: true },
      { label: "Purchase Unit", required: true },
      { label: "Wastage Quantity", required: true },
      { label: "Effective From" },
      { label: "Notes" },
    ],
    sample: {
      Ingredient: "Onion",
      "Purchase Cost": 125,
      "Purchase Quantity": 1,
      "Purchase Unit": "KG",
      "Wastage Quantity": 200,
      "Effective From": "2026-06-01",
      Notes: "Peeling + trimming loss",
    },
    parseRow: (row, n) => {
      const ingredient_name = toText(pick(row, ["Ingredient", "Ingredient Name"]));
      if (!ingredient_name) return { error: `Row ${n}: ingredient is required` };
      const purchase_cost = toNum(pick(row, ["Purchase Cost", "Cost"]));
      if (purchase_cost == null || Number.isNaN(purchase_cost) || purchase_cost <= 0)
        return { error: `Row ${n}: purchase cost must be greater than 0` };
      const purchase_quantity = toNum(pick(row, ["Purchase Quantity", "Quantity", "Qty"]));
      if (purchase_quantity == null || Number.isNaN(purchase_quantity) || purchase_quantity <= 0)
        return { error: `Row ${n}: purchase quantity must be greater than 0` };
      const purchase_unit = toText(pick(row, ["Purchase Unit", "Unit"]));
      if (!PURCHASE_UNITS.includes(purchase_unit as (typeof PURCHASE_UNITS)[number]))
        return { error: `Row ${n}: invalid purchase unit "${purchase_unit}"` };
      const wastage_quantity = toNum(pick(row, ["Wastage Quantity", "Wastage"]));
      if (wastage_quantity == null || Number.isNaN(wastage_quantity) || wastage_quantity < 0)
        return { error: `Row ${n}: wastage quantity cannot be negative` };
      return {
        value: {
          ingredient_name,
          purchase_cost,
          purchase_quantity,
          purchase_unit,
          wastage_quantity,
          effective_from: toText(pick(row, ["Effective From", "Date"])) || null,
          notes: toText(pick(row, ["Notes"])) || null,
        },
      };
    },
    run: async (mode, rows) => {
      const summary = await yieldsRepo.importYields(mode, rows, user.id);
      await queryClient.invalidateQueries({ queryKey: ["yields"] });
      await queryClient.invalidateQueries({ queryKey: ["recipes"] });
      return summary;
    },
  }), [queryClient, user.id]);
  const deleteMut = useDeleteYield();

  const matById = useMemo(() => new Map(materials.map((m) => [m.id, m])), [materials]);
  const categories = useMemo(
    () => [...new Set(materials.map((m) => m.category))].sort(),
    [materials],
  );

  // Recipes that use a given ingredient (§6 "View recipes using ingredient").
  const recipesUsing = useMemo(() => {
    const recById = new Map(recipes.map((r) => [r.id, r]));
    const map = new Map<string, { id: string; name: string }[]>();
    for (const ri of recipeIngredients) {
      if (ri.component_type === "recipe") continue;
      const r = recById.get(ri.recipe_id);
      if (!r) continue;
      const list = map.get(ri.ingredient_id) ?? [];
      if (!list.some((x) => x.id === r.id)) list.push({ id: r.id, name: r.recipe_name });
      map.set(ri.ingredient_id, list);
    }
    return map;
  }, [recipeIngredients, recipes]);

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [wastageBand, setWastageBand] = useState("all");
  const [yieldBand, setYieldBand] = useState("all");
  const [sort, setSort] = useState<{ key: SortKey; dir: "asc" | "desc" }>({ key: "name", dir: "asc" });
  const [page, setPage] = useState(1);

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<IngredientYield | null>(null);
  const [showMissing, setShowMissing] = useState(false);
  const [breakdownFor, setBreakdownFor] = useState<IngredientYield | null>(null);
  const [deleting, setDeleting] = useState<IngredientYield | null>(null);
  const [recipesForYield, setRecipesForYield] = useState<(IngredientYield & { material: RawMaterial | null }) | null>(null);

  type Row = IngredientYield & { material: RawMaterial | null };
  const rows = useMemo<Row[]>(
    () => yields.map((y) => ({ ...y, material: matById.get(y.ingredient_id) ?? null })),
    [yields, matById],
  );

  const filtered = useMemo(() => {
    const out = rows.filter((r) => {
      const name = r.material?.ingredient_name ?? "";
      if (search && !name.toLowerCase().includes(search.toLowerCase())) return false;
      if (category !== "all" && r.material?.category !== category) return false;
      if (wastageBand === "low" && r.wastage_percentage >= 10) return false;
      if (wastageBand === "med" && (r.wastage_percentage < 10 || r.wastage_percentage > 25)) return false;
      if (wastageBand === "high" && r.wastage_percentage <= 25) return false;
      if (yieldBand === "high" && r.yield_percentage < 90) return false;
      if (yieldBand === "med" && (r.yield_percentage < 75 || r.yield_percentage >= 90)) return false;
      if (yieldBand === "low" && r.yield_percentage >= 75) return false;
      return true;
    });
    out.sort((a, b) => {
      let cmp = 0;
      if (sort.key === "name")
        cmp = (a.material?.ingredient_name ?? "").localeCompare(b.material?.ingredient_name ?? "");
      else if (sort.key === "wastage") cmp = a.wastage_percentage - b.wastage_percentage;
      else if (sort.key === "yield") cmp = a.yield_percentage - b.yield_percentage;
      else if (sort.key === "cost") cmp = a.yield_adjusted_unit_cost - b.yield_adjusted_unit_cost;
      return sort.dir === "asc" ? cmp : -cmp;
    });
    return out;
  }, [rows, search, category, wastageBand, yieldBand, sort]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const current = Math.min(page, pageCount);
  const pageItems = filtered.slice((current - 1) * PAGE_SIZE, current * PAGE_SIZE);

  // Summary stats
  const stats = useMemo(() => {
    const n = yields.length;
    const avgYield = n ? yields.reduce((s, y) => s + y.yield_percentage, 0) / n : 0;
    const avgWastage = n ? yields.reduce((s, y) => s + y.wastage_percentage, 0) / n : 0;
    // Estimated wastage cost = wastage_quantity × original cost per base unit, summed.
    const wastageCost = yields.reduce((s, y) => s + y.wastage_quantity * y.original_unit_cost, 0);
    // A yield can be created before its purchase price is known. Flag only those
    // (NOT every raw material that lacks a yield — that was ~795 rows of noise).
    const missingItems = yields.filter((y) => {
      const m = matById.get(y.ingredient_id);
      return (y.purchase_cost ?? 0) <= 0 || m == null || m.cost_per_base_unit == null;
    });
    return { n, avgYield, avgWastage, wastageCost, missing: missingItems.length, missingItems };
  }, [yields, matById]);

  const toggleSort = (key: SortKey) =>
    setSort((s) => (s.key === key ? { key, dir: s.dir === "asc" ? "desc" : "asc" } : { key, dir: "desc" }));

  const SortHead = ({ label, k, className }: { label: string; k: SortKey; className?: string }) => {
    const active = sort.key === k;
    return (
      <TableHead className={className} aria-sort={active ? (sort.dir === "asc" ? "ascending" : "descending") : "none"}>
        <button
          className="inline-flex items-center gap-1 rounded hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          onClick={() => toggleSort(k)}
          aria-label={`Sort by ${label}`}
        >
          {label}
          {active ? (
            sort.dir === "asc" ? <ArrowUp className="h-3.5 w-3.5" /> : <ArrowDown className="h-3.5 w-3.5" />
          ) : (
            <ArrowUpDown className="h-3.5 w-3.5 opacity-40" />
          )}
        </button>
      </TableHead>
    );
  };

  const openAdd = () => {
    setEditing(null);
    setFormOpen(true);
  };

  return (
    <>
      <PageHeader
        title="Yield Management"
        description="Effective ingredient cost after cleaning, peeling, trimming and processing loss."
        actions={
          canEdit && (
            <div className="flex items-center gap-2">
              <Button variant="outline" onClick={() => setImportOpen(true)}>
                <Upload className="h-4 w-4" /> Import
              </Button>
              <Button variant="accent" onClick={openAdd}>
                <Plus className="h-4 w-4" /> Add Yield
              </Button>
            </div>
          )
        }
      />

      {/* Summary cards */}
      <div className="mb-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <Stat icon={<Sprout className="h-4 w-4" />} label="Ingredients w/ Yield" value={String(stats.n)} />
        <Stat icon={<Percent className="h-4 w-4" />} label="Avg Yield" value={`${stats.avgYield.toFixed(1)}%`} />
        <Stat icon={<Percent className="h-4 w-4" />} label="Avg Wastage" value={`${stats.avgWastage.toFixed(1)}%`} />
        <Stat icon={<Calculator className="h-4 w-4" />} label="Est. Wastage Cost" value={formatINR(stats.wastageCost)} />
        <Stat
          icon={<TriangleAlert className="h-4 w-4 text-amber-500" />}
          label="Yields Missing Price"
          value={String(stats.missing)}
          onClick={stats.missing > 0 ? () => setShowMissing(true) : undefined}
        />
      </div>

      {/* Filters */}
      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <Input placeholder="Search ingredients…" value={search} onChange={(e) => { setSearch(e.target.value); setPage(1); }} />
          <Select value={category} onValueChange={(v) => { setCategory(v); setPage(1); }}>
            <SelectTrigger><SelectValue placeholder="Category" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Categories</SelectItem>
              {categories.map((c) => <SelectItem key={c} value={c}>{c}</SelectItem>)}
            </SelectContent>
          </Select>
          <Select value={wastageBand} onValueChange={(v) => { setWastageBand(v); setPage(1); }}>
            <SelectTrigger><SelectValue placeholder="Wastage" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Any Wastage</SelectItem>
              <SelectItem value="low">Low (&lt; 10%)</SelectItem>
              <SelectItem value="med">Medium (10–25%)</SelectItem>
              <SelectItem value="high">High (&gt; 25%)</SelectItem>
            </SelectContent>
          </Select>
          <Select value={yieldBand} onValueChange={(v) => { setYieldBand(v); setPage(1); }}>
            <SelectTrigger><SelectValue placeholder="Yield" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Any Yield</SelectItem>
              <SelectItem value="high">High (≥ 90%)</SelectItem>
              <SelectItem value="med">Medium (75–90%)</SelectItem>
              <SelectItem value="low">Low (&lt; 75%)</SelectItem>
            </SelectContent>
          </Select>
          <Select
            value={`${sort.key}:${sort.dir}`}
            onValueChange={(v) => {
              const [key, dir] = v.split(":") as [SortKey, "asc" | "desc"];
              setSort({ key, dir });
              setPage(1);
            }}
          >
            <SelectTrigger><SelectValue placeholder="Sort" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="name:asc">Name (A–Z)</SelectItem>
              <SelectItem value="wastage:desc">Highest wastage</SelectItem>
              <SelectItem value="yield:asc">Lowest yield</SelectItem>
              <SelectItem value="cost:desc">Highest effective cost</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </Card>

      <Card>
        {isLoading ? (
          <TableSkeleton rows={6} cols={6} />
        ) : filtered.length === 0 ? (
          <EmptyState
            icon={<Sprout className="h-7 w-7" />}
            title="No yield data has been added yet"
            description="Add yield information to calculate the effective usable ingredient cost."
            action={canEdit && <Button variant="accent" onClick={openAdd}><Plus className="h-4 w-4" /> Add Yield</Button>}
          />
        ) : (
          <>
            <div className="hidden md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <SortHead label="Ingredient" k="name" />
                    <TableHead>Category</TableHead>
                    <SortHead label="Wastage %" k="wastage" className="text-right" />
                    <SortHead label="Yield %" k="yield" className="text-right" />
                    <TableHead className="text-right">Original Cost</TableHead>
                    <SortHead label="Yield-Adjusted" k="cost" className="text-right" />
                    <TableHead>Updated</TableHead>
                    <TableHead className="w-10" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pageItems.map((r) => (
                    <TableRow key={r.id} className="cursor-pointer" onClick={() => setBreakdownFor(r)}>
                      <TableCell className="font-medium">{r.material?.ingredient_name ?? "—"}</TableCell>
                      <TableCell className="text-muted-foreground">{r.material?.category ?? "—"}</TableCell>
                      <TableCell className="text-right font-mono">{r.wastage_percentage}%</TableCell>
                      <TableCell className="text-right font-mono">{r.yield_percentage}%</TableCell>
                      <TableCell className="text-right font-mono text-muted-foreground">{formatINR(r.original_unit_cost * 1000)}/kg</TableCell>
                      <TableCell className="text-right font-mono font-semibold">{formatINR(r.yield_adjusted_unit_cost * 1000)}/kg</TableCell>
                      <TableCell className="text-xs text-muted-foreground">{formatDate(r.updated_at)}</TableCell>
                      <TableCell onClick={(e) => e.stopPropagation()}>
                        <RowActions
                          y={r}
                          canEdit={canEdit}
                          onEdit={() => { setEditing(r); setFormOpen(true); }}
                          onBreakdown={() => setBreakdownFor(r)}
                          onRecipes={() => setRecipesForYield(r)}
                          onDelete={() => setDeleting(r)}
                        />
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            {/* Mobile cards */}
            <ul className="divide-y md:hidden">
              {pageItems.map((r) => (
                <li key={r.id} className="flex items-start gap-3 p-4">
                  <button className="min-w-0 flex-1 text-left" onClick={() => setBreakdownFor(r)}>
                    <p className="truncate font-medium">{r.material?.ingredient_name ?? "—"}</p>
                    <p className="text-xs text-muted-foreground">{r.material?.category}</p>
                    <p className="mt-1 text-sm">
                      Yield <span className="font-semibold">{r.yield_percentage}%</span> · {formatINR(r.yield_adjusted_unit_cost * 1000)}/kg
                    </p>
                  </button>
                  <RowActions
                    y={r}
                    canEdit={canEdit}
                    onEdit={() => { setEditing(r); setFormOpen(true); }}
                    onBreakdown={() => setBreakdownFor(r)}
                    onRecipes={() => setRecipesForYield(r)}
                    onDelete={() => setDeleting(r)}
                  />
                </li>
              ))}
            </ul>

            <Pagination page={current} pageSize={PAGE_SIZE} total={filtered.length} onPageChange={setPage} label="ingredients" />
          </>
        )}
      </Card>

      <ImportDialog open={importOpen} onOpenChange={setImportOpen} config={importConfig} />
      <YieldForm open={formOpen} onOpenChange={setFormOpen} record={editing} />

      {/* Drill-in: the yields counted as "Missing Price" */}
      <Dialog open={showMissing} onOpenChange={setShowMissing}>
        <DialogContent className="max-h-[80vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Yields missing a price — {stats.missing}</DialogTitle>
            <DialogDescription>
              A yield exists but its ingredient has no purchase price. Tap one to add the price.
            </DialogDescription>
          </DialogHeader>
          <ul className="divide-y">
            {stats.missingItems.map((y) => (
              <li key={y.id}>
                <button
                  type="button"
                  onClick={() => { setShowMissing(false); setEditing(y); setFormOpen(true); }}
                  className="flex w-full items-center justify-between gap-3 py-2 text-left text-sm hover:text-emerald-700"
                >
                  <span className="font-medium">{matById.get(y.ingredient_id)?.ingredient_name ?? "—"}</span>
                  <span className="shrink-0 text-xs text-muted-foreground">yield {y.yield_percentage}%</span>
                </button>
              </li>
            ))}
          </ul>
        </DialogContent>
      </Dialog>
      <YieldBreakdownDialog
        record={breakdownFor}
        material={breakdownFor ? matById.get(breakdownFor.ingredient_id) ?? null : null}
        open={!!breakdownFor}
        onOpenChange={(o) => !o && setBreakdownFor(null)}
      />
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => !o && setDeleting(null)}
        title="Delete yield record?"
        description={`Yield data for "${(deleting && matById.get(deleting.ingredient_id)?.ingredient_name) ?? "this ingredient"}" will be removed. Recipes will fall back to the standard purchase cost.`}
        confirmLabel="Delete"
        destructive
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await deleteMut.mutateAsync(deleting.id);
            toast.success("Yield record deleted");
          } catch (e) {
            toast.error(e instanceof Error ? e.message : "Delete failed");
          }
        }}
      />

      <Dialog open={!!recipesForYield} onOpenChange={(o) => !o && setRecipesForYield(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Recipes using {recipesForYield?.material?.ingredient_name ?? "this ingredient"}</DialogTitle>
            <DialogDescription>
              These recipes apply this ingredient's yield-adjusted cost. Editing the yield re-costs them all.
            </DialogDescription>
          </DialogHeader>
          {(() => {
            const list = recipesForYield ? recipesUsing.get(recipesForYield.ingredient_id) ?? [] : [];
            if (list.length === 0) {
              return <p className="py-4 text-sm text-muted-foreground">No recipes currently use this ingredient.</p>;
            }
            return (
              <ul className="max-h-80 divide-y overflow-y-auto">
                {list.map((r) => (
                  <li key={r.id}>
                    <button
                      onClick={() => { navigate(`/recipes/${r.id}`); setRecipesForYield(null); }}
                      className="flex w-full items-center gap-2 py-2.5 text-left text-sm hover:underline"
                    >
                      <ChefHat className="h-4 w-4 shrink-0 text-muted-foreground" />
                      <span className="truncate">{r.name}</span>
                    </button>
                  </li>
                ))}
              </ul>
            );
          })()}
        </DialogContent>
      </Dialog>
    </>
  );
}

function Stat({ icon, label, value, onClick }: { icon: React.ReactNode; label: string; value: string; onClick?: () => void }) {
  return (
    <Card
      className={cn("p-4", onClick && "cursor-pointer transition-colors hover:bg-muted/50")}
      onClick={onClick}
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onClick(); } } : undefined}
    >
      <div className="mb-1 flex items-center gap-2 text-sm text-muted-foreground">{icon}{label}{onClick && <span className="text-muted-foreground/70">›</span>}</div>
      <div className="text-2xl font-bold">{value}</div>
    </Card>
  );
}

function RowActions({
  y,
  canEdit,
  onEdit,
  onBreakdown,
  onRecipes,
  onDelete,
}: {
  y: IngredientYield & { material: RawMaterial | null };
  canEdit: boolean;
  onEdit: () => void;
  onBreakdown: () => void;
  onRecipes: () => void;
  onDelete: () => void;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label={`Actions for ${y.material?.ingredient_name ?? "yield"}`}>
          <MoreVertical className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem onClick={onBreakdown}>View Calculation Breakdown</DropdownMenuItem>
        <DropdownMenuItem onClick={onRecipes}>
          <ChefHat className="h-4 w-4" /> Recipes Using This
        </DropdownMenuItem>
        {canEdit && <DropdownMenuItem onClick={onEdit}>Edit Yield</DropdownMenuItem>}
        {canEdit && (
          <DropdownMenuItem onClick={onDelete} className="text-destructive">
            <Trash2 className="h-4 w-4" /> Delete Yield
          </DropdownMenuItem>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
