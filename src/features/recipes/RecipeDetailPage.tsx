import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Copy, Pencil, Send, CheckCircle2, XCircle, Lock } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { StatusBadge } from "@/components/StatusBadge";
import { EmptyState } from "@/components/EmptyState";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Textarea } from "@/components/ui/textarea";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { formatDate, formatINR } from "@/lib/utils";
import { calculateIngredientCost } from "@/lib/costing";
import { canConvert } from "@/lib/units";
import { useSession } from "@/lib/auth/session";
import { can, canEditRecipe, visibilityFor } from "@/lib/auth/permissions";
import { toast } from "@/components/ui/use-toast";
import { useUsersMap } from "@/features/users/hooks";
import { useUserViews } from "@/features/viewers/hooks";
import { useFoodCostPct } from "@/features/settings/hooks";
import { CostSummary } from "@/features/costing/CostSummary";
import { RecipePdfButton } from "@/features/reports/RecipePdfButton";
import {
  useApproveRecipe,
  useDuplicateRecipe,
  useRecipe,
  useRecipeCostHistory,
  useRecipeVersions,
  useRejectRecipe,
  useSubmitRecipe,
} from "./hooks";

export function RecipeDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const user = useSession((s) => s.user)!;

  const { data, isLoading } = useRecipe(id);
  const { data: foodCostPct = 30 } = useFoodCostPct();
  const { map: usersMap } = useUsersMap();
  const { data: myViews = [] } = useUserViews(user.role === "viewer" ? user.id : undefined);
  const costHistory = useRecipeCostHistory(id);
  const versions = useRecipeVersions(id);

  const dupMut = useDuplicateRecipe();
  const submitMut = useSubmitRecipe();
  const approveMut = useApproveRecipe();
  const rejectMut = useRejectRecipe();

  const [submitOpen, setSubmitOpen] = useState(false);
  const [submitNote, setSubmitNote] = useState("");
  const [rejectOpen, setRejectOpen] = useState(false);
  const [rejectNote, setRejectNote] = useState("");
  const [approveOpen, setApproveOpen] = useState(false);

  if (isLoading) return <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>;
  if (!data) return <EmptyState title="Recipe not found" />;

  const { recipe, ingredients } = data;

  // Viewer access enforcement (PRD §14, §9.3 RLS).
  const myView = myViews.find((v) => v.recipe_id === recipe.id) ?? null;
  if (user.role === "viewer") {
    if (!myView || recipe.status !== "approved") {
      return (
        <EmptyState
          icon={<Lock className="h-10 w-10" />}
          title="No access"
          description="This recipe hasn't been shared with you."
        />
      );
    }
  }

  const vis = visibilityFor(user.role, myView?.view_type ?? null);
  const editable = canEditRecipe(user, recipe);
  const isAdmin = can(user.role, "recipe.approve");

  return (
    <>
      <PageHeader
        title={recipe.recipe_name}
        description={`${recipe.category} • ${recipe.serving_size} portions`}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <RecipePdfButton recipe={recipe} ingredients={ingredients} foodCostPct={foodCostPct} visibility={vis} />
            {can(user.role, "recipe.duplicate") && (
              <Button
                variant="outline"
                onClick={async () => {
                  const copy = await dupMut.mutateAsync(recipe.id);
                  toast.success("Recipe duplicated");
                  navigate(`/recipes/${copy.id}/edit`);
                }}
              >
                <Copy className="h-4 w-4" /> Duplicate
              </Button>
            )}
            {editable && (
              <Button variant="outline" onClick={() => navigate(`/recipes/${recipe.id}/edit`)}>
                <Pencil className="h-4 w-4" /> Edit
              </Button>
            )}
            {editable && recipe.status === "draft" && (
              <Button variant="accent" onClick={() => setSubmitOpen(true)}>
                <Send className="h-4 w-4" /> Submit
              </Button>
            )}
            {isAdmin && recipe.status === "testing" && (
              <>
                <Button variant="destructive" onClick={() => setRejectOpen(true)}>
                  <XCircle className="h-4 w-4" /> Reject
                </Button>
                <Button variant="accent" onClick={() => setApproveOpen(true)}>
                  <CheckCircle2 className="h-4 w-4" /> Approve
                </Button>
              </>
            )}
          </div>
        }
      />

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <StatusBadge status={recipe.status} />
        <span className="text-sm text-muted-foreground">
          Created by {usersMap.get(recipe.created_by ?? "")?.name ?? "—"}
        </span>
        {recipe.approved_by && (
          <span className="text-sm text-muted-foreground">
            • Approved by {usersMap.get(recipe.approved_by)?.name ?? "—"} on {formatDate(recipe.approved_at)}
          </span>
        )}
      </div>

      {recipe.rejection_note && (
        <div className="mb-4 rounded-md bg-destructive/10 px-4 py-3 text-sm text-destructive">
          <strong>Rejection note:</strong> {recipe.rejection_note}
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {recipe.description && (
            <Card className="p-5">
              <p className="mb-1 text-sm font-semibold">Description</p>
              <p className="text-sm text-muted-foreground">{recipe.description}</p>
            </Card>
          )}

          <Card className="p-5">
            <p className="mb-3 text-sm font-semibold">Ingredients</p>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>#</TableHead>
                  <TableHead>Ingredient</TableHead>
                  {vis.quantities && <TableHead>Qty</TableHead>}
                  {vis.quantities && <TableHead>Unit</TableHead>}
                  {vis.unitCosts && <TableHead>Unit Cost</TableHead>}
                  {vis.totalCost && <TableHead className="text-right">Total</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {ingredients.map((ing, idx) => {
                  const m = ing.material;
                  const cost =
                    m && m.cost_per_base_unit !== null && canConvert(ing.unit_used, m.base_unit)
                      ? calculateIngredientCost(
                          m.cost_per_base_unit,
                          ing.quantity_used,
                          ing.unit_used,
                          m.base_unit,
                        )
                      : null;
                  return (
                    <TableRow key={ing.id}>
                      <TableCell>{idx + 1}</TableCell>
                      <TableCell className="font-medium">
                        {m?.ingredient_name ?? "—"}
                      </TableCell>
                      {vis.quantities && <TableCell>{ing.quantity_used}</TableCell>}
                      {vis.quantities && <TableCell>{ing.unit_used}</TableCell>}
                      {vis.unitCosts && (
                        <TableCell>{formatINR(m?.cost_per_base_unit ?? null)}</TableCell>
                      )}
                      {vis.totalCost && (
                        <TableCell className="text-right">{formatINR(cost)}</TableCell>
                      )}
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </Card>

          {(isAdmin || editable) && (
            <Card className="p-5">
              <Tabs defaultValue="cost">
                <TabsList>
                  <TabsTrigger value="cost">Cost History</TabsTrigger>
                  <TabsTrigger value="versions">Versions</TabsTrigger>
                </TabsList>
                <TabsContent value="cost">
                  {(costHistory.data ?? []).length === 0 ? (
                    <p className="py-4 text-sm text-muted-foreground">No cost changes recorded.</p>
                  ) : (
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Date</TableHead>
                          <TableHead>Old Total</TableHead>
                          <TableHead>New Total</TableHead>
                          <TableHead>Reason</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {(costHistory.data ?? []).map((h) => (
                          <TableRow key={h.id}>
                            <TableCell>{formatDate(h.changed_at)}</TableCell>
                            <TableCell>{formatINR(h.old_total_cost)}</TableCell>
                            <TableCell>{formatINR(h.new_total_cost)}</TableCell>
                            <TableCell className="text-muted-foreground">{h.change_reason}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  )}
                </TabsContent>
                <TabsContent value="versions">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Version</TableHead>
                        <TableHead>Notes</TableHead>
                        <TableHead>Date</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(versions.data ?? []).map((v) => (
                        <TableRow key={v.id}>
                          <TableCell>v{v.version_no}</TableCell>
                          <TableCell className="text-muted-foreground">{v.notes}</TableCell>
                          <TableCell>{formatDate(v.created_at)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TabsContent>
              </Tabs>
            </Card>
          )}
        </div>

        <div className="space-y-4">
          <CostSummary
            totalCost={recipe.total_cost ?? 0}
            costPerPortion={recipe.cost_per_portion ?? 0}
            suggestedPrice={
              recipe.cost_per_portion ? (recipe.cost_per_portion / (foodCostPct / 100)) : 0
            }
            grossProfit={
              recipe.cost_per_portion
                ? recipe.cost_per_portion / (foodCostPct / 100) - recipe.cost_per_portion
                : 0
            }
            grossMarginPct={100 - foodCostPct}
            foodCostPct={foodCostPct}
            servingSize={recipe.serving_size}
            visibility={vis}
          />
        </div>
      </div>

      {/* Submit dialog */}
      <Dialog open={submitOpen} onOpenChange={setSubmitOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Submit for Approval</DialogTitle>
            <DialogDescription>Add an optional note for the reviewer.</DialogDescription>
          </DialogHeader>
          <Textarea
            placeholder="Notes to reviewer (optional)…"
            value={submitNote}
            onChange={(e) => setSubmitNote(e.target.value)}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setSubmitOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="accent"
              onClick={async () => {
                await submitMut.mutateAsync({ id: recipe.id, note: submitNote || null });
                toast.success("Submitted for testing");
                setSubmitOpen(false);
              }}
            >
              Submit for Testing
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Approve confirm */}
      <ConfirmDialog
        open={approveOpen}
        onOpenChange={setApproveOpen}
        title="Approve recipe?"
        description={`"${recipe.recipe_name}" will become available to assigned viewers.`}
        confirmLabel="Approve"
        onConfirm={async () => {
          await approveMut.mutateAsync(recipe.id);
          toast.success("Recipe approved");
        }}
      />

      {/* Reject dialog (mandatory note) */}
      <Dialog open={rejectOpen} onOpenChange={setRejectOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Reject Recipe</DialogTitle>
            <DialogDescription>
              The recipe returns to Draft. A note is required.
            </DialogDescription>
          </DialogHeader>
          <Textarea
            placeholder="Reason for rejection…"
            value={rejectNote}
            onChange={(e) => setRejectNote(e.target.value)}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setRejectOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              disabled={!rejectNote.trim()}
              onClick={async () => {
                await rejectMut.mutateAsync({ id: recipe.id, note: rejectNote.trim() });
                toast.success("Recipe rejected");
                setRejectOpen(false);
                setRejectNote("");
              }}
            >
              Reject Recipe
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
