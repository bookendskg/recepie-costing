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
import type { RawMaterial } from "@/lib/data/types";

export function IngredientPicker({
  materials,
  value,
  onSelect,
}: {
  materials: RawMaterial[];
  value: string | null;
  onSelect: (material: RawMaterial) => void;
}) {
  const [open, setOpen] = useState(false);
  const selected = materials.find((m) => m.id === value);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          className="w-full justify-between font-normal"
        >
          <span className={cn(!selected && "text-muted-foreground")}>
            {selected ? selected.ingredient_name : "Search ingredient…"}
          </span>
          <ChevronsUpDown className="h-4 w-4 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-[--radix-popover-trigger-width] p-0">
        <Command>
          <CommandInput placeholder="Search ingredient…" />
          <CommandList>
            <CommandEmpty>No ingredient found.</CommandEmpty>
            <CommandGroup>
              {materials.map((m) => (
                <CommandItem
                  key={m.id}
                  value={m.ingredient_name}
                  onSelect={() => {
                    onSelect(m);
                    setOpen(false);
                  }}
                >
                  <Check
                    className={cn("h-4 w-4", m.id === value ? "opacity-100" : "opacity-0")}
                  />
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
