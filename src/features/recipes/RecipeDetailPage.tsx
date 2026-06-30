import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams, useLocation } from "react-router-dom";
import {
  Copy,
  Pencil,
  Send,
  CheckCircle2,
  XCircle,
  Lock,
  Clock,
  UtensilsCrossed,
  TrendingUp,
  AlertTriangle,
  ImageUp,
  ImageOff,
  ExternalLink,
  ArrowLeft,
} from "lucide-react";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { cn, formatDate, formatINR } from "@/lib/utils";
import { prepUnitCostFrom, round2 } from "@/lib/costing";
import { canConvert, getConversionFactor } from "@/lib/units";

const round3 = (n: number) => Math.round(n * 1000) / 1000;
import { BRANDS } from "@/lib/data/types";
import { useSession } from "@/lib/auth/session";
import { can, canEditRecipe, viewerCanAccess, visibilityForUser } from "@/lib/auth/permissions";
import { toast } from "@/components/ui/use-toast";
import { useUsersMap } from "@/features/users/hooks";
import { useFoodCostPct } from "@/features/settings/hooks";
import { menuPriceOf, fullCostPerPortion, packagingOf } from "./recipeMetrics";
import { RecipePdfButton } from "@/features/reports/RecipePdfButton";
import {
  useApproveRecipe,
  useDuplicateRecipe,
  useRecipe,
  useRecipes,
  useRecipeCostHistory,
  useRecipeVersions,
  useRejectRecipe,
  useSetRecipeImage,
  useSetSellingPrice,
  useSubmitRecipe,
} from "./hooks";

const CATEGORY_EMOJI: Record<string, string> = {
  Pasta: "🍝", Rice: "🍚", Dessert: "🍰", Beverage: "🍵", Protein: "🍗",
};
const emojiFor = (c: string) => CATEGORY_EMOJI[c] ?? "🍽️";

