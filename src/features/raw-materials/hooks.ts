import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { materialsRepo, type MaterialInput } from "@/lib/data";
import { useActorId } from "@/lib/hooks/useActor";

export function useMaterials() {
  return useQuery({ queryKey: ["materials"], queryFn: () => materialsRepo.list() });
}

export function useMaterial(id: string | undefined) {
  return useQuery({
    queryKey: ["materials", id],
    queryFn: () => materialsRepo.getById(id!),
    enabled: !!id,
  });
}

export function usePriceHistory(id: string | undefined) {
  return useQuery({
    queryKey: ["materials", id, "priceHistory"],
    queryFn: () => materialsRepo.priceHistory(id!),
    enabled: !!id,
  });
}

/** Invalidate everything a price change can touch (materials + recipes + audit). */
function invalidateAll(qc: ReturnType<typeof useQueryClient>) {
  qc.invalidateQueries({ queryKey: ["materials"] });
  qc.invalidateQueries({ queryKey: ["recipes"] });
  qc.invalidateQueries({ queryKey: ["audit"] });
}

export function useCreateMaterial() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: (input: MaterialInput) => materialsRepo.create(input, actorId),
    onSuccess: () => invalidateAll(qc),
  });
}

export function useUpdateMaterial() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, input }: { id: string; input: MaterialInput }) =>
      materialsRepo.update(id, input, actorId),
    onSuccess: () => invalidateAll(qc),
  });
}

export function useSetMaterialStatus() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, status }: { id: string; status: "active" | "inactive" }) =>
      materialsRepo.setStatus(id, status, actorId),
    onSuccess: () => invalidateAll(qc),
  });
}
