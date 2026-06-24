import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  recipesRepo,
  type RecipeHeaderInput,
  type RecipeLineInput,
} from "@/lib/data";
import { useActorId } from "@/lib/hooks/useActor";

export function useRecipes() {
  return useQuery({ queryKey: ["recipes"], queryFn: () => recipesRepo.list() });
}

export function useRecipe(id: string | undefined) {
  return useQuery({
    queryKey: ["recipes", id, "full"],
    queryFn: () => recipesRepo.getWithIngredients(id!),
    enabled: !!id,
  });
}

export function useRecipeCostHistory(id: string | undefined) {
  return useQuery({
    queryKey: ["recipes", id, "costHistory"],
    queryFn: () => recipesRepo.costHistory(id!),
    enabled: !!id,
  });
}

export function useRecipeVersions(id: string | undefined) {
  return useQuery({
    queryKey: ["recipes", id, "versions"],
    queryFn: () => recipesRepo.versions(id!),
    enabled: !!id,
  });
}

function invalidate(qc: ReturnType<typeof useQueryClient>) {
  qc.invalidateQueries({ queryKey: ["recipes"] });
  qc.invalidateQueries({ queryKey: ["audit"] });
}

export function useCreateRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ header, lines }: { header: RecipeHeaderInput; lines: RecipeLineInput[] }) =>
      recipesRepo.create(header, lines, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useUpdateRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({
      id,
      header,
      lines,
    }: {
      id: string;
      header: RecipeHeaderInput;
      lines: RecipeLineInput[];
    }) => recipesRepo.update(id, header, lines, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useDuplicateRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: (id: string) => recipesRepo.duplicate(id, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useSetRecipeImage() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, imageUrl }: { id: string; imageUrl: string | null }) =>
      recipesRepo.setImage(id, imageUrl, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useSetSellingPrice() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, price }: { id: string; price: number | null }) =>
      recipesRepo.setSellingPrice(id, price, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useSubmitRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, note }: { id: string; note: string | null }) =>
      recipesRepo.submit(id, note, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useApproveRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: (id: string) => recipesRepo.approve(id, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useRejectRecipe() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, note }: { id: string; note: string }) =>
      recipesRepo.reject(id, note, actorId),
    onSuccess: () => invalidate(qc),
  });
}
