import { useState } from "react";
import { Check, ChevronsUpDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import type { RawMaterial, Recipe } from "@/lib/data/types";

export type ComponentPick =
  | { type: "material"; material: RawMaterial }
  | { type: "recipe"; recipe: Recipe };

export function IngredientPicker({
  materials,
  preps,
  value,
  onSelect,
}: {
  materials: RawMaterial[];
  preps: Recipe[];
  value: string | null;
  onSelect: (pick: ComponentPick) => void;
}) {
  const [open, setOpen] = useState(false);
  const selectedMat = materials.find((m) => m.id === value);
  const selectedPrep = preps.find((p) => p.id === value);
  const label = selectedMat?.ingredient_name ?? selectedPrep?.recipe_name ?? null;

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" role="combobox" className="w-full justify-between font-normal">
          <span className={cn(!label && "text-muted-foreground")}>
            {label ?? "Search ingredient or prep…"}
          </span>
          <ChevronsUpDown className="h-4 w-4 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[--radix-popover-trigger-width] p-0">
        <Command>
          <CommandInput placeholder="Search ingredient or prep…" />
          <CommandList>
            <CommandEmpty>No match found.</CommandEmpty>
            {preps.length > 0 && (
              <CommandGroup heading="In-House Prep">
                {preps.map((p) => (
                  <CommandItem
                    key={p.id}
                    value={`prep ${p.recipe_name}`}
                    onSelect={() => {
                      onSelect({ type: "recipe", recipe: p });
                      setOpen(false);
                    }}
                  >
                    <Check className={cn("h-4 w-4", p.id === value ? "opacity-100" : "opacity-0")} />
                    <span className="flex-1">{p.recipe_name}</span>
                    <span className="text-xs text-emerald-700">Prep</span>
                  </CommandItem>
                ))}
              </CommandGroup>
            )}
            <CommandGroup heading="Ingredients">
              {materials.map((m) => (
                <CommandItem
                  key={m.id}
                  value={m.ingredient_name}
                  onSelect={() => {
                    onSelect({ type: "material", material: m });
                    setOpen(false);
                  }}
                >
                  <Check className={cn("h-4 w-4", m.id === value ? "opacity-100" : "opacity-0")} />
                  <span className="flex-1">{m.ingredient_name}</span>
                  <span className="text-xs text-muted-foreground">{m.base_unit}</span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
