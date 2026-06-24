import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { settingsRepo } from "@/lib/data";
import { useActorId } from "@/lib/hooks/useActor";

const DEFAULT_CATEGORIES = [
  "Vegetables", "Protein", "Dairy", "Grains & Flour", "Oils & Fats",
  "Spices", "Sauces & Condiments", "Beverages", "Bakery", "Dry Fruits",
];

export function useCategories() {
  return useQuery({
    queryKey: ["settings", "categories"],
    queryFn: async () => {
      const raw = await settingsRepo.get("ingredient_categories");
      if (!raw) return DEFAULT_CATEGORIES;
      try {
        return JSON.parse(raw) as string[];
      } catch {
        return DEFAULT_CATEGORIES;
      }
    },
  });
}

const DEFAULT_RECIPE_CATEGORIES = [
  "Pasta", "Pizza", "Sushi", "Mains", "Appetizers", "Small Plates",
  "Sides", "Salad", "Dessert", "Beverage", "In-House Prep",
];

export function useRecipeCategories() {
  return useQuery({
    queryKey: ["settings", "recipe_categories"],
    queryFn: async () => {
      const raw = await settingsRepo.get("recipe_categories");
      if (!raw) return DEFAULT_RECIPE_CATEGORIES;
      try {
        return JSON.parse(raw) as string[];
      } catch {
        return DEFAULT_RECIPE_CATEGORIES;
      }
    },
  });
}

export function useFoodCostPct() {
  return useQuery({
    queryKey: ["settings", "food_cost_pct"],
    queryFn: () => settingsRepo.foodCostPct(),
  });
}

export function useAllSettings() {
  return useQuery({ queryKey: ["settings", "all"], queryFn: () => settingsRepo.getAll() });
}

export function useSetSetting() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ key, value }: { key: string; value: string }) =>
      settingsRepo.set(key, value, actorId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["settings"] }),
  });
}
