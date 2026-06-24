import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
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
} from "lucide-react";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
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
import { calculateIngredientCost, round2 } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import { BRANDS } from "@/lib/data/types";
import { useSession } from "@/lib/auth/session";
import { can, canEditRecipe, visibilityFor } from "@/lib/auth/permissions";
import { toast } from "@/components/ui/use-toast";
import { useUsersMap } from "@/features/users/hooks";
import { useUserViews } from "@/features/viewers/hooks";
import { useFoodCostPct } from "@/features/settings/hooks";
import { menuPriceOf } from "./recipeMetrics";
import { RecipePdfButton } from "@/features/reports/RecipePdfButton";
import {
  useApproveRecipe,
  useDuplicateRecipe,
  useRecipe,
  useRecipeCostHistory,
  useRecipeVersions,
  useRejectRecipe,
  useSubmitRecipe,
} from "./hooks";

const CATEGORY_EMOJI: Record<string, string> = {
  Pasta: "🍝", Rice: "🍚", Dessert: "🍰", Beverage: "🍵", Protein: "🍗",
};
const emojiFor = (c: string) => CATEGORY_EMOJI[c] ?? "🍽️";
const SCALES = [1, 2, 5];

export function RecipeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const user = useSession((s) => s.user)!;

  const { data, isLoading } = useRecipe(id);
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { map: usersMap } = useUsersMap();
  const { data: myViews = [] } = useUserViews(user.role === "viewer" ? user.id : undefined);
  const costHistory = useRecipeCostHistory(id);
  const versions = useRecipeVersions(id);

  const dupMut = useDuplicateRecipe();
  const submitMut = useSubmitRecipe();
  const approveMut = useApproveRecipe();
  const rejectMut = useRejectRecipe();

  const [scale, setScale] = useState(1);
  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitNote, setSubmitNote] = useState("");
  const [rejectOpen, setRejectOpen] = useState(false);
  const [rejectNote, setRejectNote] = useState("");
  const [approveOpen, setApproveOpen] = useState(false);

  if (isLoading) return <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>;
  if (!data) return <EmptyState title="Recipe not found" />;

  const { recipe, ingredients } = data;

  // Viewer access enforcement (PRD §14).
  const myView = myViews.find((v) => v.recipe_id === recipe.id) ?? null;
  if (user.role === "viewer" && (!myView || recipe.status !== "approved")) {
    return (
      <EmptyState
        icon={<Lock className="h-10 w-10" />}
        title="No access"
        description="This recipe hasn't been shared with you."
      />
    );
  }

  const vis = visibilityFor(user.role, myView?.view_type ?? null);
  const editable = canEditRecipe(user, recipe);
  const isAdmin = can(user.role, "recipe.approve");
  const showFinancials = vis.totalCost;

  const batchCost = round2((recipe.total_cost ?? 0) * scale);
  const portionCost = recipe.cost_per_portion ?? 0;
  const menuPrice = menuPriceOf(recipe, foodCostPct);
  const marginPct = menuPrice > 0 ? round2(((menuPrice - portionCost) / menuPrice) * 100) : 0;
  const brandLabel = BRANDS.find((b) => b.value === recipe.brand)?.label ?? recipe.brand;

  // Price recommendation engine — suggested price at each food-cost target.
  const recommendations = [25, 30, 35].map((pct) => ({
    pct,
    price: portionCost > 0 ? round2(portionCost / (pct / 100)) : 0,
  }));
  const actualFc = menuPrice > 0 ? round2((portionCost / menuPrice) * 100) : foodCostPct;
  const efficiency = Math.max(0, Math.min(100, Math.round((foodCostPct / Math.max(actualFc, 1)) * 100)));

  return (
    <>
      {/* Breadcrumb */}
      <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        Recipes › {recipe.category}
      </p>

      {/* Header */}
      <div className="mb-5 flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{recipe.recipe_name}</h1>
          <p className="text-muted-foreground">{recipe.description ?? `${brandLabel} • ${recipe.category}`}</p>
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
            <Button
              className="bg-emerald-800 text-white hover:bg-emerald-900"
              onClick={() => navigate(`/recipes/${recipe.id}/edit`)}
            >
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
                className="bg-emerald-800 text-white hover:bg-emerald-900"
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
              <div className="relative flex h-44 items-center justify-center bg-gradient-to-br from-emerald-700 to-teal-900 text-6xl">
                {emojiFor(recipe.category)}
                <span className="absolute left-3 top-3 rounded bg-black/40 px-2 py-1 text-[10px] font-bold uppercase tracking-wide text-white">
                  {recipe.status === "approved" ? "Active Recipe" : recipe.status}
                </span>
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
                    <p className="font-semibold">{recipe.serving_size * scale} Portions</p>
                  </div>
                  <div className="inline-flex rounded-lg border bg-muted p-1">
                    {SCALES.map((s) => (
                      <button
                        key={s}
                        onClick={() => setScale(s)}
                        className={cn(
                          "rounded-md px-3 py-1 text-sm font-medium transition-colors",
                          scale === s ? "bg-background shadow" : "text-muted-foreground hover:text-foreground",
                        )}
                      >
                        {s}X
                      </button>
                    ))}
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
                      {vis.unitCosts && <TableHead className="text-right">Price / Unit</TableHead>}
                      {vis.totalCost && <TableHead className="text-right">Subtotal</TableHead>}
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {ingredients.map((ing) => {
                      const m = ing.material;
                      const ok = m && m.cost_per_base_unit !== null && canConvert(ing.unit_used, m.base_unit);
                      const pricePerUnit = ok ? calculateIngredientCost(m!.cost_per_base_unit!, 1, ing.unit_used, m!.base_unit) : null;
                      const subtotal = ok ? round2(calculateIngredientCost(m!.cost_per_base_unit!, ing.quantity_used, ing.unit_used, m!.base_unit) * scale) : null;
                      return (
                        <TableRow key={ing.id}>
                          <TableCell className="font-medium">{m?.ingredient_name ?? "—"}</TableCell>
                          {vis.quantities && <TableCell className="text-right font-mono">{round2(ing.quantity_used * scale)}</TableCell>}
                          {vis.quantities && <TableCell className="text-muted-foreground">{ing.unit_used}</TableCell>}
                          {vis.unitCosts && <TableCell className="text-right font-mono text-muted-foreground">{formatINR(pricePerUnit)}</TableCell>}
                          {vis.totalCost && <TableCell className="text-right font-mono font-semibold">{formatINR(subtotal)}</TableCell>}
                        </TableRow>
                      );
                    })}
                    {vis.totalCost && (
                      <TableRow className="border-t-2">
                        <TableCell colSpan={vis.unitCosts ? 4 : vis.quantities ? 3 : 1} className="text-right text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                          Total Raw Ingredient Cost
                        </TableCell>
                        <TableCell className="text-right font-mono text-base font-bold text-emerald-700">
                          {formatINR(batchCost)}
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </TabsContent>

              <TabsContent value="method">
                <p className="whitespace-pre-wrap py-2 text-sm text-muted-foreground">
                  {recipe.description?.trim() || "No preparation method recorded for this recipe."}
                </p>
              </TabsContent>

              {showFinancials && (
                <TabsContent value="financials">
                  <div className="space-y-1 py-2 text-sm">
                    <FinRow label="Total Recipe Cost" value={formatINR(recipe.total_cost)} />
                    {recipe.serving_size > 1 && (
                      <FinRow label={`Cost Per Portion (÷${recipe.serving_size})`} value={formatINR(portionCost)} />
                    )}
                    <FinRow label={`Suggested Price (${foodCostPct}% food cost)`} value={formatINR(round2(portionCost / (foodCostPct / 100)))} strong />
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

                <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                  Price Recommendation Engine
                </p>
                <div className="space-y-2">
                  {recommendations.map((r) => (
                    <div
                      key={r.pct}
                      className={cn(
                        "flex items-center justify-between rounded-md border px-3 py-2 text-sm",
                        r.pct === foodCostPct && "border-emerald-400 bg-emerald-50",
                      )}
                    >
                      <span>Target {r.pct}% Food Cost</span>
                      <span className="font-mono font-semibold">{formatINR(r.price)}</span>
                    </div>
                  ))}
                </div>

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
