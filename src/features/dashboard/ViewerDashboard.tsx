import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Search } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useSession } from "@/lib/auth/session";
import { useRecipes } from "@/features/recipes/hooks";
import { useUserViews } from "@/features/viewers/hooks";

export function ViewerDashboard() {
  const user = useSession((s) => s.user)!;
  const navigate = useNavigate();
  const { data: recipes = [] } = useRecipes();
  const { data: views = [] } = useUserViews(user.id);

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");

  // Only approved recipes assigned to this viewer (PRD §14, §9.3).
  const assignedIds = useMemo(() => new Set(views.map((v) => v.recipe_id)), [views]);
  const accessible = useMemo(
    () => recipes.filter((r) => r.status === "approved" && assignedIds.has(r.id)),
    [recipes, assignedIds],
  );
  const categories = useMemo(
    () => [...new Set(accessible.map((r) => r.category))],
    [accessible],
  );

  const filtered = accessible.filter((r) => {
    if (search && !r.recipe_name.toLowerCase().includes(search.toLowerCase())) return false;
    if (category !== "all" && r.category !== category) return false;
    return true;
  });

  return (
    <>
      <PageHeader title="Recipes" description="Browse the recipes shared with you" />

      <Card className="mb-6 p-4">
        <div className="grid gap-3 sm:grid-cols-[1fr_200px]">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              className="pl-9"
              placeholder="Search recipes…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
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
        </div>
      </Card>

      {filtered.length === 0 ? (
        <EmptyState
          title="No recipes available"
          description="Recipes shared with you will appear here once an admin assigns access."
        />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((r) => (
            <Card
              key={r.id}
              className="cursor-pointer transition-shadow hover:shadow-md"
              onClick={() => navigate(`/recipes/${r.id}`)}
            >
              <CardHeader>
                <CardTitle className="text-base">{r.recipe_name}</CardTitle>
                <div className="flex items-center gap-2">
                  <Badge variant="secondary">{r.category}</Badge>
                  <span className="text-xs text-muted-foreground">{r.serving_size} portions</span>
                </div>
              </CardHeader>
              {r.description && (
                <CardContent>
                  <p className="line-clamp-2 text-sm text-muted-foreground">{r.description}</p>
                </CardContent>
              )}
            </Card>
          ))}
        </div>
      )}
    </>
  );
}
