import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import {
  ChevronDown,
  Copy,
  FileDown,
  MoreVertical,
  Pencil,
  Plus,
  AlertTriangle,
  TrendingDown,
  Boxes,
  ClipboardCheck,
  Percent,
} from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { cn, formatDateTime, formatINR } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { can, canEditRecipe, viewerBrands, viewerShowCost } from "@/lib/auth/permissions";
import { calculateIngredientCost } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import type { Recipe } from "@/lib/data/types";
import { toast } from "@/components/ui/use-toast";
import { useRecipeCategories, useFoodCostPct, useAllSettings } from "@/features/settings/hooks";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useUsersMap } from "@/features/users/hooks";
import { useDashboardBrand } from "@/features/dashboard/brandTheme";
import { useDuplicateRecipe, useRecipe, useRecipes } from "./hooks";
import {
  FC_TONE_STYLES,
  fcTone,
  foodCostPctOf,
  menuPriceOf,
  profitMarginOf,
  skuOf,
} from "./recipeMetrics";

const PAGE_SIZE = 6;

const CATEGORY_EMOJI: Record<string, string> = {
  Pasta: "🍝",
  Rice: "🍚",
  Dessert: "🍰",
  Beverage: "🍵",
  Protein: "🍗",
};
const emojiFor = (category: string) => CATEGORY_EMOJI[category] ?? "🍽️";

