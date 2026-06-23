import { useState } from "react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
import { formatDateTime } from "@/lib/utils";
import type { AuditEntityType } from "@/lib/data/types";
import { useUsers } from "@/features/users/hooks";
import { useAuditLogs } from "./hooks";

const actionVariant: Record<string, "success" | "warning" | "info" | "danger" | "secondary"> = {
  create: "info",
  update: "secondary",
  delete: "danger",
  approve: "success",
  reject: "danger",
  submit: "warning",
};

export function AuditPage() {
  const { data: users = [] } = useUsers();
  const usersById = new Map(users.map((u) => [u.id, u]));

  const [entityType, setEntityType] = useState<AuditEntityType | "all">("all");
  const [userId, setUserId] = useState("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");

  const { data: logs = [], isLoading } = useAuditLogs({ entityType, userId, from, to });

  return (
    <>
      <PageHeader title="Audit Log" description="Every change to recipes, ingredients, and users" />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="space-y-1.5">
            <Label>Event Type</Label>
            <Select value={entityType} onValueChange={(v) => setEntityType(v as AuditEntityType | "all")}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All Events</SelectItem>
                <SelectItem value="recipe">Recipe</SelectItem>
                <SelectItem value="ingredient">Ingredient</SelectItem>
                <SelectItem value="user">User</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>User</Label>
            <Select value={userId} onValueChange={setUserId}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All Users</SelectItem>
                {users.map((u) => (
                  <SelectItem key={u.id} value={u.id}>
                    {u.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>From</Label>
            <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label>To</Label>
            <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
          </div>
        </div>
      </Card>

      <Card>
        {isLoading ? (
          <p className="p-8 text-center text-sm text-muted-foreground">Loading…</p>
        ) : logs.length === 0 ? (
          <EmptyState title="No audit entries" description="Actions will be recorded here." />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Time</TableHead>
                <TableHead>User</TableHead>
                <TableHead>Action</TableHead>
                <TableHead>Details</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {logs.map((a) => (
                <TableRow key={a.id}>
                  <TableCell className="whitespace-nowrap">{formatDateTime(a.performed_at)}</TableCell>
                  <TableCell>{usersById.get(a.performed_by ?? "")?.name ?? "—"}</TableCell>
                  <TableCell>
                    <Badge variant={actionVariant[a.action] ?? "secondary"}>{a.action}</Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground">{a.notes ?? "—"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Card>
    </>
  );
}
