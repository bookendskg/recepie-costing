import { useMemo } from "react";
import { useNavigate } from "react-router-dom";
import { BookOpen, LayoutGrid, UtensilsCrossed, ArrowRight } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { viewerCanAccess } from "@/lib/auth/permissions";
import { useRecipes } from "@/features/recipes/hooks";
import { brandWordmark, brandAccentText } from "./brandTheme";
import type { BrandSelection } from "./BrandFilter";

/**
 * Plain overview dashboard for viewers and anyone without Master Costing access —
 * no making/packaging/selling/FC% figures. Shows what the user is allowed to
 * browse (dish counts + categories) across the selected brand(s) and links into
 * the recipe catalogue.
 */
export function SimpleDashboard({ brand }: { brand: BrandSelection }) {
  const navigate = useNavigate();
  const user = useSession((s) => s.user);
  const { data: recipes = [], isLoading } = useRecipes();

  const data = useMemo(() => {
    const visible = recipes.filter((r) => {
      if (r.is_prep || r.parent_recipe_id) return false;
      if (brand !== "all" && r.brand !== brand) return false;
      // Viewers only see approved recipes in their permitted brands; other roles
      // without dashboard access can still browse the full catalogue.
      if (user?.role === "viewer") return viewerCanAccess(user, r);
      return true;
    });
    const categories = new Map<string, number>();
    for (const r of visible) {
      const c = r.category || "Uncategorised";
      categories.set(c, (categories.get(c) ?? 0) + 1);
    }
    return {
      total: visible.length,
      categories: [...categories.entries()].sort((a, b) => a[0].localeCompare(b[0])),
    };
  }, [recipes, brand, user]);

  const accent = brandAccentText(brand);
  const firstName = user?.name?.split(" ")[0] ?? "there";

  return (
    <div className="space-y-4">
      {/* Welcome banner */}
      <Card className="overflow-hidden border-0 bg-slate-900 text-white dark:bg-slate-950">
        <div className="flex flex-col gap-3 p-5 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-4">
            <div className={cn("rounded-md bg-white/10 px-4 py-2 text-xl font-extrabold tracking-wide", accent)}>
              {brandWordmark[brand]}
            </div>
            <div>
              <p className="text-base font-bold sm:text-lg">Welcome back, {firstName}</p>
              <p className="text-xs text-slate-300">Browse the {brandWordmark[brand]} recipe catalogue</p>
            </div>
          </div>
          <Button variant="secondary" onClick={() => navigate("/recipes")} className="shrink-0">
            <BookOpen className="h-4 w-4" /> Browse Recipes <ArrowRight className="h-4 w-4" />
          </Button>
        </div>
      </Card>

      {/* Non-sensitive KPIs */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat icon={<UtensilsCrossed className="h-4 w-4" />} label="Dishes" value={isLoading ? "—" : String(data.total)} accent={accent} />
        <Stat icon={<LayoutGrid className="h-4 w-4" />} label="Categories" value={isLoading ? "—" : String(data.categories.length)} accent={accent} />
        <Stat icon={<BookOpen className="h-4 w-4" />} label="Brand" value={brandWordmark[brand]} accent={accent} />
      </div>

      {/* Category overview (counts only — no costs) */}
      <Card className="overflow-hidden">
        <p className="border-b bg-muted/60 px-4 py-2 text-sm font-semibold">Menu Categories</p>
        {isLoading ? (
          <p className="p-4 text-sm text-muted-foreground">Loading…</p>
        ) : data.categories.length === 0 ? (
          <p className="p-6 text-center text-sm text-muted-foreground">
            No recipes available to you yet.
          </p>
        ) : (
          <ul className="divide-y">
            {data.categories.map(([name, count]) => (
              <li
                key={name}
                onClick={() => navigate("/recipes")}
                className="flex cursor-pointer items-center justify-between px-4 py-2.5 text-sm hover:bg-muted/50"
              >
                <span className="font-medium">{name}</span>
                <span className="font-mono text-muted-foreground">{count} {count === 1 ? "dish" : "dishes"}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

function Stat({ icon, label, value, accent }: { icon: React.ReactNode; label: string; value: string; accent?: string }) {
  return (
    <Card className="p-4">
      <div className="flex items-center gap-1.5 text-[11px] uppercase tracking-wide text-muted-foreground">
        {icon} {label}
      </div>
      <p className={cn("mt-1 text-2xl font-bold", accent)}>{value}</p>
    </Card>
  );
}
