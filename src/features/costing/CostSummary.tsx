import { formatINR } from "@/lib/utils";
import type { ViewVisibility } from "@/lib/auth/permissions";

interface CostSummaryProps {
  totalCost: number;
  costPerPortion: number;
  suggestedPrice: number;
  grossProfit: number;
  grossMarginPct: number;
  foodCostPct: number;
  servingSize: number;
  /** Optional view-mode gate (viewers). Omitted = show everything. */
  visibility?: ViewVisibility;
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex items-center justify-between py-1 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className={strong ? "text-base font-semibold" : "font-medium"}>{value}</span>
    </div>
  );
}

export function CostSummary(props: CostSummaryProps) {
  const v = props.visibility;
  const showCost = v ? v.totalCost : true;
  const showPortion = v ? v.costPerPortion : true;
  const showPrice = v ? v.sellingPrice : true;
  const showProfit = v ? v.grossProfit : true;

  if (!showCost && !showPortion && !showPrice && !showProfit) {
    return (
      <div className="rounded-lg border bg-muted/40 p-4 text-sm text-muted-foreground">
        Costing details are hidden for this view.
      </div>
    );
  }

  return (
    <div className="rounded-lg border bg-muted/40 p-4">
      <p className="mb-2 text-sm font-semibold">Cost Summary</p>
      {showCost && <Row label="Total Recipe Cost" value={formatINR(props.totalCost)} />}
      {showPortion && (
        <Row
          label={`Cost Per Portion (÷${props.servingSize})`}
          value={formatINR(props.costPerPortion)}
        />
      )}
      {showPrice && (
        <Row
          label={`Suggested Selling Price (${props.foodCostPct}% food cost)`}
          value={formatINR(props.suggestedPrice)}
          strong
        />
      )}
      {showProfit && (
        <>
          <Row label="Gross Profit" value={formatINR(props.grossProfit)} />
          <Row label="Gross Margin" value={`${props.grossMarginPct}%`} />
        </>
      )}
    </div>
  );
}
