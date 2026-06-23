import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState } from "@/components/EmptyState";
import { formatDate, formatINR } from "@/lib/utils";
import { percentChange } from "@/lib/costing";
import type { RawMaterial } from "@/lib/data/types";
import { usePriceHistory } from "./hooks";

export function PriceHistoryDialog({
  material,
  open,
  onOpenChange,
}: {
  material: RawMaterial | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const { data: history = [], isLoading } = usePriceHistory(material?.id);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Price History — {material?.ingredient_name}</DialogTitle>
        </DialogHeader>
        {isLoading ? (
          <p className="py-6 text-center text-sm text-muted-foreground">Loading…</p>
        ) : history.length === 0 ? (
          <EmptyState title="No price changes yet" description="Updates to this ingredient's price will appear here." />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Date</TableHead>
                <TableHead>Old Price</TableHead>
                <TableHead>New Price</TableHead>
                <TableHead>Change %</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {history.map((h) => {
                const change = percentChange(h.old_price ?? 0, h.new_price ?? 0);
                return (
                  <TableRow key={h.id}>
                    <TableCell>{formatDate(h.changed_at)}</TableCell>
                    <TableCell>{formatINR(h.old_price)}</TableCell>
                    <TableCell>{formatINR(h.new_price)}</TableCell>
                    <TableCell className={change >= 0 ? "text-red-600" : "text-green-600"}>
                      {change >= 0 ? "+" : ""}
                      {change}%
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </DialogContent>
    </Dialog>
  );
}
