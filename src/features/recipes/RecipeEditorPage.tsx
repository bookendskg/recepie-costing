import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams, useLocation } from "react-router-dom";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2, Plus, Trash2, AlertTriangle } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { recipeHeaderSchema, type RecipeHeaderValues } from "@/lib/validation/schemas";
import { compatibleUnits, canConvert } from "@/lib/units";
import { calculateIngredientCost, prepUnitCostFrom, round2 } from "@/lib/costing";
import { activeYield, effectiveCostPerBaseUnit, costForCutYield } from "@/lib/yield";
import { cutsForName, cutYieldPct, resolveParentAndCut } from "@/lib/data/ingredientCuts";
import { cn, formatINR } from "@/lib/utils";
import { toast } from "@/components/ui/use-toast";
import { BRANDS, type RawMaterial } from "@/lib/data/types";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useYields } from "@/features/yield/hooks";
import { useFoodCostPct, useRecipeCategories } from "@/features/settings/hooks";
import { useRecipeCosting, type EditorLine } from "@/features/costing/useRecipeCosting";
import { CostSummary } from "@/features/costing/CostSummary";
import { IngredientPicker, type ComponentPick } from "./IngredientPicker";
import { useCreateRecipe, useRecipe, useRecipes, useSubmitRecipe, useUpdateRecipe } from "./hooks";
import type { Recipe } from "@/lib/data/types";

interface GridLine extends EditorLine {
  key: string;
}

let keyCounter = 0;
const newKey = () => `line-${keyCounter++}`;

