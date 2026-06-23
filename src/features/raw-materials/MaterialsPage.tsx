import { useMemo, useState } from "react";
import { AlertTriangle, MoreVertical, Plus } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
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
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { formatINR } from "@/lib/utils";
import type { RawMaterial } from "@/lib/data/types";
import { useMaterials, useSetMaterialStatus } from "./hooks";
import { useCategories } from "@/features/settings/hooks";
import { MaterialForm } from "./MaterialForm";
import { PriceHistoryDialog } from "./PriceHistoryDialog";
import { toast } from "@/components/ui/use-toast";

export function MaterialsPage() {
  const { data: materials = [], isLoading } = useMaterials();
  const { data: categories = [] } = useCategories();
  const setStatus = useSetMaterialStatus();

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [status, setStatus_] = useState("active");

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<RawMaterial | null>(null);
  const [historyFor, setHistoryFor] = useState<RawMaterial | null>(null);
  const [deactivating, setDeactivating] = useState<RawMaterial | null>(null);

  const filtered = useMemo(() => {
    return materials.filter((m) => {
      if (search && !m.ingredient_name.toLowerCase().includes(search.toLowerCase())) return false;
      if (category !== "all" && m.category !== category) return false;
      if (status !== "all" && m.status !== status) return false;
      return true;
    });
  }, [materials, search, category, status]);

  const openAdd = () => {
    setEditing(null);
    setFormOpen(true);
  };
  const openEdit = (m: RawMaterial) => {
    setEditing(m);
    setFormOpen(true);
  };

  return (
    <>
      <PageHeader
        title="Raw Materials"
        description="Manage ingredients and their purchase pricing"
        actions={
          <Button variant="accent" onClick={openAdd}>
            <Plus className="h-4 w-4" /> Add Ingredient
          </Button>
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

      <Card>
        {isLoading ? (
          <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>
        ) : filtered.length === 0 ? (
          <EmptyState
            title="No ingredients found"
            description="Add your first ingredient to start building recipes."
            action={
              <Button variant="accent" onClick={openAdd}>
                <Plus className="h-4 w-4" /> Add Ingredient
              </Button>
            }
          />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Category</TableHead>
                <TableHead>Supplier</TableHead>
                <TableHead>Purchase</TableHead>
                <TableHead>Base Unit</TableHead>
                <TableHead>Cost / Unit</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((m) => (
                <TableRow key={m.id} className={m.status === "inactive" ? "opacity-50" : ""}>
                  <TableCell className="font-medium">
                    <div className="flex items-center gap-2">
                      {m.purchase_price === null && (
                        <AlertTriangle className="h-4 w-4 text-amber-500" />
                      )}
                      {m.ingredient_name}
                    </div>
                  </TableCell>
                  <TableCell>{m.category}</TableCell>
                  <TableCell className="text-muted-foreground">{m.supplier_name ?? "—"}</TableCell>
                  <TableCell>
                    {m.purchase_price === null ? (
                      <Badge variant="warning">No Price</Badge>
                    ) : (
                      `${formatINR(m.purchase_price)} / ${m.purchase_quantity} ${m.purchase_unit}`
                    )}
                  </TableCell>
                  <TableCell>{m.base_unit}</TableCell>
                  <TableCell className="font-medium">
                    {m.cost_per_base_unit === null
                      ? "—"
                      : `${formatINR(m.cost_per_base_unit)}`}
                  </TableCell>
                  <TableCell>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="ghost" size="icon">
                          <MoreVertical className="h-4 w-4" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onClick={() => openEdit(m)}>Edit</DropdownMenuItem>
                        <DropdownMenuItem onClick={() => setHistoryFor(m)}>
                          Price History
                        </DropdownMenuItem>
                        {m.status === "active" ? (
                          <DropdownMenuItem onClick={() => setDeactivating(m)}>
                            Deactivate
                          </DropdownMenuItem>
                        ) : (
                          <DropdownMenuItem
                            onClick={async () => {
                              await setStatus.mutateAsync({ id: m.id, status: "active" });
                              toast.success("Ingredient reactivated");
                            }}
                          >
                            Reactivate
                          </DropdownMenuItem>
                        )}
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Card>

      <MaterialForm open={formOpen} onOpenChange={setFormOpen} material={editing} />
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
          await setStatus.mutateAsync({ id: deactivating.id, status: "inactive" });
          toast.success("Ingredient deactivated");
        }}
      />
    </>
  );
}
