import { useMemo, useState } from "react";
import { FileSpreadsheet } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { StatusBadge } from "@/components/StatusBadge";
import { formatINR } from "@/lib/utils";
import { toast } from "@/components/ui/use-toast";
import { useRecipes } from "@/features/recipes/hooks";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useUsers } from "@/features/users/hooks";
import { useCategories, useFoodCostPct } from "@/features/settings/hooks";
import {
  useAllCostHistory,
  useAllPriceHistory,
  useAllRecipeIngredients,
} from "./hooks";
import { generateExcelReport } from "./excel";

export function ReportsPage() {
  const { data: recipes = [] } = useRecipes();
  const { data: materials = [] } = useMaterials();
  const { data: users = [] } = useUsers();
  const { data: categories = [] } = useCategories();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const ingredients = useAllRecipeIngredients();
  const costHistory = useAllCostHistory();
  const priceHistory = useAllPriceHistory();

  const [status, setStatus] = useState("all");
  const [category, setCategory] = useState("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");

  const filtered = useMemo(
    () =>
      recipes.filter((r) => {
        if (status !== "all" && r.status !== status) return false;
        if (category !== "all" && r.category !== category) return false;
        const date = (r.approved_at ?? r.created_at).slice(0, 10);
        if (from && date < from) return false;
        if (to && date > to) return false;
        return true;
      }),
    [recipes, status, category, from, to],
  );

  const exportExcel = async () => {
    try {
      const ids = new Set(filtered.map((r) => r.id));
      await generateExcelReport(
        {
          recipes: filtered,
          ingredients: (ingredients.data ?? []).filter((i) => ids.has(i.recipe_id)),
          costHistory: (costHistory.data ?? []).filter((h) => ids.has(h.recipe_id ?? "")),
          priceHistory: priceHistory.data ?? [],
          usersById: new Map(users.map((u) => [u.id, u])),
          materialsById: new Map(materials.map((m) => [m.id, m])),
          foodCostPct,
        },
        new Date().toISOString().slice(0, 10),
      );
      toast.success("Excel report downloaded");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Export failed");
    }
  };

  return (
    <>
      <PageHeader
        title="Reports"
        description="Filter recipes and export a multi-sheet Excel workbook"
        actions={
          <Button variant="accent" onClick={exportExcel} disabled={filtered.length === 0}>
            <FileSpreadsheet className="h-4 w-4" /> Export Excel
          </Button>
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="space-y-1.5">
            <Label>Status</Label>
            <Select value={status} onValueChange={setStatus}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All</SelectItem>
                <SelectItem value="draft">Draft</SelectItem>
                <SelectItem value="testing">Testing</SelectItem>
                <SelectItem value="approved">Approved</SelectItem>
                <SelectItem value="rejected">Rejected</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>Category</Label>
            <Select value={category} onValueChange={setCategory}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All</SelectItem>
                {categories.map((c) => (
                  <SelectItem key={c} value={c}>
                    {c}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>From</Label>
            <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label>To</Label>
            <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
          </div>
        </div>
      </Card>

      <Card>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Recipe</TableHead>
              <TableHead>Category</TableHead>
              <TableHead>Total Cost</TableHead>
              <TableHead>Cost / Portion</TableHead>
              <TableHead>Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filtered.map((r) => (
              <TableRow key={r.id}>
                <TableCell className="font-medium">{r.recipe_name}</TableCell>
                <TableCell>{r.category}</TableCell>
                <TableCell>{formatINR(r.total_cost)}</TableCell>
                <TableCell>{formatINR(r.cost_per_portion)}</TableCell>
                <TableCell>
                  <StatusBadge status={r.status} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Card>
    </>
  );
}
