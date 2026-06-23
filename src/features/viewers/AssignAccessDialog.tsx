import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { EmptyState } from "@/components/EmptyState";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { toast } from "@/components/ui/use-toast";
import type { User, ViewType } from "@/lib/data/types";
import { useRecipes } from "@/features/recipes/hooks";
import { useRemoveAccess, useSetAccess, useUserViews } from "./hooks";

const NONE = "none";

export function AssignAccessDialog({
  user,
  open,
  onOpenChange,
}: {
  user: User | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const { data: recipes = [] } = useRecipes();
  const { data: views = [] } = useUserViews(user?.id);
  const setAccess = useSetAccess();
  const removeAccess = useRemoveAccess();

  const approved = recipes.filter((r) => r.status === "approved");
  const viewFor = (recipeId: string): ViewType | null =>
    views.find((v) => v.recipe_id === recipeId)?.view_type ?? null;

  const change = async (recipeId: string, value: string) => {
    if (!user) return;
    try {
      if (value === NONE) {
        await removeAccess.mutateAsync({ userId: user.id, recipeId });
      } else {
        await setAccess.mutateAsync({ userId: user.id, recipeId, viewType: value as ViewType });
      }
      toast.success("Access updated");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Assign Recipe Access — {user?.name}</DialogTitle>
          <DialogDescription>
            Choose a view mode per recipe. Capiche hides costs; Aiko shows full costing.
          </DialogDescription>
        </DialogHeader>
        {approved.length === 0 ? (
          <EmptyState title="No approved recipes" description="Approve recipes before assigning access." />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Recipe</TableHead>
                <TableHead>Category</TableHead>
                <TableHead className="w-40">View Mode</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {approved.map((r) => (
                <TableRow key={r.id}>
                  <TableCell className="font-medium">{r.recipe_name}</TableCell>
                  <TableCell>{r.category}</TableCell>
                  <TableCell>
                    <Select value={viewFor(r.id) ?? NONE} onValueChange={(v) => change(r.id, v)}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value={NONE}>No access</SelectItem>
                        <SelectItem value="capiche">Capiche (no cost)</SelectItem>
                        <SelectItem value="aiko">Aiko (full cost)</SelectItem>
                      </SelectContent>
                    </Select>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </DialogContent>
    </Dialog>
  );
}
