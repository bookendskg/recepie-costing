import { useMemo } from "react";
import {
  BookOpen,
  CheckCircle2,
  FileEdit,
  Beef,
  AlertTriangle,
  Clock,
} from "lucide-react";
import {
  Bar,
  BarChart,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { PageHeader } from "@/components/PageHeader";
import { KpiCard } from "@/components/KpiCard";
import { Card } from "@/components/ui/card";
import { formatDateTime, formatINR } from "@/lib/utils";
import { useRecipes } from "@/features/recipes/hooks";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useAuditLogs } from "@/features/audit/hooks";

const DONUT_COLORS = ["#4f46e5", "#0ea5e9", "#16a34a", "#f59e0b", "#ef4444", "#8b5cf6", "#ec4899", "#14b8a6", "#f97316", "#64748b"];

export function AdminDashboard() {
  const { data: recipes = [] } = useRecipes();
  const { data: materials = [] } = useMaterials();
  const { data: audit = [] } = useAuditLogs();

  const stats = useMemo(() => {
    const thisMonth = new Date().toISOString().slice(0, 7);
    return {
      total: recipes.length,
      approvedThisMonth: recipes.filter(
        (r) => r.status === "approved" && (r.approved_at ?? "").startsWith(thisMonth),
      ).length,
      drafts: recipes.filter((r) => r.status === "draft").length,
      activeIngredients: materials.filter((m) => m.status === "active").length,
      missingPrice: materials.filter((m) => m.purchase_price === null).length,
      pending: recipes.filter((r) => r.status === "testing").length,
    };
  }, [recipes, materials]);

  const topExpensive = useMemo(
    () =>
      [...recipes]
        .sort((a, b) => (b.cost_per_portion ?? 0) - (a.cost_per_portion ?? 0))
        .slice(0, 5)
        .map((r) => ({ name: r.recipe_name, cost: r.cost_per_portion ?? 0 })),
    [recipes],
  );

  const byCategory = useMemo(() => {
    const map = new Map<string, number>();
    recipes.forEach((r) => map.set(r.category, (map.get(r.category) ?? 0) + 1));
    return [...map.entries()].map(([name, value]) => ({ name, value }));
  }, [recipes]);

  return (
    <>
      <PageHeader title="Admin Dashboard" description="Overview of recipes, costs, and approvals" />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
        <KpiCard label="Total Recipes" value={stats.total} icon={BookOpen} />
        <KpiCard label="Approved (Month)" value={stats.approvedThisMonth} icon={CheckCircle2} />
        <KpiCard label="Draft Recipes" value={stats.drafts} icon={FileEdit} />
        <KpiCard label="Active Ingredients" value={stats.activeIngredients} icon={Beef} />
        <KpiCard
          label="Missing Price"
          value={stats.missingPrice}
          icon={AlertTriangle}
          alert={stats.missingPrice > 0}
        />
        <KpiCard label="Pending Approvals" value={stats.pending} icon={Clock} alert={stats.pending > 0} />
      </div>

      <div className="mb-6 grid gap-4 lg:grid-cols-2">
        <Card className="p-5">
          <p className="mb-4 text-sm font-semibold">Top 5 Expensive Recipes</p>
          {topExpensive.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted-foreground">No data</p>
          ) : (
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={topExpensive} layout="vertical" margin={{ left: 20 }}>
                <XAxis type="number" tickFormatter={(v) => `₹${v}`} fontSize={12} />
                <YAxis type="category" dataKey="name" width={120} fontSize={12} />
                <Tooltip formatter={(v: number) => formatINR(v)} />
                <Bar dataKey="cost" fill="#4f46e5" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          )}
        </Card>

        <Card className="p-5">
          <p className="mb-4 text-sm font-semibold">Recipes by Category</p>
          {byCategory.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted-foreground">No data</p>
          ) : (
            <ResponsiveContainer width="100%" height={240}>
              <PieChart>
                <Pie data={byCategory} dataKey="value" nameKey="name" innerRadius={50} outerRadius={90}>
                  {byCategory.map((_, i) => (
                    <Cell key={i} fill={DONUT_COLORS[i % DONUT_COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip />
              </PieChart>
            </ResponsiveContainer>
          )}
        </Card>
      </div>

      <Card className="p-5">
        <p className="mb-3 text-sm font-semibold">Recent Activity</p>
        {audit.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted-foreground">No activity yet.</p>
        ) : (
          <ul className="divide-y">
            {audit.slice(0, 10).map((a) => (
              <li key={a.id} className="flex items-center justify-between py-2 text-sm">
                <span>{a.notes ?? `${a.action} ${a.entity_type}`}</span>
                <span className="text-muted-foreground">{formatDateTime(a.performed_at)}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </>
  );
}
