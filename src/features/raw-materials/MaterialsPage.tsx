import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  ArrowDown,
  ArrowUp,
  ArrowUpDown,
  Columns3,
  Download,
  MoreVertical,
  Plus,
  RotateCcw,
  Trash2,
  Upload,
} from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { PageHeader } from "@/components/PageHeader";
import { ImportDialog } from "@/components/ImportDialog";
import { materialsRepo, type MaterialInput } from "@/lib/data";
import { PURCHASE_UNITS, BASE_UNITS } from "@/lib/units";
import { pick, toNum, toText, type ImportConfig } from "@/lib/import/importTypes";
import { EmptyState } from "@/components/EmptyState";
import { TableSkeleton } from "@/components/TableSkeleton";
import { Pagination } from "@/components/Pagination";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
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
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { cn, formatINR, formatQuantityWithUnit } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { can } from "@/lib/auth/permissions";
import type { RawMaterial } from "@/lib/data/types";
import { useMaterials, useSetMaterialStatus, useBulkSetMaterialStatus } from "./hooks";
import { useCategories } from "@/features/settings/hooks";
import { MaterialForm } from "./MaterialForm";
import { PriceHistoryDialog } from "./PriceHistoryDialog";
import { exportMaterials } from "./exportMaterials";
import { toast } from "@/components/ui/use-toast";

type SortKey = "name" | "category" | "price";

const PAGE_SIZE = 10;

const COLUMN_DEFS = [
  { key: "category", label: "Category" },
  { key: "supplier", label: "Supplier" },
  { key: "price", label: "Purchase Price" },
  { key: "packSize", label: "Quantity" },
] as const;
type ColKey = (typeof COLUMN_DEFS)[number]["key"];