export function RecipesPage({ prepMode = false }: { prepMode?: boolean } = {}) {
  const user = useSession((s) => s.user)!;
  const navigate = useNavigate();
  const { data: allRecipes = [], isLoading } = useRecipes();
  const globalBrand = useDashboardBrand((s) => s.brand);
  const canSeeCost = user.role !== "viewer" || viewerShowCost(user);
  const recipes = useMemo(() => {
    const base = allRecipes.filter((r) => (prepMode ? r.is_prep : !r.is_prep));
    if (user.role === "viewer") {
      const brands = viewerBrands(user);
      return base.filter((r) => r.status === "approved" && brands.includes(r.brand));
    }
    return globalBrand === "all" ? base : base.filter((r) => r.brand === globalBrand);
  }, [allRecipes, prepMode, user, globalBrand]);
  const { data: categories = [] } = useRecipeCategories();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { data: settings = [] } = useAllSettings();
  const { data: materials = [] } = useMaterials();
  const { map: usersMap } = useUsersMap();
  const dupMut = useDuplicateRecipe();

  // "Updated by" attribution is for staff roles, not external viewers.
  const showUpdatedBy = user.role !== "viewer";

  const criticalPct = Number(
    settings.find((s) => s.key === "margin_alert_pct")?.value ?? 35,
  );

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [status, setStatus] = useState("all");
  const [fcRange, setFcRange] = useState("all");
  const [page, setPage] = useState(1);
  const [expanded, setExpanded] = useState<string | null>(null);

  const canCreate = can(user.role, "recipe.create");

  const filtered = useMemo(() => {
    return recipes.filter((r) => {
      if (search && !r.recipe_name.toLowerCase().includes(search.toLowerCase())) return false;
      if (category !== "all" && r.category !== category) return false;
      if (status !== "all" && r.status !== status) return false;
      if (fcRange !== "all") {
        const fc = foodCostPctOf(r, foodCostPct);
        if (fcRange === "low" && !(fc < 25)) return false;
        if (fcRange === "mid" && !(fc >= 25 && fc <= 35)) return false;
        if (fcRange === "high" && !(fc > 35)) return false;
      }
      return true;
    });
  }, [recipes, search, category, status, fcRange, foodCostPct]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pageItems = filtered.slice((currentPage - 1) * PAGE_SIZE, currentPage * PAGE_SIZE);

  const kpis = useMemo(() => {
    const withFc = recipes.map((r) => foodCostPctOf(r, foodCostPct));
    const avgFc = withFc.length ? withFc.reduce((a, b) => a + b, 0) / withFc.length : 0;
    const critical = recipes.filter((r) => foodCostPctOf(r, foodCostPct) >= criticalPct).length;
    const activeMaterials = materials.filter((m) => m.status === "active");
    const pendingPrices = materials.filter((m) => m.purchase_price === null).length;
    const inventoryValue = activeMaterials.reduce((sum, m) => sum + (m.purchase_price ?? 0), 0);
    return {
      avgFc: avgFc.toFixed(1),
      critical,
      pendingPrices,
      inventoryValue,
      activeCount: activeMaterials.length,
    };
  }, [recipes, materials, foodCostPct, criticalPct]);

  const clearFilters = () => {
    setSearch("");
    setCategory("all");
    setStatus("all");
    setFcRange("all");
    setPage(1);
  };

  const duplicate = async (id: string) => {
    try {
      const copy = await dupMut.mutateAsync(id);
      toast.success("Recipe duplicated");
      navigate(`/recipes/${copy.id}/edit`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Duplicate failed");
    }
  };

  return (
    <>
      <PageHeader
        title={prepMode ? "In-House Prep" : "Recipe Inventory"}
        description={
          prepMode
            ? "Sauces, doughs, pastes and bases made in-house and used across recipes."
            : "Manage costing and margins across your kitchen catalog."
        }
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={() => navigate("/reports")}>
              <FileDown className="h-4 w-4" /> Export
            </Button>
            {canCreate && (
              <Button
                className="bg-emerald-800 text-white hover:bg-emerald-900"
                onClick={() => navigate("/recipes/new", { state: prepMode ? { isPrep: true } : undefined })}
              >
                <Plus className="h-4 w-4" /> {prepMode ? "New Prep" : "New Recipe"}
              </Button>
            )}
          </div>
        }
      />

      {/* Filters */}
      <Card className="mb-4 p-4">
        <div className="grid items-end gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Filter label="Category">
            <Select value={category} onValueChange={(v) => { setCategory(v); setPage(1); }}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All Categories</SelectItem>
                {categories.map((c) => (
                  <SelectItem key={c} value={c}>{c}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Filter>
          <Filter label="Status">
            <Select value={status} onValueChange={(v) => { setStatus(v); setPage(1); }}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All Statuses</SelectItem>
                <SelectItem value="draft">Draft</SelectItem>
                <SelectItem value="testing">Testing</SelectItem>
                <SelectItem value="approved">Approved</SelectItem>
                <SelectItem value="rejected">Rejected</SelectItem>
              </SelectContent>
            </Select>
          </Filter>
          <Filter label="Food Cost Range">
            <Select value={fcRange} onValueChange={(v) => { setFcRange(v); setPage(1); }}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Any Cost %</SelectItem>
                <SelectItem value="low">Under 25%</SelectItem>
                <SelectItem value="mid">25% – 35%</SelectItem>
                <SelectItem value="high">Over 35%</SelectItem>
              </SelectContent>
            </Select>
          </Filter>
          <div className="flex items-center gap-3">
            <Input
              placeholder="Search recipes…"
              value={search}
              onChange={(e) => { setSearch(e.target.value); setPage(1); }}
            />
            <button onClick={clearFilters} className="whitespace-nowrap text-sm font-semibold text-emerald-800 hover:underline">
              Clear Filters
            </button>
          </div>
        </div>
      </Card>

      {/* Table */}
      <Card className="mb-6 overflow-hidden">
        {isLoading ? (
          <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>
        ) : filtered.length === 0 ? (
          <EmptyState
            title="No recipes found"
            description="Adjust your filters or create a new recipe."
            action={canCreate && (
              <Button className="bg-emerald-800 text-white hover:bg-emerald-900" onClick={() => navigate("/recipes/new")}>
                <Plus className="h-4 w-4" /> New Recipe
              </Button>
            )}
          />
        ) : (
          <>
            {/* Header */}
            <div className="hidden grid-cols-12 gap-2 border-b bg-muted/40 px-4 py-3 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground lg:grid">
              <div className="col-span-3">Recipe Name</div>
              <div className="col-span-2">Category</div>
              <div className="col-span-1">Yield</div>
              <div className="col-span-1 text-right">Unit Cost</div>
              <div className="col-span-1 text-right">Menu Price</div>
              <div className="col-span-2">Food Cost %</div>
              <div className="col-span-1">Last Updated</div>
              <div className="col-span-1" />
            </div>

            <div className="divide-y">
              {pageItems.map((r) => (
                <RecipeRow
                  key={r.id}
                  recipe={r}
                  foodCostPct={foodCostPct}
                  criticalPct={criticalPct}
                  expanded={expanded === r.id}
                  onToggle={() => setExpanded(expanded === r.id ? null : r.id)}
                  onView={() => navigate(`/recipes/${r.id}`)}
                  canEdit={canEditRecipe(user, r)}
                  canDuplicate={can(user.role, "recipe.duplicate")}
                  onEdit={() => navigate(`/recipes/${r.id}/edit`)}
                  onDuplicate={() => duplicate(r.id)}
                  updatedBy={showUpdatedBy ? usersMap.get(r.updated_by ?? "")?.name ?? null : null}
                  canSeeCost={canSeeCost}
                />
              ))}
            </div>

            {/* Pagination */}
            <div className="flex flex-col items-center justify-between gap-3 bg-muted/30 px-4 py-3 text-sm sm:flex-row">
              <span className="text-muted-foreground">
                Showing <strong>{(currentPage - 1) * PAGE_SIZE + 1}-
                {Math.min(currentPage * PAGE_SIZE, filtered.length)}</strong> of{" "}
                <strong>{filtered.length}</strong> recipes
              </span>
              <div className="flex items-center gap-1">
                <Button variant="outline" size="sm" disabled={currentPage <= 1} onClick={() => setPage(currentPage - 1)}>
                  ‹
                </Button>
                {Array.from({ length: pageCount }, (_, i) => i + 1).map((p) => (
                  <Button
                    key={p}
                    size="sm"
                    variant={p === currentPage ? "default" : "outline"}
                    className={p === currentPage ? "bg-emerald-800 text-white hover:bg-emerald-900" : ""}
                    onClick={() => setPage(p)}
                  >
                    {p}
                  </Button>
                ))}
                <Button variant="outline" size="sm" disabled={currentPage >= pageCount} onClick={() => setPage(currentPage + 1)}>
                  ›
                </Button>
              </div>
            </div>
          </>
        )}
      </Card>

      {/* Bottom KPI strip (cost — hidden for viewers without cost access) */}
      {canSeeCost && (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          icon={<Percent className="h-4 w-4" />}
          label="Average Food Cost"
          value={`${kpis.avgFc}%`}
          sub={<span className="inline-flex items-center gap-1 text-emerald-600"><TrendingDown className="h-3 w-3" /> 1.2% from last month</span>}
        />
        <StatCard
          icon={<AlertTriangle className="h-4 w-4" />}
          label="Critical Recipes"
          value={<span className="text-red-600">{kpis.critical}</span>}
          sub={`Cost exceeding ${criticalPct}% target`}
        />
        <StatCard
          icon={<ClipboardCheck className="h-4 w-4" />}
          label="Pending Ingredient Updates"
          value={<span className="text-amber-600">{kpis.pendingPrices}</span>}
          sub="Awaiting price confirmation"
        />
        <StatCard
          icon={<Boxes className="h-4 w-4" />}
          label="Inventory Value"
          value={formatINR(kpis.inventoryValue)}
          sub={`Across ${kpis.activeCount} active items`}
        />
      </div>
      )}
    </>
  );
}

function Filter({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label className="text-xs font-medium text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}

function StatCard({
  icon,
  label,
  value,
  sub,
}: {
  icon: React.ReactNode;
  label: string;
  value: React.ReactNode;
  sub: React.ReactNode;
}) {
  return (
    <Card className="p-4">
      <div className="mb-1 flex items-center gap-2 text-sm text-muted-foreground">
        {icon}
        {label}
      </div>
      <div className="text-2xl font-bold">{value}</div>
      <div className="mt-1 text-xs text-muted-foreground">{sub}</div>
    </Card>
  );
}

function RecipeRow({
  recipe,
  foodCostPct,
  criticalPct,
  expanded,
  onToggle,
  onView,
  canEdit,
  canDuplicate,
  onEdit,
  onDuplicate,
  updatedBy,
  canSeeCost,
}: {
  recipe: Recipe;
  foodCostPct: number;
  criticalPct: number;
  expanded: boolean;
  onToggle: () => void;
  onView: () => void;
  canEdit: boolean;
  canDuplicate: boolean;
  onEdit: () => void;
  onDuplicate: () => void;
  updatedBy: string | null;
  canSeeCost: boolean;
}) {
  const unitCost = recipe.cost_per_portion ?? 0;
  const menuPrice = menuPriceOf(recipe, foodCostPct);
  const fc = foodCostPctOf(recipe, foodCostPct);
  const tone = fcTone(fc, criticalPct);
  const toneStyle = FC_TONE_STYLES[tone];

  return (
    <div className={cn(expanded && "bg-emerald-50/50")}>
      <button
        onClick={onToggle}
        className={cn(
          "grid w-full grid-cols-2 items-center gap-2 px-4 py-3 text-left lg:grid-cols-12",
          expanded && "border-l-4 border-emerald-700",
        )}
      >
        <div className="col-span-2 flex items-center gap-3 lg:col-span-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center overflow-hidden rounded-md bg-muted text-lg">
            {recipe.image_url ? (
              <img src={recipe.image_url} alt="" className="h-full w-full object-cover" />
            ) : (
              emojiFor(recipe.category)
            )}
          </div>
          <div className="min-w-0">
            <p className="truncate font-semibold">{recipe.recipe_name}</p>
            <p className="text-xs text-muted-foreground">SKU: {skuOf(recipe.id)}</p>
          </div>
        </div>
        <div className="col-span-1 hidden text-xs font-medium uppercase text-muted-foreground lg:block lg:col-span-2">
          {recipe.category}
        </div>
        <div className="hidden lg:block lg:col-span-1">
          <span className="font-mono">{recipe.serving_size} Port.</span>
        </div>
        <div className="hidden text-right font-mono lg:block lg:col-span-1">{canSeeCost ? formatINR(unitCost) : "—"}</div>
        <div className="hidden text-right font-mono font-semibold lg:block lg:col-span-1">{canSeeCost ? formatINR(menuPrice) : "—"}</div>
        <div className="col-span-2 lg:col-span-2">
          {canSeeCost ? (
          <div className="flex items-center gap-2">
            <span className={cn("rounded px-1.5 py-0.5 text-xs font-semibold", toneStyle.badge)}>
              {fc}%
            </span>
            <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
              <div
                className={cn("h-full rounded-full", toneStyle.bar)}
                style={{ width: `${Math.min(100, (fc / Math.max(criticalPct + 15, 1)) * 100)}%` }}
              />
            </div>
          </div>
          ) : (
            <span className="text-muted-foreground">—</span>
          )}
        </div>
        <div className="hidden text-xs text-muted-foreground lg:block lg:col-span-1">
          <div>{formatDateTime(recipe.updated_at)}</div>
          {updatedBy && <div className="text-[11px]">by {updatedBy}</div>}
        </div>
        <div className="hidden items-center justify-end lg:flex lg:col-span-1">
          <ChevronDown className={cn("h-4 w-4 transition-transform", expanded && "rotate-180")} />
        </div>
      </button>

      {expanded && canSeeCost && (
        <ExpandedBreakdown
          recipe={recipe}
          foodCostPct={foodCostPct}
          onView={onView}
          canEdit={canEdit}
          canDuplicate={canDuplicate}
          onEdit={onEdit}
          onDuplicate={onDuplicate}
        />
      )}
    </div>
  );
}

function ExpandedBreakdown({
  recipe,
  foodCostPct,
  onView,
  canEdit,
  canDuplicate,
  onEdit,
  onDuplicate,
}: {
  recipe: Recipe;
  foodCostPct: number;
  onView: () => void;
  canEdit: boolean;
  canDuplicate: boolean;
  onEdit: () => void;
  onDuplicate: () => void;
}) {
  const { data, isLoading } = useRecipe(recipe.id);
  const margin = profitMarginOf(recipe, foodCostPct);
  const actualFc = foodCostPctOf(recipe, foodCostPct);
  const variance = Number((actualFc - foodCostPct).toFixed(1));

  const lines = (data?.ingredients ?? []).map((ing) => {
    const m = ing.material;
    const cost =
      m && m.cost_per_base_unit !== null && canConvert(ing.unit_used, m.base_unit)
        ? calculateIngredientCost(m.cost_per_base_unit, ing.quantity_used, ing.unit_used, m.base_unit)
        : null;
    return {
      name: `${m?.ingredient_name ?? "—"} (${ing.quantity_used}${ing.unit_used})`,
      cost,
    };
  });
  const mid = Math.ceil(lines.length / 2);

  return (
    <div className="grid gap-4 border-t bg-background/60 p-4 lg:grid-cols-3">
      <div className="lg:col-span-2">
        <div className="mb-3 flex items-center justify-between">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Cost Component Breakdown
          </p>
          <div className="flex items-center gap-2">
            <StatusBadge status={recipe.status} />
            <Button variant="ghost" size="sm" onClick={onView}>View</Button>
            {canEdit && (
              <Button variant="ghost" size="sm" onClick={onEdit}>
                <Pencil className="h-3.5 w-3.5" /> Edit
              </Button>
            )}
            {canDuplicate && (
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon"><MoreVertical className="h-4 w-4" /></Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem onClick={onDuplicate}>
                    <Copy className="h-4 w-4" /> Duplicate
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            )}
          </div>
        </div>
        {isLoading ? (
          <p className="py-4 text-sm text-muted-foreground">Loading breakdown…</p>
        ) : (
          <div className="grid gap-x-8 gap-y-2 sm:grid-cols-2">
            {[lines.slice(0, mid), lines.slice(mid)].map((col, ci) => (
              <div key={ci} className="space-y-2">
                {col.map((l, i) => (
                  <div key={i} className="flex items-baseline justify-between gap-2 border-b border-dashed pb-1 text-sm">
                    <span className="text-muted-foreground">{l.name}</span>
                    <span className="font-mono">{formatINR(l.cost)}</span>
                  </div>
                ))}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Profit margin card */}
      <div className="rounded-lg border bg-muted/40 p-4 text-center">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Profit Margin</p>
        <p className="my-1 text-3xl font-bold text-emerald-700">{formatINR(margin)}</p>
        <div className="mt-3 grid grid-cols-2 gap-2 border-t pt-3 text-left">
          <div>
            <p className="text-[11px] uppercase text-muted-foreground">Target FC %</p>
            <p className="font-mono font-semibold">{foodCostPct.toFixed(1)}%</p>
          </div>
          <div>
            <p className="text-[11px] uppercase text-muted-foreground">Variance</p>
            <p className={cn("font-mono font-semibold", variance <= 0 ? "text-emerald-600" : "text-red-600")}>
              {variance > 0 ? "+" : ""}{variance}%
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
