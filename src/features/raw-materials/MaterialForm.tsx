import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Loader2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { materialSchema, type MaterialValues } from "@/lib/validation/schemas";
import { BASE_UNITS, PURCHASE_UNITS, canConvert } from "@/lib/units";
import { calculateCostPerBaseUnit } from "@/lib/costing";
import { formatINR } from "@/lib/utils";
import type { RawMaterial } from "@/lib/data/types";
import { useCreateMaterial, useUpdateMaterial } from "./hooks";
import { useCategories } from "@/features/settings/hooks";
import { toast } from "@/components/ui/use-toast";

export function MaterialForm({
  open,
  onOpenChange,
  material,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  material?: RawMaterial | null;
}) {
  const { data: categories = [] } = useCategories();
  const createMut = useCreateMaterial();
  const updateMut = useUpdateMaterial();
  const isEdit = !!material;

  const form = useForm<MaterialValues>({
    resolver: zodResolver(materialSchema),
    defaultValues: {
      ingredient_name: "",
      category: "",
      supplier_name: "",
      purchase_price: undefined as unknown as number,
      purchase_quantity: undefined as unknown as number,
      purchase_unit: "KG",
      base_unit: "Gram",
    },
  });

  const { register, handleSubmit, reset, watch, setValue, formState } = form;

  useEffect(() => {
    if (open) {
      reset(
        material
          ? {
              ingredient_name: material.ingredient_name,
              category: material.category,
              supplier_name: material.supplier_name ?? "",
              purchase_price: material.purchase_price ?? (undefined as unknown as number),
              purchase_quantity: material.purchase_quantity,
              purchase_unit: material.purchase_unit as MaterialValues["purchase_unit"],
              base_unit: material.base_unit as MaterialValues["base_unit"],
            }
          : {
              ingredient_name: "",
              category: categories[0] ?? "",
              supplier_name: "",
              purchase_price: undefined as unknown as number,
              purchase_quantity: undefined as unknown as number,
              purchase_unit: "KG",
              base_unit: "Gram",
            },
      );
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, material]);

  const price = watch("purchase_price");
  const qty = watch("purchase_quantity");
  const pUnit = watch("purchase_unit");
  const bUnit = watch("base_unit");

  let preview: number | null = null;
  if (price > 0 && qty > 0 && canConvert(pUnit, bUnit)) {
    preview = calculateCostPerBaseUnit(price, qty, pUnit, bUnit);
  }

  const onSubmit = async (values: MaterialValues) => {
    const input = { ...values, supplier_name: values.supplier_name || null };
    try {
      if (isEdit && material) {
        await updateMut.mutateAsync({ id: material.id, input });
        toast.success("Ingredient updated");
      } else {
        await createMut.mutateAsync(input);
        toast.success("Ingredient added");
      }
      onOpenChange(false);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    }
  };

  const busy = createMut.isPending || updateMut.isPending;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{isEdit ? "Edit Ingredient" : "Add Ingredient"}</DialogTitle>
          <DialogDescription>
            Cost per base unit is calculated automatically from the purchase details.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div className="space-y-1.5">
            <Label>Ingredient Name *</Label>
            <Input {...register("ingredient_name")} />
            {formState.errors.ingredient_name && (
              <p className="text-xs text-destructive">
                {formState.errors.ingredient_name.message}
              </p>
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
              <Label>Supplier Name</Label>
              <Input {...register("supplier_name")} />
            </div>
          </div>

          <div className="rounded-md border p-3">
            <p className="mb-3 text-sm font-medium">Pricing</p>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label>Purchase Price (₹) *</Label>
                <Input
                  type="number"
                  step="0.01"
                  {...register("purchase_price", { valueAsNumber: true })}
                />
                {formState.errors.purchase_price && (
                  <p className="text-xs text-destructive">
                    {formState.errors.purchase_price.message}
                  </p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Purchase Quantity *</Label>
                <Input
                  type="number"
                  step="0.001"
                  {...register("purchase_quantity", { valueAsNumber: true })}
                />
                {formState.errors.purchase_quantity && (
                  <p className="text-xs text-destructive">
                    {formState.errors.purchase_quantity.message}
                  </p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Purchase Unit *</Label>
                <Select
                  value={pUnit}
                  onValueChange={(v) => setValue("purchase_unit", v as MaterialValues["purchase_unit"])}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {PURCHASE_UNITS.map((u) => (
                      <SelectItem key={u} value={u}>
                        {u}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-1.5">
                <Label>Base Unit *</Label>
                <Select
                  value={bUnit}
                  onValueChange={(v) => setValue("base_unit", v as MaterialValues["base_unit"])}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {BASE_UNITS.map((u) => (
                      <SelectItem key={u} value={u}>
                        {u}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {formState.errors.base_unit && (
                  <p className="text-xs text-destructive">{formState.errors.base_unit.message}</p>
                )}
              </div>
            </div>
          </div>

          <div className="flex items-center justify-between rounded-md bg-muted px-3 py-2 text-sm">
            <span className="text-muted-foreground">Cost Per Base Unit</span>
            <span className="font-semibold">
              {preview !== null ? `${formatINR(preview)} / ${bUnit}` : "—"}
            </span>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" variant="accent" disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />}
              {isEdit ? "Save Changes" : "Save Ingredient"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
