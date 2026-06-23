import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
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
import { calculateIngredientCost } from "@/lib/costing";
import { formatINR } from "@/lib/utils";
import { toast } from "@/components/ui/use-toast";
import type { RawMaterial } from "@/lib/data/types";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useFoodCostPct, useCategories } from "@/features/settings/hooks";
import { useRecipeCosting, type EditorLine } from "@/features/costing/useRecipeCosting";
import { CostSummary } from "@/features/costing/CostSummary";
import { IngredientPicker } from "./IngredientPicker";
import { useCreateRecipe, useRecipe, useSubmitRecipe, useUpdateRecipe } from "./hooks";

interface GridLine extends EditorLine {
  key: string;
}

let keyCounter = 0;
const newKey = () => `line-${keyCounter++}`;

export function RecipeEditorPage() {
  const { id } = useParams();
  const isEdit = !!id;
  const navigate = useNavigate();

  const { data: materials = [] } = useMaterials();
  const { data: categories = [] } = useCategories();
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

  const [lines, setLines] = useState<GridLine[]>([]);
  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitNote, setSubmitNote] = useState("");
  const [pendingRecipeId, setPendingRecipeId] = useState<string | null>(null);

  const form = useForm<RecipeHeaderValues>({
    resolver: zodResolver(recipeHeaderSchema),
    defaultValues: {
      recipe_name: "",
      category: "",
      description: "",
      preparation_time: null,
      serving_size: 1,
    },
  });
  const { register, handleSubmit, reset, watch, setValue, formState } = form;

  // Hydrate when editing.
  useEffect(() => {
    if (isEdit && existing) {
      reset({
        recipe_name: existing.recipe.recipe_name,
        category: existing.recipe.category,
        description: existing.recipe.description ?? "",
        preparation_time: existing.recipe.preparation_time,
        serving_size: existing.recipe.serving_size,
      });
      setLines(
        existing.ingredients.map((i) => ({
          key: newKey(),
          ingredient_id: i.ingredient_id,
          quantity_used: i.quantity_used,
          unit_used: i.unit_used,
        })),
      );
    } else if (!isEdit) {
      setValue("category", categories[0] ?? "");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isEdit, existing, categories.length]);

  const servingSize = watch("serving_size") || 1;
  const costing = useRecipeCosting(
    lines.map((l) => ({ ingredient_id: l.ingredient_id, quantity_used: l.quantity_used, unit_used: l.unit_used })),
    materialsById,
    servingSize,
    foodCostPct,
  );

  const addLine = () =>
    setLines((prev) => [...prev, { key: newKey(), ingredient_id: "", quantity_used: 0, unit_used: "" }]);
  const removeLine = (key: string) => setLines((prev) => prev.filter((l) => l.key !== key));
  const patchLine = (key: string, patch: Partial<GridLine>) =>
    setLines((prev) => prev.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const selectMaterial = (key: string, m: RawMaterial) =>
    patchLine(key, { ingredient_id: m.id, unit_used: m.base_unit });

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
      quantity_used: l.quantity_used,
      unit_used: l.unit_used,
    }));
  };

  const saveDraft = handleSubmit(async (header) => {
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
  const beginSubmit = handleSubmit(async (header) => {
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
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label>Prep (min)</Label>
                  <Input
                    type="number"
                    {...register("preparation_time", {
                      setValueAs: (v) => (v === "" || v === null ? null : Number(v)),
                    })}
                  />
                </div>
                <div className="space-y-1.5">
                  <Label>Serving Size *</Label>
                  <Input type="number" {...register("serving_size", { valueAsNumber: true })} />
                  {formState.errors.serving_size && (
                    <p className="text-xs text-destructive">
                      {formState.errors.serving_size.message}
                    </p>
                  )}
                </div>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>Description</Label>
              <Textarea rows={2} {...register("description")} />
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
                  const material = materialsById.get(line.ingredient_id) ?? null;
                  const units = material ? compatibleUnits(material.base_unit) : [];
                  const lineCost =
                    material &&
                    material.cost_per_base_unit !== null &&
                    line.quantity_used > 0 &&
                    canConvert(line.unit_used, material.base_unit)
                      ? calculateIngredientCost(
                          material.cost_per_base_unit,
                          line.quantity_used,
                          line.unit_used,
                          material.base_unit,
                        )
                      : null;
                  return (
                    <div key={line.key} className="grid grid-cols-12 items-center gap-2">
                      <div className="col-span-12 sm:col-span-5">
                        <IngredientPicker
                          materials={activeMaterials}
                          value={line.ingredient_id || null}
                          onSelect={(m) => selectMaterial(line.key, m)}
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
                          disabled={!material}
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
                  );
                })}
              </div>
            )}
          </Card>
        </div>

        {/* Sticky cost sidebar */}
        <div className="space-y-4">
          <CostSummary
            totalCost={costing.totalCost}
            costPerPortion={costing.costPerPortion}
            suggestedPrice={costing.suggestedPrice}
            grossProfit={costing.grossProfit}
            grossMarginPct={costing.grossMarginPct}
            foodCostPct={foodCostPct}
            servingSize={servingSize}
          />
          {costing.hasMissingPrice && (
            <div className="flex items-start gap-2 rounded-md bg-amber-500/10 p-3 text-sm text-amber-700">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              Some ingredients have no price. Update them before submitting for approval.
            </div>
          )}
          <div className="flex flex-col gap-2">
            <Button variant="outline" onClick={saveDraft} disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Save as Draft
            </Button>
            <Button variant="accent" onClick={beginSubmit} disabled={busy}>
              Submit for Approval
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
