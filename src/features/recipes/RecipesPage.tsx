import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Copy, MoreVertical, Plus, Pencil } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
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
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { formatINR } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { can, canEditRecipe } from "@/lib/auth/permissions";
import { toast } from "@/components/ui/use-toast";
import { useCategories } from "@/features/settings/hooks";
import { useDuplicateRecipe, useRecipes } from "./hooks";

export function RecipesPage() {
  const user = useSession((s) => s.user)!;
  const navigate = useNavigate();
  const { data: recipes = [], isLoading } = useRecipes();
  const { data: categories = [] } = useCategories();
  const dupMut = useDuplicateRecipe();

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [status, setStatus] = useState("all");
  const [sort, setSort] = useState("newest");

  const canCreate = can(user.role, "recipe.create");

  const filtered = useMemo(() => {
    let list = recipes.filter((r) => {
      if (search && !r.recipe_name.toLowerCase().includes(search.toLowerCase())) return false;
      if (category !== "all" && r.category !== category) return false;
      if (status !== "all" && r.status !== status) return false;
      return true;
    });
    list = list.sort((a, b) => {
      if (sort === "name") return a.recipe_name.localeCompare(b.recipe_name);
      if (sort === "cost") return (b.cost_per_portion ?? 0) - (a.cost_per_portion ?? 0);
      return b.created_at.localeCompare(a.created_at);
    });
    return list;
  }, [recipes, search, category, status, sort]);

  const duplicate = async (id: string) => {
    try {
      const copy = await dupMut.mutateAsync(id);
      toast.success("Recipe duplicated");
      navigate(`/recipes/${copy.id}/edit`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Duplicate failed");
    }
  };

  return (
    <>
      <PageHeader
        title="Recipes"
        description="Browse and manage recipes"
        actions={
          canCreate && (
            <Button variant="accent" onClick={() => navigate("/recipes/new")}>
              <Plus className="h-4 w-4" /> Create Recipe
            </Button>
          )
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Input
            placeholder="Search recipes…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <Select value={category} onValueChange={setCategory}>
            <SelectTrigger>
              <SelectValue placeholder="Category" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Categories</SelectItem>
              {categories.map((c) => (
                <SelectItem key={c} value={c}>
                  {c}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select value={status} onValueChange={setStatus}>
            <SelectTrigger>
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Statuses</SelectItem>
              <SelectItem value="draft">Draft</SelectItem>
              <SelectItem value="testing">Testing</SelectItem>
              <SelectItem value="approved">Approved</SelectItem>
              <SelectItem value="rejected">Rejected</SelectItem>
            </SelectContent>
          </Select>
          <Select value={sort} onValueChange={setSort}>
            <SelectTrigger>
              <SelectValue placeholder="Sort" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="newest">Newest</SelectItem>
              <SelectItem value="name">Name (A–Z)</SelectItem>
              <SelectItem value="cost">Cost / Portion</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </Card>

      <Card>
        {isLoading ? (
          <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>
        ) : filtered.length === 0 ? (
          <EmptyState
            title="No recipes found"
            description={canCreate ? "Create your first recipe to get started." : "No recipes match your filters."}
            action={
              canCreate && (
                <Button variant="accent" onClick={() => navigate("/recipes/new")}>
                  <Plus className="h-4 w-4" /> Create Recipe
                </Button>
              )
            }
          />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Recipe Name</TableHead>
                <TableHead>Category</TableHead>
                <TableHead>Portions</TableHead>
                <TableHead>Cost / Portion</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((r) => (
                <TableRow
                  key={r.id}
                  className="cursor-pointer"
                  onClick={() => navigate(`/recipes/${r.id}`)}
                >
                  <TableCell className="font-medium">{r.recipe_name}</TableCell>
                  <TableCell>{r.category}</TableCell>
                  <TableCell>{r.serving_size}</TableCell>
                  <TableCell>{formatINR(r.cost_per_portion)}</TableCell>
                  <TableCell>
                    <StatusBadge status={r.status} />
                  </TableCell>
                  <TableCell onClick={(e) => e.stopPropagation()}>
                    {(canEditRecipe(user, r) || can(user.role, "recipe.duplicate")) && (
                      <DropdownMenu>
                        <DropdownMenuTrigger asChild>
                          <Button variant="ghost" size="icon">
                            <MoreVertical className="h-4 w-4" />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end">
                          {canEditRecipe(user, r) && (
                            <DropdownMenuItem onClick={() => navigate(`/recipes/${r.id}/edit`)}>
                              <Pencil className="h-4 w-4" /> Edit
                            </DropdownMenuItem>
                          )}
                          {can(user.role, "recipe.duplicate") && (
                            <DropdownMenuItem onClick={() => duplicate(r.id)}>
                              <Copy className="h-4 w-4" /> Duplicate
                            </DropdownMenuItem>
                          )}
                        </DropdownMenuContent>
                      </DropdownMenu>
                    )}
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
