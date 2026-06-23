import { useQuery } from "@tanstack/react-query";
import { materialsRepo, recipesRepo } from "@/lib/data";

export function useAllRecipeIngredients() {
  return useQuery({
    queryKey: ["recipes", "allIngredients"],
    queryFn: () => recipesRepo.allIngredients(),
  });
}

export function useAllCostHistory() {
  return useQuery({
    queryKey: ["recipes", "allCostHistory"],
    queryFn: () => recipesRepo.allCostHistory(),
  });
}

export function useAllPriceHistory() {
  return useQuery({
    queryKey: ["materials", "allPriceHistory"],
    queryFn: () => materialsRepo.allPriceHistory(),
  });
}
