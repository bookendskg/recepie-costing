import { useMemo, useState } from "react";
import { CheckCircle2, FileDown, Send } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn, formatINR } from "@/lib/utils";
import { toast } from "@/components/ui/use-toast";

type AreaKey = "dry" | "walkin" | "prep";

interface StockItem {
  id: string;
  name: string;
  area: AreaKey;
  unit: string;
  theo: number;
  unitPrice: number;
  reorder: number;
  physical: number; // 0 = not yet counted
}

const AREAS: { key: AreaKey; label: string }[] = [
  { key: "dry", label: "Dry Store" },
  { key: "walkin", label: "Walk-in Chiller" },
  { key: "prep", label: "Prep Kitchen" },
];

const SEED: StockItem[] = [
  { id: "s1", name: "Basmati Rice (Extra Long)", area: "dry", unit: "KG", theo: 45, unitPrice: 86.5, reorder: 50, physical: 44.5 },
  { id: "s2", name: "Whole Cumin Seeds", area: "dry", unit: "KG", theo: 12, unitPrice: 100, reorder: 8, physical: 12.1 },
  { id: "s3", name: "Fresh Heavy Cream (35%)", area: "walkin", unit: "LITER", theo: 24, unitPrice: 120, reorder: 15, physical: 0 },
  { id: "s4", name: "Boneless Chicken Thigh", area: "walkin", unit: "KG", theo: 150, unitPrice: 260, reorder: 100, physical: 148 },
  { id: "s5", name: "Clarified Butter (Ghee)", area: "prep", unit: "KG", theo: 8.5, unitPrice: 700, reorder: 5, physical: 8.5 },
  { id: "s6", name: "Makhani Base Sauce", area: "prep", unit: "LITER", theo: 60, unitPrice: 200, reorder: 30, physical: 55 },
];

type Status = "pending" | "matched" | "low" | "stable" | "critical";

function statusOf(item: StockItem): { status: Status; variance: number; variancePct: number } {
  const variance = +(item.physical - item.theo).toFixed(2);
  const variancePct = item.theo > 0 ? (variance / item.theo) * 100 : 0;
  let status: Status;
  if (item.physical === 0) status = "pending";
  else if (variancePct <= -5) status = "critical";
  else if (variance === 0) status = "matched";
  else if (item.physical < item.reorder) status = "low";
  else status = "stable";
  return { status, variance, variancePct };
}

const STATUS_BADGE: Record<Exclude<Status, "critical">, { label: string; cls: string }> = {
  pending: { label: "Pending", cls: "bg-violet-100 text-violet-700" },
  matched: { label: "Matched", cls: "bg-emerald-100 text-emerald-700" },
  low: { label: "Low Stock", cls: "border border-red-300 text-red-600" },
  stable: { label: "Stable", cls: "border border-slate-300 text-slate-600" },
};

