import { useMemo } from "react";
import { useNavigate } from "react-router-dom";
import { BookOpen, FileEdit, FlaskConical, CheckCircle2, Plus, Beef } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { KpiCard } from "@/components/KpiCard";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatINR } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { useRecipes } from "@/features/recipes/hooks";
import { useDashboardBrand } from "./brandTheme";

export function EditorDashboard() {
  const user = useSession((s) => s.user)!;
  const navigate = useNavigate();
  const { data: recipes = [] } = useRecipes();

  const brand = useDashboardBrand((s) => s.brand);
  const mine = useMemo(
    () =>
      recipes.filter(
        (r) => r.created_by === user.id && (brand === "all" || r.brand === brand),
      ),
    [recipes, user.id, brand],
  );
  const stats = {
    total: mine.length,
    drafts: mine.filter((r) => r.status === "draft").length,
    testing: mine.filter((r) => r.status === "testing").length,
    approved: mine.filter((r) => r.status === "approved").length,
  };

  return (
    <>
      <PageHeader
        title="My Dashboard"
        description="Your recipes at a glance"
        actions={
          <Button variant="accent" onClick={() => navigate("/recipes/new")}>
            <Plus className="h-4 w-4" /> Create Recipe
          </Button>
        }
      />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard label="My Recipes" value={stats.total} icon={BookOpen} />
        <KpiCard label="Drafts" value={stats.drafts} icon={FileEdit} />
        <KpiCard label="In Testing" value={stats.testing} icon={FlaskConical} />
        <KpiCard label="Approved" value={stats.approved} icon={CheckCircle2} />
      </div>

      <div className="mb-6 flex flex-wrap gap-2">
        <Button variant="outline" onClick={() => navigate("/recipes/new")}>
          <Plus className="h-4 w-4" /> New Recipe
        </Button>
        <Button variant="outline" onClick={() => navigate("/materials")}>
          <Beef className="h-4 w-4" /> Update Ingredient Prices
        </Button>
      </div>

      <Card>
        {mine.length === 0 ? (
          <EmptyState
            title="No recipes yet"
            description="Create your first recipe to get started."
            action={
              <Button variant="accent" onClick={() => navigate("/recipes/new")}>
                <Plus className="h-4 w-4" /> Create Recipe
              </Button>
            }
          />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Recipe</TableHead>
                <TableHead>Category</TableHead>
                <TableHead>Cost / Portion</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {mine.map((r) => (
                <TableRow
                  key={r.id}
                  className="cursor-pointer"
                  onClick={() => navigate(`/recipes/${r.id}`)}
                >
                  <TableCell className="font-medium">{r.recipe_name}</TableCell>
                  <TableCell>{r.category}</TableCell>
                  <TableCell>{formatINR(r.cost_per_portion)}</TableCell>
                  <TableCell>
                    <StatusBadge status={r.status} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Card>
    </>
  );
}
