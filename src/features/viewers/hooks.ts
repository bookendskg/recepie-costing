import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { viewsRepo } from "@/lib/data";
import type { ViewType } from "@/lib/data/types";
import { useActorId } from "@/lib/hooks/useActor";

export function useUserViews(userId: string | undefined) {
  return useQuery({
    queryKey: ["views", "user", userId],
    queryFn: () => viewsRepo.listForUser(userId!),
    enabled: !!userId,
  });
}

export function useRecipeViews(recipeId: string | undefined) {
  return useQuery({
    queryKey: ["views", "recipe", recipeId],
    queryFn: () => viewsRepo.listForRecipe(recipeId!),
    enabled: !!recipeId,
  });
}

export function useSetAccess() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({
      userId,
      recipeId,
      viewType,
    }: {
      userId: string;
      recipeId: string;
      viewType: ViewType;
    }) => viewsRepo.setAccess(userId, recipeId, viewType, actorId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["views"] }),
  });
}

export function useRemoveAccess() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ userId, recipeId }: { userId: string; recipeId: string }) =>
      viewsRepo.remove(userId, recipeId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["views"] }),
  });
}