export function RecipeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const backTo = (location.state ?? null) as { fromRecipe?: string; fromName?: string } | null;
  const user = useSession((s) => s.user)!;

  const { data, isLoading } = useRecipe(id);
  const { data: allRecipes = [] } = useRecipes();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { map: usersMap } = useUsersMap();

  // Pizza size family: the master + its size variants, for the size switcher (§16).
  const sizeFamily = useMemo(() => {
    const r = data?.recipe;
    if (!r) return [];
    const masterId = r.parent_recipe_id ?? r.id;
    return allRecipes
      .filter((x) => (x.id === masterId || x.parent_recipe_id === masterId) && x.size_label)
      .sort((a, b) => (a.size_label ?? "").localeCompare(b.size_label ?? ""));
  }, [allRecipes, data]);

  // Name-variant family (e.g. Baby / Mid / Prime Hulk Pizza): masters that share a
  // base name differing only by a size-tier qualifier, surfaced as a variant
  // switcher next to the size switcher. Derived from names — no data migration.
  const variantFamily = useMemo(() => {
    const r = data?.recipe;
    if (!r) return [];
    const QUAL = /\b(Prime|Mid|Baby|Mini|Small|Large|Regular|Classic|Special|Jumbo)\b/i;
    const masters = allRecipes.filter((x) => !x.parent_recipe_id);
    const master = masters.find((x) => x.id === (r.parent_recipe_id ?? r.id)) ?? r;
    const mm = master.recipe_name.match(QUAL);
    if (!mm) return [];
    const baseOf = (name: string) => name.replace(QUAL, "").replace(/\s+/g, " ").trim().toLowerCase();
    const base = baseOf(master.recipe_name);
    const fam = masters
      .map((x) => ({ x, q: x.recipe_name.match(QUAL) }))
      .filter((e) => e.q && e.x.brand === master.brand && baseOf(e.x.recipe_name) === base)
      .map((e) => ({ id: e.x.id, label: e.q![1], activeId: r.id === e.x.id || r.parent_recipe_id === e.x.id }))
      .sort((a, b) => a.label.localeCompare(b.label));
    return fam.length > 1 ? fam : [];
  }, [allRecipes, data]);
  const costHistory = useRecipeCostHistory(id);
  const versions = useRecipeVersions(id);

  const dupMut = useDuplicateRecipe();
  const submitMut = useSubmitRecipe();
  const approveMut = useApproveRecipe();
  const rejectMut = useRejectRecipe();
  const sellingMut = useSetSellingPrice();
  const imageMut = useSetRecipeImage();

  const onImagePick = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 2_000_000) {
      toast.error("Image too large", "Please choose an image under 2 MB.");
      return;
    }
    const reader = new FileReader();
    reader.onload = async () => {
      await imageMut.mutateAsync({ id: recipe.id, imageUrl: String(reader.result) });
      toast.success("Recipe image updated");
    };
    reader.readAsDataURL(file);
  };

  const [removePhotoOpen, setRemovePhotoOpen] = useState(false);
  const [sellingInput, setSellingInput] = useState("");
  const recipeId = data?.recipe?.id;
  const recipeSellingPrice = data?.recipe?.selling_price ?? null;
  useEffect(() => {
    if (recipeId) {
      setSellingInput(recipeSellingPrice != null ? String(recipeSellingPrice) : "");
    }
  }, [recipeId, recipeSellingPrice]);

  const scale = 1;
  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitNote, setSubmitNote] = useState("");
  const [rejectOpen, setRejectOpen] = useState(false);
  const [rejectNote, setRejectNote] = useState("");
  const [approveOpen, setApproveOpen] = useState(false);

  if (isLoading) return <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>;
  if (!data) return <EmptyState title="Recipe not found" />;

  const { recipe, ingredients } = data;

  // When this recipe is one of a name-variant family (Baby/Mid/Prime Hulk), the
  // title shows the FAMILY name (e.g. "Hulk Pizza"); the tier is the variant switcher.
  const displayName =
    variantFamily.length > 1
      ? recipe.recipe_name
          .replace(/\b(Prime|Mid|Baby|Mini|Small|Large|Regular|Classic|Special|Jumbo)\b/i, "")
          .replace(/\s+/g, " ")
          .trim()
      : recipe.recipe_name;

  // Viewer access enforcement — by granted brand (PRD §14).
  if (user.role === "viewer" && !viewerCanAccess(user, recipe)) {
    return (
      <EmptyState
        icon={<Lock className="h-10 w-10" />}
        title="No access"
        description="This recipe's brand hasn't been shared with you."
      />
    );
  }

  const vis = visibilityForUser(user);
  const editable = canEditRecipe(user, recipe);
  const isAdmin = can(user.role, "recipe.approve");
  const showFinancials = vis.totalCost;

  const batchCost = round2((recipe.total_cost ?? 0) * scale);
  // Raw ingredient cost (before wastage) = total ÷ (1 + wastage%).
  const rawIngredientCost = round2(batchCost / (1 + (recipe.wastage_pct ?? 0) / 100));
  const wastageAmount = round2(batchCost - rawIngredientCost);
  const portionCost = recipe.cost_per_portion ?? 0;
  const packaging = packagingOf(recipe);
  const fullCpp = fullCostPerPortion(recipe); // food cost + packaging
  const menuPrice = menuPriceOf(recipe, foodCostPct);
  const marginPct = menuPrice > 0 ? round2(((menuPrice - fullCpp) / menuPrice) * 100) : 0;
  const brandLabel = BRANDS.find((b) => b.value === recipe.brand)?.label ?? recipe.brand;

  const actualFc = menuPrice > 0 ? round2((fullCpp / menuPrice) * 100) : foodCostPct;
  const efficiency = Math.max(0, Math.min(100, Math.round((foodCostPct / Math.max(actualFc, 1)) * 100)));

  return (
    <>
      {/* Back: to the parent recipe when opened from a sub-recipe link, else to the list. */}
      {backTo?.fromRecipe ? (
        <button
          onClick={() => navigate(`/recipes/${backTo.fromRecipe}`)}
          className="mb-2 inline-flex items-center gap-1.5 text-sm font-medium text-emerald-700 hover:underline"
        >
          <ArrowLeft className="h-4 w-4" /> Back to {backTo.fromName ?? "recipe"}
        </button>
      ) : (
        <button
          onClick={() => navigate(recipe.is_prep ? "/prep" : "/recipes")}
          className="mb-2 inline-flex items-center gap-1.5 text-sm font-medium text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" /> Back to {recipe.is_prep ? "In-House Prep" : "Recipes"}
        </button>
      )}

      {/* Breadcrumb */}
      <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        Recipes › {recipe.category}
      </p>

      {/* Header */}
      <div className="mb-5 flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{displayName}</h1>
          <p className="text-muted-foreground">{recipe.description ?? `${brandLabel} • ${recipe.category}`}</p>
          {/* Name-variant switcher (e.g. Baby / Mid / Prime Hulk) — like the size switcher. */}
          {variantFamily.length > 1 && (
            <div className="mt-2 mr-2 inline-flex gap-1 rounded-lg border bg-muted p-1 align-top">
              {variantFamily.map((v) => (
                <button
                  key={v.id}
                  onClick={() => navigate(`/recipes/${v.id}`, { replace: true })}
                  className={cn(
                    "rounded-md px-3 py-1 text-sm font-medium transition-colors",
                    v.activeId ? "bg-primary text-primary-foreground shadow" : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  {v.label}
                </button>
              ))}
            </div>
          )}
          {/* §16 Pizza size variants — switch between sizes; each is costed separately. */}
          {sizeFamily.length > 1 && (
            <div className="mt-2 inline-flex gap-1 rounded-lg border bg-muted p-1">
              {sizeFamily.map((s) => (
                <button
                  key={s.id}
                  onClick={() => navigate(`/recipes/${s.id}`, { replace: true })}
                  className={cn(
                    "rounded-md px-3 py-1 text-sm font-medium transition-colors",
                    s.id === recipe.id ? "bg-primary text-primary-foreground shadow" : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  {s.size_label}
                </button>
              ))}
            </div>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <RecipePdfButton recipe={recipe} ingredients={ingredients} foodCostPct={foodCostPct} visibility={vis} />
          {can(user.role, "recipe.duplicate") && (
            <Button
              variant="outline"
              onClick={async () => {
                const copy = await dupMut.mutateAsync(recipe.id);
                toast.success("Recipe duplicated");
                navigate(`/recipes/${copy.id}/edit`);
              }}
            >
              <Copy className="h-4 w-4" /> Duplicate
            </Button>
          )}
          {editable && (
            <Button variant="accent" onClick={() => navigate(`/recipes/${recipe.id}/edit`)}>
              <Pencil className="h-4 w-4" /> Edit Recipe
            </Button>
          )}
          {editable && recipe.status === "draft" && (
            <Button variant="accent" onClick={() => setSubmitOpen(true)}>
              <Send className="h-4 w-4" /> Submit
            </Button>
          )}
          {isAdmin && recipe.status === "testing" && (
            <>
              <Button variant="destructive" onClick={() => setRejectOpen(true)}>
                <XCircle className="h-4 w-4" /> Reject
              </Button>
              <Button
                variant="accent"
                onClick={() => setApproveOpen(true)}
              >
                <CheckCircle2 className="h-4 w-4" /> Approve
              </Button>
            </>
          )}
        </div>
      </div>

      {recipe.rejection_note && (
        <div className="mb-4 rounded-md bg-destructive/10 px-4 py-3 text-sm text-destructive">
          <strong>Rejection note:</strong> {recipe.rejection_note}
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        {/* Main column */}
        <div className="space-y-6 lg:col-span-2">
          {/* Hero card */}
          <Card className="overflow-hidden">
            <div className="grid sm:grid-cols-2">
              <div className="relative flex h-44 items-center justify-center overflow-hidden bg-gradient-to-br from-emerald-700 to-teal-900 text-6xl">
                {recipe.image_url ? (
                  <img
                    src={recipe.image_url}
                    alt={recipe.recipe_name}
                    className="absolute inset-0 h-full w-full object-cover object-center"
                  />
                ) : (
                  emojiFor(recipe.category)
                )}
                <span className="absolute left-3 top-3 rounded bg-black/40 px-2 py-1 text-[10px] font-bold uppercase tracking-wide text-white">
                  {recipe.status === "approved" ? "Active Recipe" : recipe.status}
                </span>
                {editable && (
                  <div className="absolute bottom-3 right-3 flex items-center gap-1.5">
                    <label className="inline-flex cursor-pointer items-center gap-1 rounded bg-black/50 px-2 py-1 text-[11px] font-medium text-white hover:bg-black/70">
                      <ImageUp className="h-3.5 w-3.5" />
                      {recipe.image_url ? "Change" : "Add Image"}
                      <input type="file" accept="image/*" className="hidden" onChange={onImagePick} />
                    </label>
                    {recipe.image_url && (
                      <button
                        type="button"
                        onClick={() => setRemovePhotoOpen(true)}
                        className="inline-flex items-center gap-1 rounded bg-black/50 px-2 py-1 text-[11px] font-medium text-white hover:bg-red-600/80"
                        aria-label="Remove recipe photo"
                      >
                        <ImageOff className="h-3.5 w-3.5" />
                        Remove
                      </button>
                    )}
                  </div>
                )}
              </div>
              <div className="flex flex-col justify-between p-5">
                <div className="grid grid-cols-3 gap-2 text-center">
                  <Stat icon={<Clock className="mx-auto h-4 w-4" />} label="Prep" value={recipe.preparation_time ? `${recipe.preparation_time}m` : "—"} />
                  <Stat icon={<UtensilsCrossed className="mx-auto h-4 w-4" />} label="Portions" value={String(recipe.serving_size)} />
                  <Stat label="Status" value={<StatusBadge status={recipe.status} />} />
                </div>
                <div className="mt-4 flex items-center justify-between border-t pt-3">
                  <div className="text-sm">
                    <p className="text-xs uppercase text-muted-foreground">Recipe Yield</p>
                    <p className="font-semibold">{recipe.serving_size} Portion{recipe.serving_size > 1 ? "s" : ""}</p>
                  </div>
                </div>
              </div>
            </div>
          </Card>

          {/* Tabs */}
          <Card className="p-5">
            <Tabs defaultValue="ingredients">
              <TabsList>
                <TabsTrigger value="ingredients">Ingredients</TabsTrigger>
                <TabsTrigger value="method">Method</TabsTrigger>
                {showFinancials && <TabsTrigger value="financials">Financials</TabsTrigger>}
                {(isAdmin || editable) && <TabsTrigger value="history">History</TabsTrigger>}
              </TabsList>

              <TabsContent value="ingredients">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Ingredient Name</TableHead>
                      {vis.quantities && <TableHead className="text-right">Qty</TableHead>}
                      {vis.quantities && <TableHead>Unit</TableHead>}
                      {vis.totalCost && <TableHead className="text-right">Cost</TableHead>}
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {ingredients.map((ing) => {
                      const sub = ing.subRecipe;
                      const m = ing.material;
                      if (ing.component_type === "recipe" && sub) {
                        // Sub-recipe (in-house prep) component — double-click to open it.
                        const perUnit = prepUnitCostFrom(sub.total_cost ?? 0, sub.yield_quantity, sub.wastage_pct ?? 0);
                        const cost = round2(perUnit * ing.quantity_used * scale);
                        const openSub = () =>
                          navigate(`/recipes/${sub.id}`, {
                            state: { fromRecipe: recipe.id, fromName: recipe.recipe_name },
                          });
                        return (
                          <TableRow
                            key={ing.id}
                            className="cursor-pointer"
                            title="Open sub-recipe — tap the name, or double-click the row"
                            onDoubleClick={openSub}
                          >
                            <TableCell className="font-medium">
                              {/* Tappable on mobile + clickable on desktop; row also double-clicks. */}
                              <button
                                type="button"
                                onClick={openSub}
                                className="inline-flex items-center gap-1.5 text-emerald-700 underline decoration-dotted underline-offset-2 hover:text-emerald-900"
                                title="View sub-recipe"
                                aria-label={`View sub-recipe ${sub.recipe_name}`}
                              >
                                <UtensilsCrossed className="h-3.5 w-3.5" />
                                {sub.recipe_name}
                                <ExternalLink className="h-3 w-3 opacity-70" />
                              </button>
                              <span className="ml-2 rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-emerald-700">Prep</span>
                            </TableCell>
                            {vis.quantities && <TableCell className="text-right font-mono">{round3(ing.quantity_used * scale)}</TableCell>}
                            {vis.quantities && <TableCell className="text-muted-foreground">{ing.unit_used}</TableCell>}
                            {vis.totalCost && <TableCell className="text-right font-mono font-semibold">{formatINR(cost)}</TableCell>}
                          </TableRow>
                        );
                      }
                      // Display the quantity in the ingredient's purchase unit (KG/Litre):
                      // e.g. 600 Gram → 0.6 KG. Cost is for the quantity actually used.
                      const displayUnit = m?.purchase_unit ?? ing.unit_used;
                      const qtyInPurchase =
                        m && canConvert(ing.unit_used, m.purchase_unit)
                          ? round3(ing.quantity_used * scale * getConversionFactor(ing.unit_used, m.purchase_unit))
                          : round3(ing.quantity_used * scale);
                      // Persisted (yield-adjusted) line cost — single source of truth (§9).
                      const cost = ing.calculated_cost == null ? null : round2(ing.calculated_cost * scale);
                      return (
                        <TableRow key={ing.id}>
                          <TableCell className="font-medium">
                            {m?.ingredient_name ?? "—"}
                            {ing.cut_type && (
                              <span className="ml-1.5 rounded bg-muted px-1.5 py-0.5 text-[11px] font-normal text-muted-foreground">{ing.cut_type}</span>
                            )}
                          </TableCell>
                          {vis.quantities && <TableCell className="text-right font-mono">{qtyInPurchase}</TableCell>}
                          {vis.quantities && <TableCell className="text-muted-foreground">{displayUnit}</TableCell>}
                          {vis.totalCost && <TableCell className="text-right font-mono font-semibold">{formatINR(cost)}</TableCell>}
                        </TableRow>
                      );
                    })}
                    {vis.totalCost && (
                      <>
                        <TableRow className="border-t-2">
                          <TableCell colSpan={vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            Total Raw Ingredient Cost
                          </TableCell>
                          <TableCell className="text-right font-mono">{formatINR(rawIngredientCost)}</TableCell>
                        </TableRow>
                        {(recipe.wastage_pct ?? 0) > 0 && (
                          <TableRow>
                            <TableCell colSpan={vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                              Wastage ({recipe.wastage_pct}%)
                            </TableCell>
                            <TableCell className="text-right font-mono text-amber-600">+{formatINR(wastageAmount)}</TableCell>
                          </TableRow>
                        )}
                        <TableRow>
                          <TableCell colSpan={vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                            Total Recipe Cost
                          </TableCell>
                          <TableCell className="text-right font-mono text-base font-bold text-emerald-700">
                            {formatINR(batchCost)}
                          </TableCell>
                        </TableRow>
                        {packaging > 0 && (
                          <>
                            <TableRow>
                              <TableCell colSpan={vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                                Packaging / Portion
                              </TableCell>
                              <TableCell className="text-right font-mono text-muted-foreground">+{formatINR(packaging)}</TableCell>
                            </TableRow>
                            <TableRow>
                              <TableCell colSpan={vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                                Full Cost / Portion
                              </TableCell>
                              <TableCell className="text-right font-mono text-base font-bold text-emerald-700">{formatINR(fullCpp)}</TableCell>
                            </TableRow>
                          </>
                        )}
                      </>
                    )}
                  </TableBody>
                </Table>
              </TabsContent>

              <TabsContent value="method">
                {recipe.method && recipe.method.length > 0 ? (
                  <ol className="space-y-2.5 py-2">
                    {recipe.method.map((step, i) => (
                      <li key={i} className="flex gap-3 text-sm">
                        <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary">
                          {i + 1}
                        </span>
                        <span className="pt-0.5">{step}</span>
                      </li>
                    ))}
                  </ol>
                ) : (
                  <p className="whitespace-pre-wrap py-2 text-sm text-muted-foreground">
                    {recipe.description?.trim() || "No preparation method recorded for this recipe."}
                  </p>
                )}
              </TabsContent>

              {showFinancials && (
                <TabsContent value="financials">
                  <div className="space-y-1 py-2 text-sm">
                    <FinRow label="Total Recipe Cost" value={formatINR(recipe.total_cost)} />
                    {recipe.serving_size > 1 && (
                      <FinRow label={`Cost Per Portion (÷${recipe.serving_size})`} value={formatINR(portionCost)} />
                    )}
                    {packaging > 0 && (
                      <>
                        <FinRow label="Packaging / Portion" value={formatINR(packaging)} />
                        <FinRow label="Full Cost / Portion" value={formatINR(fullCpp)} />
                      </>
                    )}
                    <FinRow label={`Suggested Price (${foodCostPct}% food cost)`} value={formatINR(round2(fullCpp / (foodCostPct / 100)))} strong />
                    <FinRow label="Menu Price" value={formatINR(menuPrice)} />
                    <FinRow label="Gross Margin" value={`${marginPct}%`} />
                  </div>
                </TabsContent>
              )}

              {(isAdmin || editable) && (
                <TabsContent value="history">
                  {(costHistory.data ?? []).length === 0 ? (
                    <p className="py-4 text-sm text-muted-foreground">No cost changes recorded.</p>
                  ) : (
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Date</TableHead>
                          <TableHead>Old Total</TableHead>
                          <TableHead>New Total</TableHead>
                          <TableHead>Reason</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {(costHistory.data ?? []).map((h) => (
                          <TableRow key={h.id}>
                            <TableCell>{formatDate(h.changed_at)}</TableCell>
                            <TableCell>{formatINR(h.old_total_cost)}</TableCell>
                            <TableCell>{formatINR(h.new_total_cost)}</TableCell>
                            <TableCell className="text-muted-foreground">{h.change_reason}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  )}
                  <p className="mt-3 text-xs text-muted-foreground">
                    {(versions.data ?? []).length} version(s) saved.
                  </p>
                </TabsContent>
              )}
            </Tabs>
          </Card>
        </div>

        {/* Financial sidebar */}
        <div className="space-y-4">
          {showFinancials ? (
            <>
              <Card className="p-5">
                <div className="mb-4 flex items-center justify-between">
                  <p className="font-semibold">Financial Metrics</p>
                  <TrendingUp className="h-4 w-4 text-emerald-600" />
                </div>
                <div className="space-y-3 text-sm">
                  <FinRow label="Total Recipe Cost" value={formatINR(batchCost)} strong />
                  {recipe.serving_size > 1 && (
                    <FinRow label={`Portion Cost (1/${recipe.serving_size})`} value={formatINR(portionCost)} accent />
                  )}
                </div>

                <div className="my-4 grid grid-cols-2 gap-3 rounded-lg bg-emerald-50 p-3">
                  <div>
                    <p className="text-[10px] font-semibold uppercase text-muted-foreground">Current Margin</p>
                    <p className="text-xl font-bold text-emerald-700">{marginPct}%</p>
                  </div>
                  <div>
                    <p className="text-[10px] font-semibold uppercase text-muted-foreground">Selling Price</p>
                    <p className="text-xl font-bold">{formatINR(menuPrice)}</p>
                  </div>
                </div>

                {editable && (
                  <div className="mb-2">
                    <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                      Selling Price
                    </p>
                    <div className="flex items-center gap-2">
                      <div className="relative flex-1">
                        <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground">₹</span>
                        <Input
                          type="number"
                          step="0.01"
                          className="pl-6"
                          value={sellingInput}
                          onChange={(e) => setSellingInput(e.target.value)}
                          placeholder="Suggested"
                        />
                      </div>
                      <Button
                        size="sm"
                        variant="accent"
                        disabled={sellingMut.isPending}
                        onClick={async () => {
                          const v = sellingInput.trim() === "" ? null : Number(sellingInput);
                          if (v !== null && !(v > 0)) {
                            toast.error("Menu price must be greater than 0");
                            return;
                          }
                          await sellingMut.mutateAsync({ id: recipe.id, price: v });
                          toast.success("Selling price updated");
                        }}
                      >
                        Save
                      </Button>
                    </div>
                    <p className="mt-1 text-[11px] text-muted-foreground">Leave blank to use the suggested price.</p>
                  </div>
                )}

                <div className="mt-4 border-t pt-3">
                  <div className="mb-1 flex items-center justify-between text-xs">
                    <span className="font-semibold uppercase tracking-wide text-muted-foreground">Efficiency vs Target</span>
                    <span className="font-semibold">{efficiency}%</span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-muted">
                    <div className="h-full rounded-full bg-emerald-600" style={{ width: `${efficiency}%` }} />
                  </div>
                </div>
              </Card>

              <Card className="border-red-200 bg-red-50 p-4">
                <div className="flex gap-3">
                  <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-red-600" />
                  <div>
                    <p className="text-sm font-semibold text-red-700">Supplier Price Volatility</p>
                    <p className="mt-1 text-xs text-red-600">
                      Ingredient prices can shift weekly. Review costing before locking the menu price.
                    </p>
                  </div>
                </div>
              </Card>
            </>
          ) : (
            <Card className="p-5 text-sm text-muted-foreground">
              Costing details are hidden for this view.
            </Card>
          )}

          <div className="rounded-lg border p-4 text-xs text-muted-foreground">
            Created by {usersMap.get(recipe.created_by ?? "")?.name ?? "—"}
            {recipe.approved_by && (
              <> • Approved by {usersMap.get(recipe.approved_by)?.name ?? "—"} on {formatDate(recipe.approved_at)}</>
            )}
          </div>
        </div>
      </div>

      {/* Submit dialog */}
      <Dialog open={submitOpen} onOpenChange={setSubmitOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Submit for Approval</DialogTitle>
            <DialogDescription>Add an optional note for the reviewer.</DialogDescription>
          </DialogHeader>
          <Textarea placeholder="Notes to reviewer (optional)…" value={submitNote} onChange={(e) => setSubmitNote(e.target.value)} />
          <DialogFooter>
            <Button variant="outline" onClick={() => setSubmitOpen(false)}>Cancel</Button>
            <Button
              variant="accent"
              onClick={async () => {
                await submitMut.mutateAsync({ id: recipe.id, note: submitNote || null });
                toast.success("Submitted for testing");
                setSubmitOpen(false);
              }}
            >
              Submit for Testing
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ConfirmDialog
        open={approveOpen}
        onOpenChange={setApproveOpen}
        title="Approve recipe?"
        description={`"${recipe.recipe_name}" will become available to assigned viewers.`}
        confirmLabel="Approve"
        onConfirm={async () => {
          await approveMut.mutateAsync(recipe.id);
          toast.success("Recipe approved");
        }}
      />

      <ConfirmDialog
        open={removePhotoOpen}
        onOpenChange={setRemovePhotoOpen}
        title="Remove this recipe photo?"
        description="The photo will be removed and the placeholder shown. The recipe itself is not affected."
        confirmLabel="Remove Photo"
        onConfirm={async () => {
          await imageMut.mutateAsync({ id: recipe.id, imageUrl: null });
          toast.success("Recipe photo removed");
        }}
      />

      <Dialog open={rejectOpen} onOpenChange={setRejectOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Reject Recipe</DialogTitle>
            <DialogDescription>The recipe returns to Draft. A note is required.</DialogDescription>
          </DialogHeader>
          <Textarea placeholder="Reason for rejection…" value={rejectNote} onChange={(e) => setRejectNote(e.target.value)} />
          <DialogFooter>
            <Button variant="outline" onClick={() => setRejectOpen(false)}>Cancel</Button>
            <Button
              variant="destructive"
              disabled={!rejectNote.trim()}
              onClick={async () => {
                await rejectMut.mutateAsync({ id: recipe.id, note: rejectNote.trim() });
                toast.success("Recipe rejected");
                setRejectOpen(false);
                setRejectNote("");
              }}
            >
              Reject Recipe
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

function Stat({ icon, label, value }: { icon?: React.ReactNode; label: string; value: React.ReactNode }) {
  return (
    <div>
      {icon}
      <p className="mt-1 text-[10px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <div className="text-sm font-semibold">{value}</div>
    </div>
  );
}

function FinRow({ label, value, strong, accent }: { label: string; value: string; strong?: boolean; accent?: boolean }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-muted-foreground">{label}</span>
      <span className={cn("font-mono", strong && "text-base font-bold", accent && "font-semibold text-emerald-700")}>{value}</span>
    </div>
  );
}
