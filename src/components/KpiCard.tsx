import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { Card } from "@/components/ui/card";

export function KpiCard({
  label,
  value,
  icon: Icon,
  alert,
}: {
  label: string;
  value: string | number;
  icon?: LucideIcon;
  alert?: boolean;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">{label}</p>
        {Icon && (
          <Icon className={cn("h-4 w-4", alert ? "text-amber-500" : "text-muted-foreground")} />
        )}
      </div>
      <p className={cn("mt-2 text-2xl font-semibold", alert && "text-amber-600")}>{value}</p>
    </Card>
  );
}
