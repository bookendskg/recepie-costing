import { useMemo, useState } from "react";
import { ResponsiveContainer, BarChart, Bar, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid } from "recharts";
import { MoreVertical, Plus, Trash2, Trash, CalendarDays, Coins, Store, Percent, ChefHat } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { TableSkeleton } from "@/components/TableSkeleton";
import { Pagination } from "@/components/Pagination";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
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
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { formatINR, formatDate } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { can } from "@/lib/auth/permissions";
import { BRANDS, OUTLETS, WASTAGE_TYPES, outletById, type Brand, type WastageEntry } from "@/lib/data/types";
import { useMaterials } from "@/features/raw-materials/hooks";
import { useRecipes } from "@/features/recipes/hooks";
import { useWastage, useDeleteWastage } from "./hooks";
import { WastageForm } from "./WastageForm";
import { toast } from "@/components/ui/use-toast";

const PAGE_SIZE = 10;

export function WastagePage() {
  const user = useSession((s) => s.user)!;
  const canEdit = can(user.role, "wastage.create");
  const { data: entries = [], isLoading } = useWastage();
  const { data: materials = [] } = useMaterials();
  const { data: recipes = [] } = useRecipes();
  const deleteMut = useDeleteWastage();

  const matById = useMemo(() => new Map(materials.map((m) => [m.id, m.ingredient_name])), [materials]);
  const recById = useMemo(() => new Map(recipes.map((r) => [r.id, r.recipe_name])), [recipes]);
  const itemName = (w: WastageEntry) =>
    w.item_type === "recipe" ? recById.get(w.recipe_id ?? "") ?? "—" : matById.get(w.ingredient_id ?? "") ?? "—";

  const [search, setSearch] = useState("");
  const [brand, setBrand] = useState("all");
  const [outlet, setOutlet] = useState("all");
  const [type, setType] = useState("all");
  const [page, setPage] = useState(1);

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<WastageEntry | null>(null);
  const [deleting, setDeleting] = useState<WastageEntry | null>(null);

  const filtered = useMemo(() => {
    return entries.filter((w) => {
      if (brand !== "all" && w.brand !== brand) return false;
      if (outlet !== "all" && w.outlet_id !== outlet) return false;
      if (type !== "all" && w.wastage_type !== type) return false;
      if (search) {
        const hay = `${itemName(w)} ${w.reason ?? ""}`.toLowerCase();
        if (!hay.includes(search.toLowerCase())) return false;
      }
      return true;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, brand, outlet, type, search, matById, recById]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const current = Math.min(page, pageCount);
  const pageItems = filtered.slice((current - 1) * PAGE_SIZE, current * PAGE_SIZE);

  // Summary + reports (§14)
  const stats = useMemo(() => {
    const today = new Date().toISOString().slice(0, 10);
    const month = today.slice(0, 7);
    const todayCost = entries.filter((w) => w.wastage_date === today).reduce((s, w) => s + w.total_cost, 0);
    const monthCost = entries.filter((w) => w.wastage_date.slice(0, 7) === month).reduce((s, w) => s + w.total_cost, 0);
    const totalCost = entries.reduce((s, w) => s + w.total_cost, 0);
    const byOutletMap = new Map<string, number>();
    const byTypeMap = new Map<string, number>();
    const byBrandMap = new Map<string, number>();
    const byReasonMap = new Map<string, number>();
    const byDayMap = new Map<string, number>();
    const recipeMap = new Map<string, number>();
    const ingredientMap = new Map<string, number>();
    for (const w of entries) {
      byOutletMap.set(w.outlet_id, (byOutletMap.get(w.outlet_id) ?? 0) + w.total_cost);
      byTypeMap.set(w.wastage_type, (byTypeMap.get(w.wastage_type) ?? 0) + w.total_cost);
      byBrandMap.set(w.brand, (byBrandMap.get(w.brand) ?? 0) + w.total_cost);
      const reason = w.reason || "Unspecified";
      byReasonMap.set(reason, (byReasonMap.get(reason) ?? 0) + w.total_cost);
      byDayMap.set(w.wastage_date, (byDayMap.get(w.wastage_date) ?? 0) + w.total_cost);
      const key = itemName(w);
      (w.item_type === "recipe" ? recipeMap : ingredientMap).set(key, ((w.item_type === "recipe" ? recipeMap : ingredientMap).get(key) ?? 0) + w.total_cost);
    }
    const top = (m: Map<string, number>) => [...m.entries()].sort((a, b) => b[1] - a[1])[0];
    const toData = (m: Map<string, number>, fmt: (k: string) => string = (k) => k) =>
      [...m.entries()].map(([name, cost]) => ({ name: fmt(name), cost: Math.round(cost) })).sort((a, b) => b.cost - a.cost).slice(0, 6);
    // Daily trend — last 30 days.
    const daily: { date: string; cost: number }[] = [];
    for (let i = 29; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86_400_000).toISOString().slice(0, 10);
      daily.push({ date: d.slice(5), cost: Math.round(byDayMap.get(d) ?? 0) });
    }
    const inventoryValue = materials.filter((m) => m.status === "active").reduce((s, m) => s + (m.purchase_price ?? 0), 0);
    const topItem = top(ingredientMap);
    const topRecipe = top(recipeMap);
    return {
      todayCost,
      monthCost,
      totalCost,
      topOutlet: top(byOutletMap) ? outletById(top(byOutletMap)[0])?.name ?? "—" : "—",
      topItem: topItem ? topItem[0] : "—",
      topRecipe: topRecipe ? topRecipe[0] : "—",
      pctOfInventory: inventoryValue > 0 ? (totalCost / inventoryValue) * 100 : 0,
      byOutlet: OUTLETS.map((o) => ({ name: o.name.replace(/^(Capiche|Aiko) /, ""), cost: Math.round(byOutletMap.get(o.id) ?? 0) })),
      byType: toData(byTypeMap, (k) => k.replace(" Wastage", "")),
      byBrand: BRANDS.map((b) => ({ name: b.label, cost: Math.round(byBrandMap.get(b.value) ?? 0) })),
      byReason: toData(byReasonMap),
      topItems: toData(ingredientMap),
      daily,
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entries, materials, matById, recById]);

  const resetPage = () => setPage(1);

  return (
    <>
      <PageHeader
        title="Wastage Management"
        description="Record and analyse operational wastage across all outlets."
        actions={
          canEdit && (
            <Button variant="accent" onClick={() => { setEditing(null); setFormOpen(true); }}>
              <Plus className="h-4 w-4" /> Record Wastage
            </Button>
          )
        }
      />

      {/* Summary cards (§14) */}
      <div className="mb-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat icon={<CalendarDays className="h-4 w-4" />} label="Today's Wastage" value={formatINR(stats.todayCost)} />
        <Stat icon={<Coins className="h-4 w-4" />} label="This Month" value={formatINR(stats.monthCost)} />
        <Stat icon={<Coins className="h-4 w-4" />} label="All-Time Cost" value={formatINR(stats.totalCost)} />
        <Stat icon={<Percent className="h-4 w-4 text-amber-500" />} label="Vs Inventory Value" value={`${stats.pctOfInventory.toFixed(1)}%`} />
        <Stat icon={<Store className="h-4 w-4" />} label="Top Outlet" value={stats.topOutlet} small />
        <Stat icon={<Trash className="h-4 w-4 text-amber-500" />} label="Top Ingredient" value={stats.topItem} small />
        <Stat icon={<ChefHat className="h-4 w-4" />} label="Top Recipe" value={stats.topRecipe} small />
        <Stat icon={<Trash className="h-4 w-4" />} label="Entries" value={String(entries.length)} />
      </div>

      {/* Reports (§14) */}
      <Card className="mb-4 p-4">
        <p className="mb-3 text-sm font-semibold">Daily Wastage Trend (last 30 days)</p>
        <ResponsiveContainer width="100%" height={200}>
          <LineChart data={stats.daily} margin={{ top: 4, right: 12, left: -12, bottom: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false} />
            <XAxis dataKey="date" tick={{ fontSize: 10 }} interval={4} />
            <YAxis tick={{ fontSize: 11 }} />
            <Tooltip formatter={(v: number) => formatINR(v)} labelFormatter={(l) => `Day ${l}`} />
            <Line type="monotone" dataKey="cost" stroke="hsl(var(--primary))" strokeWidth={2} dot={false} />
          </LineChart>
        </ResponsiveContainer>
      </Card>
      <div className="mb-4 grid gap-4 lg:grid-cols-2 xl:grid-cols-3">
        <Breakdown title="By Outlet" data={stats.byOutlet} />
        <Breakdown title="By Wastage Type" data={stats.byType} />
        <Breakdown title="By Brand" data={stats.byBrand} />
        <Breakdown title="By Reason" data={stats.byReason} />
        <Breakdown title="Top Wasted Ingredients" data={stats.topItems} />
      </div>

      {/* Filters */}
      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Input placeholder="Search item / reason…" value={search} onChange={(e) => { setSearch(e.target.value); resetPage(); }} />
          <Select value={brand} onValueChange={(v) => { setBrand(v); setOutlet("all"); resetPage(); }}>
            <SelectTrigger><SelectValue placeholder="Brand" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Brands</SelectItem>
              {BRANDS.map((b) => <SelectItem key={b.value} value={b.value}>{b.label}</SelectItem>)}
            </SelectContent>
          </Select>
          <Select value={outlet} onValueChange={(v) => { setOutlet(v); resetPage(); }}>
            <SelectTrigger><SelectValue placeholder="Outlet" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Outlets</SelectItem>
              {OUTLETS.filter((o) => brand === "all" || o.brand === (brand as Brand)).map((o) => (
                <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select value={type} onValueChange={(v) => { setType(v); resetPage(); }}>
            <SelectTrigger><SelectValue placeholder="Type" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Types</SelectItem>
              {WASTAGE_TYPES.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      </Card>

      <Card>
        {isLoading ? (
          <TableSkeleton rows={6} cols={6} />
        ) : filtered.length === 0 ? (
          <EmptyState
            icon={<Trash className="h-7 w-7" />}
            title="No wastage recorded"
            description="Record operational wastage to track spoilage, overproduction and losses by outlet."
            action={canEdit && <Button variant="accent" onClick={() => { setEditing(null); setFormOpen(true); }}><Plus className="h-4 w-4" /> Record Wastage</Button>}
          />
        ) : (
          <>
            <div className="hidden md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Date</TableHead>
                    <TableHead>Outlet</TableHead>
                    <TableHead>Type</TableHead>
                    <TableHead>Item</TableHead>
                    <TableHead className="text-right">Qty</TableHead>
                    <TableHead className="text-right">Total</TableHead>
                    <TableHead>Dept</TableHead>
                    <TableHead>Done By</TableHead>
                    <TableHead className="w-10" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pageItems.map((w) => (
                    <TableRow key={w.id}>
                      <TableCell className="whitespace-nowrap text-sm">{formatDate(w.wastage_date)}</TableCell>
                      <TableCell className="text-sm">{outletById(w.outlet_id)?.name ?? w.outlet_id}</TableCell>
                      <TableCell><Badge variant="outline">{w.wastage_type.replace(" Wastage", "")}</Badge></TableCell>
                      <TableCell className="font-medium">{itemName(w)}</TableCell>
                      <TableCell className="text-right font-mono">{w.quantity} {w.unit}</TableCell>
                      <TableCell className="text-right font-mono font-semibold">{formatINR(w.total_cost)}</TableCell>
                      <TableCell className="text-sm text-muted-foreground">{w.department}</TableCell>
                      <TableCell className="text-sm text-muted-foreground">{w.done_by ?? "—"}</TableCell>
                      <TableCell>{canEdit && <RowActions onEdit={() => { setEditing(w); setFormOpen(true); }} onDelete={() => setDeleting(w)} />}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            <ul className="divide-y md:hidden">
              {pageItems.map((w) => (
                <li key={w.id} className="flex items-start gap-3 p-4">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-medium">{itemName(w)}</p>
                    <p className="text-xs text-muted-foreground">{outletById(w.outlet_id)?.name} · {formatDate(w.wastage_date)}</p>
                    <p className="mt-1 text-sm"><Badge variant="outline" className="mr-2">{w.wastage_type.replace(" Wastage", "")}</Badge>{w.quantity} {w.unit} · <span className="font-semibold">{formatINR(w.total_cost)}</span></p>
                  </div>
                  {canEdit && <RowActions onEdit={() => { setEditing(w); setFormOpen(true); }} onDelete={() => setDeleting(w)} />}
                </li>
              ))}
            </ul>

            <Pagination page={current} pageSize={PAGE_SIZE} total={filtered.length} onPageChange={setPage} label="entries" />
          </>
        )}
      </Card>

      <WastageForm open={formOpen} onOpenChange={setFormOpen} record={editing} />
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => !o && setDeleting(null)}
        title="Delete wastage entry?"
        description="This wastage record will be permanently removed."
        confirmLabel="Delete"
        destructive
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await deleteMut.mutateAsync(deleting.id);
            toast.success("Wastage entry deleted");
          } catch (e) {
            toast.error(e instanceof Error ? e.message : "Delete failed");
          }
        }}
      />
    </>
  );
}

function Stat({ icon, label, value, small }: { icon: React.ReactNode; label: string; value: string; small?: boolean }) {
  return (
    <Card className="p-4">
      <div className="mb-1 flex items-center gap-2 text-sm text-muted-foreground">{icon}{label}</div>
      <div className={small ? "truncate text-base font-semibold" : "text-2xl font-bold"}>{value}</div>
    </Card>
  );
}

function Breakdown({ title, data }: { title: string; data: { name: string; cost: number }[] }) {
  const hasData = data.some((d) => d.cost > 0);
  return (
    <Card className="p-4">
      <p className="mb-3 text-sm font-semibold">{title}</p>
      {!hasData ? (
        <p className="flex h-[180px] items-center justify-center text-sm text-muted-foreground">No data.</p>
      ) : (
        <ResponsiveContainer width="100%" height={180}>
          <BarChart data={data} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
            <XAxis dataKey="name" tick={{ fontSize: 10 }} interval={0} angle={-15} textAnchor="end" height={42} />
            <YAxis tick={{ fontSize: 11 }} />
            <Tooltip formatter={(v: number) => formatINR(v)} cursor={{ fill: "hsl(var(--muted))" }} />
            <Bar dataKey="cost" fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
          </BarChart>
        </ResponsiveContainer>
      )}
    </Card>
  );
}

function RowActions({ onEdit, onDelete }: { onEdit: () => void; onDelete: () => void }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="Wastage entry actions">
          <MoreVertical className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem onClick={onEdit}>Edit</DropdownMenuItem>
        <DropdownMenuItem onClick={onDelete} className="text-destructive">
          <Trash2 className="h-4 w-4" /> Delete
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
