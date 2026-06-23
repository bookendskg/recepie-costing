import { useEffect, useState } from "react";
import { Loader2, RotateCcw } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { toast } from "@/components/ui/use-toast";
import { resetDb } from "@/lib/data";
import { useAllSettings, useSetSetting } from "./hooks";

export function SettingsPage() {
  const { data: settings = [] } = useAllSettings();
  const setSetting = useSetSetting();
  const qc = useQueryClient();

  const [foodCost, setFoodCost] = useState("30");
  const [marginAlert, setMarginAlert] = useState("35");
  const [resetOpen, setResetOpen] = useState(false);

  useEffect(() => {
    const fc = settings.find((s) => s.key === "food_cost_pct")?.value;
    const ma = settings.find((s) => s.key === "margin_alert_pct")?.value;
    if (fc) setFoodCost(fc);
    if (ma) setMarginAlert(ma);
  }, [settings]);

  const save = async () => {
    const fc = Number(foodCost);
    if (!(fc > 0 && fc <= 100)) {
      toast.error("Food cost % must be between 1 and 100");
      return;
    }
    await setSetting.mutateAsync({ key: "food_cost_pct", value: String(fc) });
    await setSetting.mutateAsync({ key: "margin_alert_pct", value: String(Number(marginAlert)) });
    // Recompute downstream costing that depends on food cost %.
    qc.invalidateQueries({ queryKey: ["recipes"] });
    toast.success("Settings saved");
  };

  return (
    <>
      <PageHeader title="Settings" description="System configuration" />

      <div className="grid max-w-xl gap-6">
        <Card>
          <CardHeader>
            <CardTitle>Food Cost Configuration</CardTitle>
            <CardDescription>
              Drives the suggested selling price across all recipes.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="space-y-1.5">
              <Label>Global Food Cost %</Label>
              <Input
                type="number"
                value={foodCost}
                onChange={(e) => setFoodCost(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label>Margin Alert Threshold %</Label>
              <Input
                type="number"
                value={marginAlert}
                onChange={(e) => setMarginAlert(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Flag recipes whose food cost % exceeds this threshold.
              </p>
            </div>
            <Button variant="accent" onClick={save} disabled={setSetting.isPending}>
              {setSetting.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              Save Settings
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Demo Data</CardTitle>
            <CardDescription>
              Reset the local mock database back to the seeded sample data.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button variant="outline" onClick={() => setResetOpen(true)}>
              <RotateCcw className="h-4 w-4" /> Reset Demo Data
            </Button>
          </CardContent>
        </Card>
      </div>

      <ConfirmDialog
        open={resetOpen}
        onOpenChange={setResetOpen}
        title="Reset demo data?"
        description="All local changes will be discarded and the seed data restored."
        confirmLabel="Reset"
        destructive
        onConfirm={() => {
          resetDb();
          qc.invalidateQueries();
          toast.success("Demo data reset");
        }}
      />
    </>
  );
}
