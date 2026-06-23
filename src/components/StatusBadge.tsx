import { Badge } from "@/components/ui/badge";
import type { RecipeStatus } from "@/lib/data/types";

const map: Record<RecipeStatus, { label: string; variant: "success" | "warning" | "info" | "danger" }> = {
  draft: { label: "Draft", variant: "warning" },
  testing: { label: "Testing", variant: "info" },
  approved: { label: "Approved", variant: "success" },
  rejected: { label: "Rejected", variant: "danger" },
};

export function StatusBadge({ status }: { status: RecipeStatus }) {
  const cfg = map[status];
  return <Badge variant={cfg.variant}>{cfg.label}</Badge>;
}
