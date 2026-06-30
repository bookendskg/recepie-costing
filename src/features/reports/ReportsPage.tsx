import { useMemo, useState } from "react";
import { FileSpreadsheet, Loader2 } from "lucide-react";
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
import { useDashboardBrand } from "@/features/dashboard/brandTheme";
import { useRecipes } from "@/features/recipes/hooks";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useUsers } from "@/features/users/hooks";
import { useRecipeCategories, useFoodCostPct } from "@/features/settings/hooks";
import { RecipePdfButton } from "./RecipePdfButton";
import {
  useAllCostHistory,
  useAllPriceHistory,
  useAllRecipeIngredients,
} from "./hooks";
import { generateExcelReport } from "./excel";

export function ReportsPage() {
  const { data: recipes = [], isLoading: recipesLoading, isError: recipesError } = useRecipes();
  const { data: materials = [] } = useMaterials();
  const { data: users = [] } = useUsers();
  const { data: categories = [] } = useRecipeCategories();
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const ingredients = useAllRecipeIngredients();
  const costHistory = useAllCostHistory();
  const priceHistory = useAllPriceHistory();

  // Reports follow the app-wide brand toggle in the header (All / Capiche / Aiko).
  const brand = useDashboardBrand((s) => s.brand);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [category, setCategory] = useState("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [isExporting, setIsExporting] = useState(false);

  const filtered = useMemo(
    () =>
      recipes.filter((r) => {
        if (brand !== "all" && r.brand !== brand) return false;
        if (search && !r.recipe_name.toLowerCase().includes(search.toLowerCase())) return false;
        if (status !== "all" && r.status !== status) return false;
        if (category !== "all" && r.category !== category) return false;
        const date = (r.approved_at ?? r.created_at).slice(0, 10);
        if (from && date < from) return false;
        if (to && date > to) return false;
        return true;
      }),
    [recipes, brand, search, status, category, from, to],
  );
  const ingData = ingredients.data;
  const ingredientsByRecipe = useMemo(() => {
    const map = new Map<string, typeof ingData>();
    (ingData ?? []).forEach((i) => {
      const arr = map.get(i.recipe_id) ?? [];
      arr.push(i);
      map.set(i.recipe_id, arr);
    });
    return map;
  }, [ingData]);
  const brandLabel = brand === "all" ? "AllBrands" : brand === "capiche" ? "Capiche" : "Aiko";

  const exportExcel = async () => {
    setIsExporting(true);
    try {
      const ids = new Set(filtered.map((r) => r.id));
      const usedIngIds = new Set(
        (ingredients.data ?? []).filter((i) => ids.has(i.recipe_id)).map((i) => i.ingredient_id),
      );
      await generateExcelReport(
        {
          recipes: filtered,
          ingredients: (ingredients.data ?? []).filter((i) => ids.has(i.recipe_id)),
          costHistory: (costHistory.data ?? []).filter((h) => ids.has(h.recipe_id ?? "")),
          // Scope price history to ingredients used by the filtered (brand-scoped)
          // recipes so the export never mixes the other brand's price changes (§26).
          priceHistory: (priceHistory.data ?? []).filter((p) => usedIngIds.has(p.ingredient_id ?? "")),
          usersById: new Map(users.map((u) => [u.id, u])),
          materialsById: new Map(materials.map((m) => [m.id, m])),
          foodCostPct,
        },
        `${brandLabel}_${new Date().toISOString().slice(0, 10)}`,
      );
      toast.success("Excel report downloaded");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Export failed");
    } finally {
      setIsExporting(false);
    }
  };

  return (
    <>
      <PageHeader
        title="Reports"
        description="Filter recipes and export a multi-sheet Excel workbook"
        actions={
          <Button variant="accent" onClick={exportExcel} disabled={filtered.length === 0 || isExporting}>
            {isExporting ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileSpreadsheet className="h-4 w-4" />}
            {isExporting ? "Preparing…" : "Export Excel"}
          </Button>
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <div className="space-y-1.5">
            <Label>Search</Label>
            <Input
              placeholder="Search reports by recipe…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
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

      {recipesLoading ? (
        <Card>
          <div className="flex items-center justify-center gap-2 py-16 text-muted-foreground">
            <Loader2 className="h-5 w-5 animate-spin" /> Loading reports…
          </div>
        </Card>
      ) : recipesError ? (
        <Card>
          <div className="py-12 text-center text-sm text-destructive">
            Unable to load reports. Please refresh and try again.
          </div>
        </Card>
      ) : filtered.length === 0 ? (
        <Card>
          <div className="py-12 text-center text-sm text-muted-foreground">No recipes match these filters.</div>
        </Card>
      ) : (
        <Card>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Recipe</TableHead>
                <TableHead>Category</TableHead>
                <TableHead>Total Cost</TableHead>
                <TableHead>Cost / Portion</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Export</TableHead>
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
                  <TableCell className="text-right">
                    <RecipePdfButton
                      recipe={r}
                      ingredients={ingredientsByRecipe.get(r.id) ?? []}
                      foodCostPct={foodCostPct}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>
      )}
    </>
  );
}