export function InventoryPage() {
  const [items, setItems] = useState<StockItem[]>(SEED);
  const [tab, setTab] = useState<AreaKey | "all">("all");

  const setPhysical = (id: string, value: number) =>
    setItems((prev) => prev.map((it) => (it.id === id ? { ...it, physical: value } : it)));

  const visible = tab === "all" ? items : items.filter((i) => i.area === tab);

  const grouped = useMemo(() => {
    return AREAS.map((a) => ({ ...a, rows: visible.filter((i) => i.area === a.key) })).filter(
      (g) => g.rows.length > 0,
    );
  }, [visible]);

  const totals = useMemo(() => {
    const theoVal = items.reduce((s, i) => s + i.theo * i.unitPrice, 0);
    const physVal = items.reduce((s, i) => s + i.physical * i.unitPrice, 0);
    const loss = physVal - theoVal;
    const lossPct = theoVal > 0 ? (loss / theoVal) * 100 : 0;
    return { theoVal, physVal, loss, lossPct };
  }, [items]);

  const counts = {
    all: items.length,
    dry: items.filter((i) => i.area === "dry").length,
    walkin: items.filter((i) => i.area === "walkin").length,
    prep: items.filter((i) => i.area === "prep").length,
  };

  return (
    <div className="flex min-h-[calc(100vh-7rem)] flex-col">
      <PageHeader
        title="Physical Stock Count"
        description="Last saved: 12 Oct 2023, 08:45 AM • Counting Session #SC-9821"
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={() => toast.success("Stock list exported")}>
              <FileDown className="h-4 w-4" /> Export List
            </Button>
            <Button
              className="bg-emerald-800 text-white hover:bg-emerald-900"
              onClick={() => toast.success("Count finalized")}
            >
              <CheckCircle2 className="h-4 w-4" /> Finalize Count
            </Button>
          </div>
        }
      />

      {/* Area tabs */}
      <div className="mb-4 flex flex-wrap items-center gap-6 border-b">
        {[
          { key: "all" as const, label: "All Areas", n: counts.all },
          { key: "dry" as const, label: "Dry Store", n: counts.dry },
          { key: "walkin" as const, label: "Walk-in", n: counts.walkin },
          { key: "prep" as const, label: "Prep Kitchen", n: counts.prep },
        ].map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              "flex items-center gap-2 border-b-2 pb-2 text-sm font-medium uppercase tracking-wide transition-colors",
              tab === t.key
                ? "border-emerald-700 text-emerald-800"
                : "border-transparent text-muted-foreground hover:text-foreground",
            )}
          >
            {t.label}
            <span className="rounded-full bg-muted px-2 py-0.5 text-xs">{t.n}</span>
          </button>
        ))}
      </div>

      {/* Table */}
      <Card className="flex-1 overflow-hidden">
        <div className="grid grid-cols-12 gap-2 border-b bg-muted/40 px-4 py-3 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
          <div className="col-span-3">Item Name</div>
          <div className="col-span-1">Unit</div>
          <div className="col-span-2 text-right">Theo. Stock</div>
          <div className="col-span-2 text-center">Physical Count</div>
          <div className="col-span-1 text-right">Variance</div>
          <div className="col-span-2 text-right">Value (₹)</div>
          <div className="col-span-1 text-center">Status</div>
        </div>

        {grouped.map((g) => (
          <div key={g.key}>
            <div className="bg-muted/20 px-4 py-2 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
              {g.label}
            </div>
            {g.rows.map((item) => {
              const { status, variance, variancePct } = statusOf(item);
              const value = item.physical * item.unitPrice;
              return (
                <div key={item.id} className="grid grid-cols-12 items-center gap-2 border-b px-4 py-3 text-sm last:border-0">
                  <div className="col-span-3 font-medium">{item.name}</div>
                  <div className="col-span-1 text-muted-foreground">{item.unit}</div>
                  <div className="col-span-2 text-right font-mono">{item.theo.toFixed(2)}</div>
                  <div className="col-span-2 flex justify-center">
                    <Input
                      type="number"
                      step="0.01"
                      value={item.physical}
                      onChange={(e) => setPhysical(item.id, Number(e.target.value))}
                      className="w-24 text-center font-mono"
                    />
                  </div>
                  <div
                    className={cn(
                      "col-span-1 text-right font-mono",
                      status === "pending"
                        ? "text-muted-foreground"
                        : variance < 0
                          ? "text-red-600"
                          : variance > 0
                            ? "text-emerald-600"
                            : "text-muted-foreground",
                    )}
                  >
                    {status === "pending" ? "—" : `${variance > 0 ? "+" : ""}${variance.toFixed(2)}`}
                  </div>
                  <div className="col-span-2 text-right font-mono">
                    {formatINR(value).replace("₹", "")}
                  </div>
                  <div className="col-span-1 flex justify-center">
                    {status === "critical" ? (
                      <div className="h-1.5 w-16 overflow-hidden rounded-full bg-muted" title={`${variancePct.toFixed(1)}% loss`}>
                        <div className="h-full rounded-full bg-amber-700" style={{ width: `${Math.min(100, Math.abs(variancePct) * 6)}%` }} />
                      </div>
                    ) : (
                      <span className={cn("rounded px-2 py-0.5 text-[10px] font-bold uppercase", STATUS_BADGE[status].cls)}>
                        {STATUS_BADGE[status].label}
                      </span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        ))}
      </Card>

      {/* Bottom posting bar */}
      <div className="mt-4 flex flex-col items-stretch gap-4 rounded-lg border bg-background p-4 lg:flex-row lg:items-center">
        <Summary label="Total Theoretical Value" value={formatINR(totals.theoVal)} />
        <Summary label="Actual Physical Value" value={formatINR(totals.physVal)} valueClass="text-emerald-700" />
        <Summary
          label="Variance Loss"
          value={`-${formatINR(Math.abs(totals.loss))} (${Math.abs(totals.lossPct).toFixed(1)}%)`}
          valueClass="text-red-600"
        />
        <div className="flex flex-1 items-center justify-end gap-4">
          <div className="text-right text-sm">
            <p className="font-semibold">Ready to post?</p>
            <p className="text-xs text-muted-foreground">Updates ERP &amp; GL accounts</p>
          </div>
          <Button
            size="lg"
            className="bg-emerald-800 text-white hover:bg-emerald-900"
            onClick={() => toast.success("Stock posted & finalized", "ERP and GL accounts updated.")}
          >
            Post &amp; Finalize Stock <Send className="h-4 w-4" />
          </Button>
        </div>
      </div>
    </div>
  );
}

function Summary({ label, value, valueClass }: { label: string; value: string; valueClass?: string }) {
  return (
    <div className="lg:pr-6">
      <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={cn("text-xl font-bold", valueClass)}>{value}</p>
    </div>
  );
}