export function RecipeEditorPage() {
  const { id } = useParams();
  const isEdit = !!id;
  const navigate = useNavigate();
  const location = useLocation();
  const newPrep = !!(location.state as { isPrep?: boolean } | null)?.isPrep;

  const { data: materials = [] } = useMaterials();
  const { data: yields = [] } = useYields();
  const { data: allRecipes = [] } = useRecipes();
  const { data: categories = [] } = useRecipeCategories();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { data: existing, isLoading: loadingRecipe } = useRecipe(id);

  const createMut = useCreateRecipe();
  const updateMut = useUpdateRecipe();
  const submitMut = useSubmitRecipe();

  const activeMaterials = useMemo(() => materials.filter((m) => m.status === "active"), [materials]);
  const materialsById = useMemo(() => {
    const map = new Map<string, RawMaterial>();
    materials.forEach((m) => map.set(m.id, m));
    return map;
  }, [materials]);
  // In-house prep recipes selectable as components (never include this recipe itself).
  const prepRecipes = useMemo(
    () => allRecipes.filter((r) => r.is_prep && r.id !== id).sort((a, b) => a.recipe_name.localeCompare(b.recipe_name)),
    [allRecipes, id],
  );
  const prepsById = useMemo(() => new Map<string, Recipe>(allRecipes.map((r) => [r.id, r])), [allRecipes]);

  const [lines, setLines] = useState<GridLine[]>([]);
  const [method, setMethod] = useState("");
  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitNote, setSubmitNote] = useState("");
  const [pendingRecipeId, setPendingRecipeId] = useState<string | null>(null);

  const form = useForm<RecipeHeaderValues>({
    resolver: zodResolver(recipeHeaderSchema),
    defaultValues: {
      recipe_name: "",
      category: "",
      brand: "capiche",
      description: "",
      preparation_time: null,
      serving_size: 1,
      selling_price: null,
      packaging_cost: 0,
      wastage_pct: 0,
    },
  });
  const { register, handleSubmit, reset, watch, setValue, formState } = form;

  // Hydrate when editing.
  useEffect(() => {
    if (isEdit && existing) {
      reset({
        recipe_name: existing.recipe.recipe_name,
        category: existing.recipe.category,
        brand: existing.recipe.brand,
        description: existing.recipe.description ?? "",
        preparation_time: existing.recipe.preparation_time,
        serving_size: 1, // single-portion recipes
        selling_price: existing.recipe.selling_price,
        packaging_cost: existing.recipe.packaging_cost ?? 0,
        wastage_pct: existing.recipe.wastage_pct,
      });
      setMethod((existing.recipe.method ?? []).join("\n"));
      setLines(
        existing.ingredients.map((i) => ({
          key: newKey(),
          ingredient_id: i.ingredient_id,
          component_type: i.component_type,
          quantity_used: i.quantity_used,
          unit_used: i.unit_used,
          wastage_override_pct: i.wastage_override_pct ?? null,
          cut_type: i.cut_type ?? null,
        })),
      );
    } else if (!isEdit) {
      setValue("category", newPrep ? "In-House Prep" : categories[0] ?? "");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isEdit, existing, categories.length]);

  const servingSize = watch("serving_size") || 1;
  const costing = useRecipeCosting(
    lines.map((l) => ({
      ingredient_id: l.ingredient_id,
      component_type: l.component_type,
      quantity_used: l.quantity_used,
      unit_used: l.unit_used,
      wastage_override_pct: l.wastage_override_pct,
      cut_type: l.cut_type,
    })),
    materialsById,
    prepsById,
    servingSize,
    foodCostPct,
    watch("wastage_pct") || 0,
    watch("packaging_cost") || 0,
    yields,
  );

  const addLine = () =>
    setLines((prev) => [...prev, { key: newKey(), ingredient_id: "", component_type: "material", quantity_used: 0, unit_used: "" }]);
  const removeLine = (key: string) => setLines((prev) => prev.filter((l) => l.key !== key));
  const patchLine = (key: string, patch: Partial<GridLine>) =>
    setLines((prev) => prev.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const selectComponent = (key: string, pick: ComponentPick) => {
    if (pick.type === "recipe") {
      patchLine(key, { ingredient_id: pick.recipe.id, component_type: "recipe", unit_used: pick.recipe.yield_unit });
    } else {
      patchLine(key, { ingredient_id: pick.material.id, component_type: "material", unit_used: pick.material.base_unit });
    }
  };

  /** Build the validated line payload, or null + toast on a blocking error. */
  const buildLines = (): EditorLine[] | null => {
    if (lines.length === 0) {
      toast.error("Add at least one ingredient");
      return null;
    }
    for (const l of lines) {
      if (!l.ingredient_id) {
        toast.error("Select an ingredient for every row");
        return null;
      }
      if (!(l.quantity_used > 0)) {
        toast.error("Quantity must be greater than 0");
        return null;
      }
    }
    return lines.map((l) => ({
      ingredient_id: l.ingredient_id,
      component_type: l.component_type ?? "material",
      quantity_used: l.quantity_used,
      unit_used: l.unit_used,
      wastage_override_pct: l.wastage_override_pct ?? null,
      cut_type: l.cut_type ?? null,
    }));
  };

  // Preserve prep status on edit; honour the "New Prep" entry point on create.
  const effectiveIsPrep = isEdit ? existing?.recipe.is_prep ?? false : newPrep;
  const withPrep = (h: RecipeHeaderValues) => ({
    ...h,
    is_prep: effectiveIsPrep,
    method: method.split("\n").map((s) => s.trim()).filter(Boolean),
  });

  const saveDraft = handleSubmit(async (h) => {
    const header = withPrep(h);
    const payload = buildLines();
    if (!payload) return;
    try {
      if (isEdit && id) {
        await updateMut.mutateAsync({ id, header, lines: payload });
        toast.success("Recipe saved");
        navigate(`/recipes/${id}`);
      } else {
        const created = await createMut.mutateAsync({ header, lines: payload });
        toast.success("Recipe created");
        navigate(`/recipes/${created.id}`);
      }
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    }
  });

  // Submit for approval — PRD §5.5 pre-submit validation, then save + submit.
  const beginSubmit = handleSubmit(async (h) => {
    const header = withPrep(h);
    const payload = buildLines();
    if (!payload) return;
    if (costing.hasMissingPrice) {
      const bad = costing.lines.find((l) => l.missingPrice);
      toast.error(
        `Ingredient "${bad?.material?.ingredient_name}" has no price set. Update price before submitting.`,
      );
      return;
    }
    if (costing.totalCost <= 0) {
      toast.error("Total cost cannot be zero. Review ingredients.");
      return;
    }
    try {
      let recipeId = id ?? null;
      if (isEdit && id) {
        await updateMut.mutateAsync({ id, header, lines: payload });
      } else {
        const created = await createMut.mutateAsync({ header, lines: payload });
        recipeId = created.id;
      }
      setPendingRecipeId(recipeId);
      setSubmitOpen(true);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    }
  });

  const confirmSubmit = async () => {
    if (!pendingRecipeId) return;
    try {
      await submitMut.mutateAsync({ id: pendingRecipeId, note: submitNote || null });
      toast.success("Submitted for testing");
      setSubmitOpen(false);
      navigate(`/recipes/${pendingRecipeId}`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Submit failed");
    }
  };

  const busy = createMut.isPending || updateMut.isPending;
  if (isEdit && loadingRecipe) {
    return <p className="p-8 text-center text-sm text-muted-foreground">Loading recipe…</p>;
  }

  return (
    <>
      <PageHeader
        title={isEdit ? "Edit Recipe" : "Create Recipe"}
        description={isEdit ? "Editing an approved recipe reverts it to Draft." : undefined}
      />

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {/* Header */}
          <Card className="space-y-4 p-5">
            <div className="space-y-1.5">
              <Label>Recipe Name *</Label>
              <Input {...register("recipe_name")} />
              {formState.errors.recipe_name && (
                <p className="text-xs text-destructive">{formState.errors.recipe_name.message}</p>
              )}
            </div>
            <div className="space-y-1.5">
              <Label>Brand *</Label>
              <Select
                value={watch("brand")}
                onValueChange={(v) => setValue("brand", v as RecipeHeaderValues["brand"])}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Select brand" />
                </SelectTrigger>
                <SelectContent>
                  {BRANDS.map((b) => (
                    <SelectItem key={b.value} value={b.value}>
                      {b.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {formState.errors.brand && (
                <p className="text-xs text-destructive">{formState.errors.brand.message}</p>
              )}
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Category *</Label>
                <Select value={watch("category")} onValueChange={(v) => setValue("category", v)}>
                  <SelectTrigger>
                    <SelectValue placeholder="Select category" />
                  </SelectTrigger>
                  <SelectContent>
                    {categories.map((c) => (
                      <SelectItem key={c} value={c}>
                        {c}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {formState.errors.category && (
                  <p className="text-xs text-destructive">{formState.errors.category.message}</p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Prep (min)</Label>
                <Input
                  type="number"
                  {...register("preparation_time", {
                    setValueAs: (v) => (v === "" || v === null ? null : Number(v)),
                  })}
                />
              </div>
            </div>
            {/* Recipes are single-portion: serving size is fixed at 1. */}
            <div className="space-y-1.5">
              <Label>Menu Price (₹)</Label>
              <Input
                type="number"
                step="0.01"
                placeholder="Leave blank to use the suggested price"
                {...register("selling_price", {
                  setValueAs: (v) => (v === "" || v === null ? null : Number(v)),
                })}
              />
              <p className="text-xs text-muted-foreground">
                The actual menu price. Drives the food cost % shown on the recipe list.
              </p>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Wastage (%)</Label>
                <Input
                  type="number"
                  step="0.1"
                  {...register("wastage_pct", { setValueAs: (v) => (v === "" ? 0 : Number(v)) })}
                />
                {formState.errors.wastage_pct && (
                  <p className="text-xs text-destructive">{formState.errors.wastage_pct.message}</p>
                )}
                <p className="text-xs text-muted-foreground">Trimming/peeling loss, on top of cost.</p>
              </div>
              <div className="space-y-1.5">
                <Label>Packaging (₹/portion)</Label>
                <Input
                  type="number"
                  step="0.01"
                  {...register("packaging_cost", { setValueAs: (v) => (v === "" ? 0 : Number(v)) })}
                />
                {formState.errors.packaging_cost && (
                  <p className="text-xs text-destructive">{formState.errors.packaging_cost.message}</p>
                )}
                <p className="text-xs text-muted-foreground">Box/container cost per portion.</p>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>Description</Label>
              <Textarea rows={2} {...register("description")} />
            </div>
            <div className="space-y-1.5">
              <Label>Method</Label>
              <Textarea
                rows={6}
                value={method}
                onChange={(e) => setMethod(e.target.value)}
                placeholder="One step per line…"
              />
              <p className="text-xs text-muted-foreground">Preparation steps — one per line; shown as a numbered list.</p>
            </div>
          </Card>

          {/* Ingredient grid */}
          <Card className="p-5">
            <div className="mb-3 flex items-center justify-between">
              <p className="text-sm font-semibold">Ingredients</p>
              <Button type="button" variant="outline" size="sm" onClick={addLine}>
                <Plus className="h-4 w-4" /> Add Ingredient
              </Button>
            </div>

            {lines.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                No ingredients yet. Click “Add Ingredient”.
              </p>
            ) : (
              <div className="space-y-2">
                <div className="hidden grid-cols-12 gap-2 px-1 text-xs font-medium text-muted-foreground sm:grid">
                  <div className="col-span-5">Ingredient</div>
                  <div className="col-span-2">Qty</div>
                  <div className="col-span-2">Unit</div>
                  <div className="col-span-2 text-right">Total</div>
                  <div className="col-span-1" />
                </div>
                {lines.map((line) => {
                  const isPrep = line.component_type === "recipe";
                  const prep = isPrep ? prepsById.get(line.ingredient_id) ?? null : null;
                  const material = !isPrep ? materialsById.get(line.ingredient_id) ?? null : null;
                  const units = prep ? [prep.yield_unit] : material ? compatibleUnits(material.base_unit) : [];
                  const yieldRec = material ? activeYield(yields, material.id) : null;
                  let lineCost: number | null = null;
                  if (prep && line.quantity_used > 0) {
                    const perUnit = prepUnitCostFrom(prep.total_cost ?? 0, prep.yield_quantity, prep.wastage_pct ?? 0);
                    lineCost = round2(perUnit * line.quantity_used);
                  } else if (material && line.quantity_used > 0 && canConvert(line.unit_used, material.base_unit)) {
                    // Cut yield takes priority; else §9/§10 yield-adjusted rate.
                    const cutY = line.cut_type
                      ? cutYieldPct(resolveParentAndCut(material.ingredient_name).parent ?? "", line.cut_type)
                      : null;
                    const rate =
                      cutY != null
                        ? costForCutYield(material.cost_per_base_unit, cutY)
                        : effectiveCostPerBaseUnit(material.cost_per_base_unit, yieldRec, line.wastage_override_pct);
                    if (rate !== null) {
                      lineCost = calculateIngredientCost(rate, line.quantity_used, line.unit_used, material.base_unit);
                    }
                  }
                  const cutOptions = material ? cutsForName(material.ingredient_name) : [];
                  const stdWastage = yieldRec?.wastage_percentage ?? 0;
                  const effWastage = line.wastage_override_pct ?? stdWastage;
                  const hasOverride = line.wastage_override_pct != null;
                  return (
                    <div key={line.key} className="space-y-1.5 border-b border-dashed pb-2 last:border-0">
                    <div className="grid grid-cols-12 items-center gap-2">
                      <div className="col-span-12 sm:col-span-5">
                        <IngredientPicker
                          materials={activeMaterials}
                          preps={prepRecipes}
                          value={line.ingredient_id || null}
                          onSelect={(pick) => selectComponent(line.key, pick)}
                        />
                      </div>
                      <div className="col-span-4 sm:col-span-2">
                        <Input
                          type="number"
                          step="0.001"
                          value={line.quantity_used || ""}
                          onChange={(e) =>
                            patchLine(line.key, { quantity_used: Number(e.target.value) })
                          }
                        />
                      </div>
                      <div className="col-span-4 sm:col-span-2">
                        <Select
                          value={line.unit_used}
                          onValueChange={(v) => patchLine(line.key, { unit_used: v })}
                          disabled={!material && !prep}
                        >
                          <SelectTrigger>
                            <SelectValue placeholder="Unit" />
                          </SelectTrigger>
                          <SelectContent>
                            {units.map((u) => (
                              <SelectItem key={u} value={u}>
                                {u}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </div>
                      <div className="col-span-3 text-right text-sm font-medium sm:col-span-2">
                        {material && material.cost_per_base_unit === null ? (
                          <span className="inline-flex items-center gap-1 text-amber-600">
                            <AlertTriangle className="h-3.5 w-3.5" /> No price
                          </span>
                        ) : (
                          formatINR(lineCost)
                        )}
                      </div>
                      <div className="col-span-1 text-right">
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          onClick={() => removeLine(line.key)}
                        >
                          <Trash2 className="h-4 w-4 text-destructive" />
                        </Button>
                      </div>
                    </div>
                    {/* Cut / prep variant bar — pick how the vegetable is cut; its yield drives the cost. */}
                    {cutOptions.length > 0 && (
                      <div className="flex flex-wrap items-center gap-1.5 pl-1 text-xs">
                        <span className="text-muted-foreground">Cut</span>
                        <button
                          type="button"
                          onClick={() => patchLine(line.key, { cut_type: null })}
                          className={cn(
                            "rounded-full border px-2 py-0.5 transition-colors",
                            !line.cut_type ? "border-primary bg-primary/10 font-medium text-primary" : "text-muted-foreground hover:bg-muted",
                          )}
                        >
                          As-is
                        </button>
                        {cutOptions.map((c) => (
                          <button
                            key={c.cut}
                            type="button"
                            onClick={() => patchLine(line.key, { cut_type: c.cut })}
                            className={cn(
                              "rounded-full border px-2 py-0.5 transition-colors",
                              line.cut_type === c.cut ? "border-primary bg-primary/10 font-medium text-primary" : "text-muted-foreground hover:bg-muted",
                            )}
                          >
                            {c.cut} <span className="opacity-60">{c.yieldPct}%</span>
                          </button>
                        ))}
                      </div>
                    )}
                    {/* §10: recipe-specific wastage override (only for ingredients with yield data) */}
                    {yieldRec && (
                      <div className="flex flex-wrap items-center gap-2 pl-1 text-xs text-muted-foreground">
                        <span>Wastage</span>
                        <Input
                          type="number"
                          step="0.1"
                          value={effWastage}
                          onChange={(e) =>
                            patchLine(line.key, {
                              wastage_override_pct: e.target.value === "" ? null : Number(e.target.value),
                            })
                          }
                          className="h-7 w-20"
                          aria-label="Recipe-specific wastage %"
                        />
                        <span>% · standard {stdWastage}%</span>
                        {hasOverride && (
                          <button
                            type="button"
                            onClick={() => patchLine(line.key, { wastage_override_pct: null })}
                            className="font-medium text-primary hover:underline"
                          >
                            Reset to standard yield
                          </button>
                        )}
                      </div>
                    )}
                    </div>
                  );
                })}
              </div>
            )}
          </Card>
        </div>

        {/* Sticky cost sidebar */}
        <div className="space-y-4">
          <CostSummary
            recipeCost={costing.totalCost}
            packagingCost={costing.packagingCost}
            sellingPrice={(watch("selling_price") || 0) > 0 ? (watch("selling_price") as number) : costing.suggestedPrice}
            isSuggested={!((watch("selling_price") || 0) > 0)}
            foodCostPct={foodCostPct}
          />
          {costing.hasMissingPrice && (
            <div className="flex items-start gap-2 rounded-md bg-amber-500/10 p-3 text-sm text-amber-700">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              Some ingredients have no price. Update them before submitting for approval.
            </div>
          )}
          <div className="flex flex-col gap-2">
            <Button variant="accent" onClick={beginSubmit} disabled={busy}>
              Submit for Approval
            </Button>
            <Button variant="outline" onClick={saveDraft} disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Save as Draft
            </Button>
            <Button
              variant="ghost"
              onClick={() => navigate(isEdit && id ? `/recipes/${id}` : "/recipes")}
              disabled={busy}
            >
              Cancel
            </Button>
          </div>
        </div>
      </div>

      <Dialog open={submitOpen} onOpenChange={setSubmitOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Submit Recipe for Approval</DialogTitle>
            <DialogDescription>
              All ingredient prices verified. Add an optional note for the reviewer.
            </DialogDescription>
          </DialogHeader>
          <Textarea
            placeholder="Notes to reviewer (optional)…"
            value={submitNote}
            onChange={(e) => setSubmitNote(e.target.value)}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setSubmitOpen(false)}>
              Cancel
            </Button>
            <Button variant="accent" onClick={confirmSubmit} disabled={submitMut.isPending}>
              {submitMut.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              Submit for Testing
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