export function MaterialsPage() {
  const user = useSession((s) => s.user)!;
  const canEdit = can(user.role, "material.edit"); // admin-only — ingredients locked otherwise
  const { data: materials = [], isLoading } = useMaterials();
  const { data: categories = [] } = useCategories();
  const setStatus = useSetMaterialStatus();
  const bulkStatus = useBulkSetMaterialStatus();
  const queryClient = useQueryClient();
  const [importOpen, setImportOpen] = useState(false);

  const importConfig = useMemo<ImportConfig<MaterialInput>>(() => ({
    title: "Import Ingredients",
    columns: [
      { label: "Ingredient", required: true },
      { label: "Category" },
      { label: "Supplier" },
      { label: "Purchase Price" },
      { label: "Purchase Quantity" },
      { label: "Purchase Unit" },
      { label: "Base Unit" },
      { label: "Notes" },
    ],
    sample: {
      Ingredient: "Onion",
      Category: "Vegetables",
      Supplier: "",
      "Purchase Price": 2400,
      "Purchase Quantity": 20,
      "Purchase Unit": "KG",
      "Base Unit": "Gram",
      Notes: "",
    },
    parseRow: (row, n) => {
      const name = toText(pick(row, ["Ingredient", "Ingredient Name", "Name"]));
      if (!name) return { error: `Row ${n}: ingredient name is required` };
      const price = toNum(pick(row, ["Purchase Price", "Purchase Price (₹)", "Price"]));
      if (price !== null && (Number.isNaN(price) || price < 0)) return { error: `Row ${n}: invalid purchase price` };
      const qtyRaw = toNum(pick(row, ["Purchase Quantity", "Pack Size", "Quantity"]));
      const qty = qtyRaw == null || Number.isNaN(qtyRaw) ? 1 : qtyRaw;
      if (qty <= 0) return { error: `Row ${n}: purchase quantity must be greater than 0` };
      const purchaseUnit = toText(pick(row, ["Purchase Unit", "Unit"])) || "KG";
      if (!(PURCHASE_UNITS as readonly string[]).includes(purchaseUnit)) return { error: `Row ${n}: unknown purchase unit "${purchaseUnit}"` };
      const baseUnit = toText(pick(row, ["Base Unit"])) || "Gram";
      if (!(BASE_UNITS as readonly string[]).includes(baseUnit)) return { error: `Row ${n}: unknown base unit "${baseUnit}"` };
      return {
        value: {
          ingredient_name: name,
          category: toText(pick(row, ["Category"])) || "Other",
          supplier_name: toText(pick(row, ["Supplier", "Supplier Name"])) || null,
          notes: toText(pick(row, ["Notes"])) || null,
          purchase_price: price,
          purchase_quantity: qty,
          purchase_unit: purchaseUnit,
          base_unit: baseUnit,
        },
      };
    },
    run: async (mode, rows) => {
      const summary = await materialsRepo.importMaterials(mode, rows, user.id);
      await queryClient.invalidateQueries({ queryKey: ["materials"] });
      await queryClient.invalidateQueries({ queryKey: ["recipes"] });
      return summary;
    },
  }), [queryClient, user.id]);

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [status, setStatus_] = useState("active");
  const [sort, setSort] = useState<{ key: SortKey; dir: "asc" | "desc" }>({ key: "name", dir: "asc" });

  const pageSize = PAGE_SIZE;
  const [page, setPage] = useState(1);

  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [cols, setCols] = useState<Record<ColKey, boolean>>({
    category: true,
    supplier: false,
    price: true,
    packSize: true,
  });

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<RawMaterial | null>(null);
  const [historyFor, setHistoryFor] = useState<RawMaterial | null>(null);
  const [deactivating, setDeactivating] = useState<RawMaterial | null>(null);
  const [bulkConfirm, setBulkConfirm] = useState<"inactive" | "active" | null>(null);

  const filtered = useMemo(() => {
    return materials.filter((m) => {
      if (search && !m.ingredient_name.toLowerCase().includes(search.toLowerCase())) return false;
      if (category !== "all" && m.category !== category) return false;
      if (status !== "all" && m.status !== status) return false;
      return true;
    });
  }, [materials, search, category, status]);

  const sorted = useMemo(() => {
    const arr = [...filtered];
    arr.sort((a, b) => {
      let cmp = 0;
      if (sort.key === "name") cmp = a.ingredient_name.localeCompare(b.ingredient_name);
      else if (sort.key === "category")
        cmp = a.category.localeCompare(b.category) || a.ingredient_name.localeCompare(b.ingredient_name);
      else if (sort.key === "price") cmp = (a.purchase_price ?? -Infinity) - (b.purchase_price ?? -Infinity);
      return sort.dir === "asc" ? cmp : -cmp;
    });
    return arr;
  }, [filtered, sort]);

  // Reset paging + selection whenever the visible set changes.
  useEffect(() => {
    setPage(1);
    setSelected(new Set());
  }, [search, category, status, sort, pageSize]);

  const pageCount = Math.max(1, Math.ceil(sorted.length / pageSize));
  const current = Math.min(page, pageCount);
  const pageItems = sorted.slice((current - 1) * pageSize, current * pageSize);

  const pageIds = pageItems.map((m) => m.id);
  const allPageSelected = pageIds.length > 0 && pageIds.every((id) => selected.has(id));
  const toggleOne = (id: string) =>
    setSelected((prev) => {
      const n = new Set(prev);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const toggleAllPage = () =>
    setSelected((prev) => {
      const n = new Set(prev);
      if (allPageSelected) pageIds.forEach((id) => n.delete(id));
      else pageIds.forEach((id) => n.add(id));
      return n;
    });

  const toggleSort = (key: SortKey) =>
    setSort((s) => (s.key === key ? { key, dir: s.dir === "asc" ? "desc" : "asc" } : { key, dir: "asc" }));

  const openAdd = () => {
    setEditing(null);
    setFormOpen(true);
  };
  const openEdit = (m: RawMaterial) => {
    setEditing(m);
    setFormOpen(true);
  };

  const [isExporting, setIsExporting] = useState(false);
  const doExport = async () => {
    if (isExporting) return;
    const list = selected.size > 0 ? sorted.filter((m) => selected.has(m.id)) : sorted;
    setIsExporting(true);
    try {
      await exportMaterials(list, String(list.length));
      toast.success(`Exported ${list.length} ingredient${list.length === 1 ? "" : "s"}`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Export failed");
    } finally {
      setIsExporting(false);
    }
  };

  const runBulk = async (next: "inactive" | "active") => {
    const ids = [...selected];
    try {
      const n = await bulkStatus.mutateAsync({ ids, status: next });
      setSelected(new Set());
      toast.success(`${next === "inactive" ? "Deactivated" : "Reactivated"} ${n} ingredient${n === 1 ? "" : "s"}`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Bulk update failed");
    }
  };

  const priceLabel = (m: RawMaterial) =>
    m.purchase_price === null ? null : formatINR(m.purchase_price);
  const sizeLabel = (m: RawMaterial) =>
    formatQuantityWithUnit(m.purchase_quantity, m.purchase_unit, { humanize: false });

  const renderActions = (m: RawMaterial) => (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label={`Actions for ${m.ingredient_name}`}>
          <MoreVertical className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        {canEdit && <DropdownMenuItem onClick={() => openEdit(m)}>Edit</DropdownMenuItem>}
        <DropdownMenuItem onClick={() => setHistoryFor(m)}>Price History</DropdownMenuItem>
        {canEdit &&
          (m.status === "active" ? (
            <DropdownMenuItem onClick={() => setDeactivating(m)}>Deactivate</DropdownMenuItem>
          ) : (
            <DropdownMenuItem
              onClick={async () => {
                try {
                  await setStatus.mutateAsync({ id: m.id, status: "active" });
                  toast.success("Ingredient reactivated");
                } catch (e) {
                  toast.error(e instanceof Error ? e.message : "Reactivate failed");
                }
              }}
            >
              Reactivate
            </DropdownMenuItem>
          ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );

  const SortHead = ({ label, k, className }: { label: string; k: SortKey; className?: string }) => {
    const active = sort.key === k;
    return (
      <TableHead className={className} aria-sort={active ? (sort.dir === "asc" ? "ascending" : "descending") : "none"}>
        <button
          className="inline-flex items-center gap-1 rounded hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          onClick={() => toggleSort(k)}
          aria-label={`Sort by ${label}`}
        >
          {label}
          {active ? (
            sort.dir === "asc" ? <ArrowUp className="h-3.5 w-3.5" /> : <ArrowDown className="h-3.5 w-3.5" />
          ) : (
            <ArrowUpDown className="h-3.5 w-3.5 opacity-40" />
          )}
        </button>
      </TableHead>
    );
  };

  return (
    <>
      <PageHeader
        title="Raw Materials"
        description={canEdit ? "Manage ingredients and their purchase pricing" : "Ingredient prices are managed by an admin."}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={doExport} disabled={isExporting}>
              <Download className="h-4 w-4" /> Export
            </Button>
            {canEdit && (
              <Button variant="outline" onClick={() => setImportOpen(true)}>
                <Upload className="h-4 w-4" /> Import
              </Button>
            )}
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline">
                  <Columns3 className="h-4 w-4" /> Columns
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuLabel>Visible columns</DropdownMenuLabel>
                <DropdownMenuSeparator />
                {COLUMN_DEFS.map((c) => (
                  <DropdownMenuItem
                    key={c.key}
                    onSelect={(e) => {
                      e.preventDefault();
                      setCols((prev) => ({ ...prev, [c.key]: !prev[c.key] }));
                    }}
                  >
                    <Checkbox checked={cols[c.key]} className="pointer-events-none" />
                    {c.label}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
            {canEdit && (
              <Button variant="accent" onClick={openAdd}>
                <Plus className="h-4 w-4" /> Add Ingredient
              </Button>
            )}
          </div>
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Input
            placeholder="Search ingredients…"
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
          <Select value={status} onValueChange={setStatus_}>
            <SelectTrigger>
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Statuses</SelectItem>
              <SelectItem value="active">Active</SelectItem>
              <SelectItem value="inactive">Inactive</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </Card>

      {/* Bulk action bar */}
      {canEdit && selected.size > 0 && (
        <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border bg-muted/50 px-4 py-2.5 text-sm">
          <span className="font-medium">{selected.size} selected</span>
          <div className="flex-1" />
          <Button variant="outline" size="sm" onClick={doExport} disabled={isExporting}>
            <Download className="h-4 w-4" /> Export
          </Button>
          <Button variant="outline" size="sm" onClick={() => setBulkConfirm("active")}>
            <RotateCcw className="h-4 w-4" /> Reactivate
          </Button>
          <Button variant="destructive" size="sm" onClick={() => setBulkConfirm("inactive")}>
            <Trash2 className="h-4 w-4" /> Deactivate
          </Button>
          <Button variant="ghost" size="sm" onClick={() => setSelected(new Set())}>
            Clear
          </Button>
        </div>
      )}

      <Card>
        {isLoading ? (
          <TableSkeleton rows={6} cols={4} />
        ) : sorted.length === 0 ? (
          <EmptyState
            title="No ingredients found"
            description="Add your first ingredient to start building recipes."
            action={
              canEdit && (
                <Button variant="accent" onClick={openAdd}>
                  <Plus className="h-4 w-4" /> Add Ingredient
                </Button>
              )
            }
          />
        ) : (
          <>
            {/* Desktop / tablet: table */}
            <div className="hidden md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    {canEdit && (
                      <TableHead className="w-10">
                        <Checkbox
                          checked={allPageSelected}
                          onCheckedChange={toggleAllPage}
                          aria-label="Select all on page"
                        />
                      </TableHead>
                    )}
                    <SortHead label="Name" k="name" />
                    {cols.category && <SortHead label="Category" k="category" />}
                    {cols.supplier && <TableHead>Supplier</TableHead>}
                    {cols.price && <SortHead label="Purchase Price" k="price" />}
                    {cols.packSize && <TableHead>Quantity</TableHead>}
                    <TableHead className="w-10" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pageItems.map((m) => (
                    <TableRow key={m.id} className={m.status === "inactive" ? "opacity-50" : ""} data-state={selected.has(m.id) ? "selected" : undefined}>
                      {canEdit && (
                        <TableCell>
                          <Checkbox
                            checked={selected.has(m.id)}
                            onCheckedChange={() => toggleOne(m.id)}
                            aria-label={`Select ${m.ingredient_name}`}
                          />
                        </TableCell>
                      )}
                      <TableCell className="font-medium">
                        <div className="flex items-center gap-2">
                          {m.purchase_price === null && (
                            <AlertTriangle className="h-4 w-4 text-amber-500" />
                          )}
                          {m.ingredient_name}
                        </div>
                      </TableCell>
                      {cols.category && <TableCell>{m.category}</TableCell>}
                      {cols.supplier && <TableCell>{m.supplier_name ?? "—"}</TableCell>}
                      {cols.price && (
                        <TableCell>{priceLabel(m) ?? <Badge variant="warning">No Price</Badge>}</TableCell>
                      )}
                      {cols.packSize && <TableCell>{sizeLabel(m)}</TableCell>}
                      <TableCell>{renderActions(m)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            {/* Mobile: stacked cards (no horizontal scroll) */}
            <ul className="divide-y md:hidden">
              {pageItems.map((m) => (
                <li
                  key={m.id}
                  className={cn("flex items-start gap-3 p-4", m.status === "inactive" && "opacity-50")}
                >
                  {canEdit && (
                    <Checkbox
                      checked={selected.has(m.id)}
                      onCheckedChange={() => toggleOne(m.id)}
                      className="mt-1"
                      aria-label={`Select ${m.ingredient_name}`}
                    />
                  )}
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      {m.purchase_price === null && (
                        <AlertTriangle className="h-4 w-4 shrink-0 text-amber-500" />
                      )}
                      <p className="truncate font-medium">{m.ingredient_name}</p>
                    </div>
                    <p className="mt-0.5 text-xs text-muted-foreground">{m.category}</p>
                    <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                      {priceLabel(m) ? (
                        <span className="font-medium">{priceLabel(m)}</span>
                      ) : (
                        <Badge variant="warning">No Price</Badge>
                      )}
                      <span className="text-muted-foreground">{sizeLabel(m)}</span>
                    </div>
                  </div>
                  {renderActions(m)}
                </li>
              ))}
            </ul>

            <Pagination
              page={current}
              pageSize={pageSize}
              total={sorted.length}
              onPageChange={setPage}
              label="ingredients"
            />
          </>
        )}
      </Card>

      <MaterialForm open={formOpen} onOpenChange={setFormOpen} material={editing} />
      <ImportDialog open={importOpen} onOpenChange={setImportOpen} config={importConfig} />
      <PriceHistoryDialog
        material={historyFor}
        open={!!historyFor}
        onOpenChange={(o) => !o && setHistoryFor(null)}
      />
      <ConfirmDialog
        open={!!deactivating}
        onOpenChange={(o) => !o && setDeactivating(null)}
        title="Deactivate ingredient?"
        description={`"${deactivating?.ingredient_name}" will be hidden from new recipes. Existing recipes keep their data.`}
        confirmLabel="Deactivate"
        destructive
        onConfirm={async () => {
          if (!deactivating) return;
          const m = deactivating;
          try {
            await setStatus.mutateAsync({ id: m.id, status: "inactive" });
            toast.success("Ingredient deactivated", undefined, {
              action: { label: "Undo", onClick: () => setStatus.mutate({ id: m.id, status: "active" }) },
            });
          } catch (e) {
            toast.error(e instanceof Error ? e.message : "Deactivate failed");
          }
        }}
      />
      <ConfirmDialog
        open={!!bulkConfirm}
        onOpenChange={(o) => !o && setBulkConfirm(null)}
        title={bulkConfirm === "inactive" ? `Deactivate ${selected.size} ingredients?` : `Reactivate ${selected.size} ingredients?`}
        description={
          bulkConfirm === "inactive"
            ? "They'll be hidden from new recipes. Existing recipes keep their data."
            : "They'll be available for new recipes again."
        }
        confirmLabel={bulkConfirm === "inactive" ? "Deactivate" : "Reactivate"}
        destructive={bulkConfirm === "inactive"}
        onConfirm={() => bulkConfirm && runBulk(bulkConfirm)}
      />
    </>
  );
}
