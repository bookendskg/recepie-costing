import { useQuery } from "@tanstack/react-query";
import { auditRepo, type AuditFilter } from "@/lib/data";

export function useAuditLogs(filter: AuditFilter = {}) {
  return useQuery({
    queryKey: ["audit", filter],
    queryFn: () => auditRepo.list(filter),
  });
}
