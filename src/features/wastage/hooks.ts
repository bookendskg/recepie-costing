import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { wastageRepo, type WastageInput } from "@/lib/data";
import { useActorId } from "@/lib/hooks/useActor";

export function useWastage() {
  return useQuery({ queryKey: ["wastage"], queryFn: () => wastageRepo.list() });
}

function invalidate(qc: ReturnType<typeof useQueryClient>) {
  qc.invalidateQueries({ queryKey: ["wastage"] });
  qc.invalidateQueries({ queryKey: ["audit"] });
}

export function useCreateWastage() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: (input: WastageInput) => wastageRepo.create(input, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useUpdateWastage() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: ({ id, input }: { id: string; input: WastageInput }) => wastageRepo.update(id, input, actorId),
    onSuccess: () => invalidate(qc),
  });
}

export function useDeleteWastage() {
  const qc = useQueryClient();
  const actorId = useActorId();
  return useMutation({
    mutationFn: (id: string) => wastageRepo.remove(id, actorId),
    onSuccess: () => invalidate(qc),
  });
}
