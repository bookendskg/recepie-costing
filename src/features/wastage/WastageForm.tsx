import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Check, ChevronsUpDown, Loader2 } from "lucide-react";
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
import { CurrencyInput } from "@/components/ui/currency-input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { wastageSchema, type WastageValues } from "@/lib/validation/schemas";
import { useSession } from "@/lib/auth/session";
import { accessibleOutlets, userBrands } from "@/lib/auth/permissions";
import { applicableUnitCost } from "@/lib/data";
import {
  BRANDS,
  DEPARTMENTS,
  WASTAGE_TYPES,
  type Brand,
  type WastageEntry,
} from "@/lib/data/types";
import { cn, formatINR } from "@/lib/utils";
import { todayISO } from "@/lib/data/mock/db";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useRecipes } from "@/features/recipes/hooks";
import { useYields } from "@/features/yield/hooks";
import { useCreateWastage, useUpdateWastage } from "./hooks";
import { toast } from "@/components/ui/use-toast";

const SHIFTS = ["Morning", "Afternoon", "Evening", "Night"];

export function WastageForm({
  open,
  onOpenChange,
  record,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  record?: WastageEntry | null;
}) {
  const { data: materials = [] } = useMaterials();
  const { data: recipes = [] } = useRecipes();
  const { data: yields = [] } = useYields();
  const createMut = useCreateWastage();
  const updateMut = useUpdateWastage();
  const isEdit = !!record;

  const sessionUser = useSession((s) => s.user);
  // §11/§12 outlet roles can only file wastage for their permitted outlets.
  const myBrands = userBrands(sessionUser);
  const myOutlets = accessibleOutlets(sessionUser);
  const defBrand = (myBrands[0] as Brand) ?? "capiche";
  const defOutlet =
    (myOutlets.find((o) => o.brand === defBrand) ?? myOutlets[0])?.id ?? "capiche-piplod";

  const menuRecipes = recipes.filter((r) => !r.is_prep);

  const form = useForm<WastageValues>({
    resolver: zodResolver(wastageSchema),
    defaultValues: {
      wastage_date: todayISO(),
      brand: defBrand,
      outlet_id: defOutlet,
      wastage_type: "Spoilage",
      item_type: "ingredient",
      ingredient_id: null,
      recipe_id: null,
      quantity: undefined as unknown as number,
      unit: "Gram",
      unit_cost: undefined as unknown as number,
      reason: "",
      department: "Kitchen Staff",
      shift: "",
      done_by: "",
      approved_by: "",
      notes: "",
    },
  });
  const { register, handleSubmit, reset, watch, setValue, formState } = form;

  useEffect(() => {
    if (!open) return;
    reset(
      record
        ? {
            wastage_date: record.wastage_date,
            brand: record.brand,
            outlet_id: record.outlet_id,
            wastage_type: record.wastage_type,
            item_type: record.item_type,
            ingredient_id: record.ingredient_id,
            recipe_id: record.recipe_id,
            quantity: record.quantity,
            unit: record.unit,
            unit_cost: record.unit_cost,
            reason: record.reason ?? "",
            department: record.department,
            shift: record.shift ?? "",
            done_by: record.done_by ?? "",
            approved_by: record.approved_by ?? "",
            notes: record.notes ?? "",
          }
        : {
            wastage_date: todayISO(),
            brand: defBrand,
            outlet_id: defOutlet,
            wastage_type: "Spoilage",
            item_type: "ingredient",
            ingredient_id: null,
            recipe_id: null,
            quantity: undefined as unknown as number,
            unit: "Gram",
            unit_cost: undefined as unknown as number,
            reason: "",
            department: "Kitchen Staff",
            shift: "",
            done_by: "",
            approved_by: "",
            notes: "",
          },
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, record]);

  const brand = watch("brand");
  const itemType = watch("item_type");
  const quantity = watch("quantity");
  const unitCost = watch("unit_cost");
  const total = quantity > 0 && unitCost >= 0 ? quantity * unitCost : 0;

  const onBrand = (b: Brand) => {
    setValue("brand", b);
    const next = myOutlets.filter((o) => o.brand === b);
    setValue("outlet_id", next[0]?.id ?? "");
  };

  const onItemType = (t: "ingredient" | "recipe") => {
    setValue("item_type", t);
    setValue("ingredient_id", null);
    setValue("recipe_id", null);
    setValue("unit", t === "recipe" ? "Portion" : "Gram");
    setValue("unit_cost", undefined as unknown as number);
  };

  // Prefill the applicable unit cost (§13) when the item changes.
  const onPickItem = (id: string) => {
    if (itemType === "ingredient") setValue("ingredient_id", id);
    else setValue("recipe_id", id);
    const cost = applicableUnitCost(itemType, id, materials, recipes, yields);
    setValue("unit_cost", Number(cost.toFixed(2)), { shouldValidate: true });
    if (itemType === "ingredient") {
      const m = materials.find((x) => x.id === id);
      if (m) setValue("unit", m.base_unit);
    }
  };

  const onSubmit = async (values: WastageValues) => {
    const input = {
      wastage_date: values.wastage_date,
      brand: values.brand,
      outlet_id: values.outlet_id,
      wastage_type: values.wastage_type,
      item_type: values.item_type,
      ingredient_id: values.ingredient_id ?? null,
      recipe_id: values.recipe_id ?? null,
      quantity: values.quantity,
      unit: values.unit,
      unit_cost: values.unit_cost,
      reason: values.reason,
      department: values.department,
      shift: values.shift || null,
      done_by: values.done_by,
      approved_by: values.approved_by || null,
      notes: values.notes || null,
    };
    try {
      if (isEdit && record) {
        await updateMut.mutateAsync({ id: record.id, input });
        toast.success("Wastage entry updated");
      } else {
        await createMut.mutateAsync(input);
        toast.success("Wastage recorded");
      }
      onOpenChange(false);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    }
  };

  const busy = createMut.isPending || updateMut.isPending;
  const selectedItem = itemType === "ingredient" ? watch("ingredient_id") : watch("recipe_id");

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{isEdit ? "Edit Wastage Entry" : "Record Wastage"}</DialogTitle>
          <DialogDescription>Log operational wastage at an outlet.</DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <Field label="Date *" error={formState.errors.wastage_date?.message}>
              <Input type="date" {...register("wastage_date")} />
            </Field>
            <Field label="Wastage Type *">
              <Select value={watch("wastage_type")} onValueChange={(v) => setValue("wastage_type", v as WastageValues["wastage_type"])}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {WASTAGE_TYPES.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Brand *">
              <Select value={brand} onValueChange={(v) => onBrand(v as Brand)} disabled={myBrands.length <= 1}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {BRANDS.filter((b) => myBrands.includes(b.value)).map((b) => <SelectItem key={b.value} value={b.value}>{b.label}</SelectItem>)}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Outlet *" error={formState.errors.outlet_id?.message}>
              <Select value={watch("outlet_id")} onValueChange={(v) => setValue("outlet_id", v)} disabled={myOutlets.length <= 1}>
                <SelectTrigger><SelectValue placeholder="Select outlet" /></SelectTrigger>
                <SelectContent>
                  {myOutlets.filter((o) => o.brand === brand).map((o) => <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </Field>
          </div>

          <div className="rounded-md border p-3">
            <div className="mb-3 flex gap-2">
              <Button type="button" size="sm" variant={itemType === "ingredient" ? "accent" : "outline"} onClick={() => onItemType("ingredient")}>
                Ingredient
              </Button>
              <Button type="button" size="sm" variant={itemType === "recipe" ? "accent" : "outline"} onClick={() => onItemType("recipe")}>
                Recipe
              </Button>
            </div>
            <Field
              label={itemType === "ingredient" ? "Ingredient *" : "Recipe *"}
              error={formState.errors.ingredient_id?.message || formState.errors.recipe_id?.message}
            >
              <ItemCombobox
                items={
                  itemType === "ingredient"
                    ? materials.map((m) => ({ id: m.id, label: m.ingredient_name }))
                    : menuRecipes.map((r) => ({
                        id: r.id,
                        label: r.size_label ? `${r.recipe_name} (${r.size_label})` : r.recipe_name,
                      }))
                }
                value={selectedItem ?? null}
                onChange={onPickItem}
                placeholder={`Search ${itemType}…`}
              />
            </Field>
            <div className="mt-3 grid grid-cols-3 gap-3">
              <Field label="Quantity *" error={formState.errors.quantity?.message}>
                <Input type="number" step="0.001" {...register("quantity", { valueAsNumber: true })} />
              </Field>
              <Field label="Unit">
                <Input {...register("unit")} readOnly tabIndex={-1} className="bg-muted text-muted-foreground" />
              </Field>
              <Field label="Unit Cost (₹) *" error={formState.errors.unit_cost?.message}>
                <CurrencyInput value={unitCost ?? undefined} onChange={(v) => setValue("unit_cost", v as number, { shouldValidate: true })} />
              </Field>
            </div>
            <div className="mt-3 flex items-center justify-between rounded-md bg-muted px-3 py-2 text-sm">
              <span className="text-muted-foreground">Total Wastage Cost</span>
              <span className="font-semibold">{formatINR(total)}</span>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <Field label="Department *">
              <Select value={watch("department")} onValueChange={(v) => setValue("department", v as WastageValues["department"])}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {DEPARTMENTS.map((d) => <SelectItem key={d} value={d}>{d}</SelectItem>)}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Shift">
              <Select value={watch("shift") || ""} onValueChange={(v) => setValue("shift", v)}>
                <SelectTrigger><SelectValue placeholder="Optional" /></SelectTrigger>
                <SelectContent>
                  {SHIFTS.map((s) => <SelectItem key={s} value={s}>{s}</SelectItem>)}
                </SelectContent>
              </Select>
            </Field>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <Field label="Reason *" error={formState.errors.reason?.message}>
              <Input {...register("reason")} placeholder="e.g. Spoiled / burnt / expired" />
            </Field>
            <Field label="Wastage Done By *" error={formState.errors.done_by?.message}>
              <Input {...register("done_by")} placeholder="Staff member name" />
            </Field>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Approved By">
              <Input {...register("approved_by")} placeholder="Manager name (optional)" />
            </Field>
          </div>
          <Field label="Notes">
            <Textarea rows={2} {...register("notes")} placeholder="Optional" />
          </Field>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
            <Button type="submit" variant="accent" disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />}
              {isEdit ? "Save Changes" : "Record Wastage"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, error, children }: { label: string; error?: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <Label>{label}</Label>
      {children}
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

/** Searchable single-select for picking the wasted ingredient/recipe. */
function ItemCombobox({
  items,
  value,
  onChange,
  placeholder,
}: {
  items: { id: string; label: string }[];
  value: string | null;
  onChange: (id: string) => void;
  placeholder: string;
}) {
  const [open, setOpen] = useState(false);
  const selected = items.find((i) => i.id === value);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" role="combobox" className="w-full justify-between font-normal">
          <span className={cn("truncate", !selected && "text-muted-foreground")}>
            {selected ? selected.label : placeholder}
          </span>
          <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[--radix-popover-trigger-width] p-0" align="start">
        <Command>
          <CommandInput placeholder="Search…" />
          <CommandList>
            <CommandEmpty>No match found.</CommandEmpty>
            <CommandGroup>
              {items.map((i) => (
                <CommandItem
                  key={i.id}
                  value={i.label}
                  onSelect={() => {
                    onChange(i.id);
                    setOpen(false);
                  }}
                >
                  <Check className={cn("mr-2 h-4 w-4", value === i.id ? "opacity-100" : "opacity-0")} />
                  {i.label}
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
