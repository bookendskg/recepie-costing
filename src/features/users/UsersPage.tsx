import { useMemo, useState } from "react";
import { KeyRound, MoreVertical, Plus } from "lucide-react";
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
import { toast } from "@/components/ui/use-toast";
import type { User } from "@/lib/data/types";
import { useUpdateUser, useUsers } from "./hooks";
import { UserForm } from "./UserForm";
import { AssignAccessDialog } from "@/features/viewers/AssignAccessDialog";

export function UsersPage() {
  const { data: users = [], isLoading } = useUsers();
  const updateMut = useUpdateUser();

  const [search, setSearch] = useState("");
  const [role, setRole] = useState("all");
  const [status, setStatus] = useState("all");

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<User | null>(null);
  const [assignFor, setAssignFor] = useState<User | null>(null);

  const filtered = useMemo(
    () =>
      users.filter((u) => {
        if (search && !`${u.name} ${u.email}`.toLowerCase().includes(search.toLowerCase()))
          return false;
        if (role !== "all" && u.role !== role) return false;
        if (status !== "all" && u.status !== status) return false;
        return true;
      }),
    [users, search, role, status],
  );

  const toggleStatus = async (u: User) => {
    await updateMut.mutateAsync({
      id: u.id,
      patch: { status: u.status === "active" ? "inactive" : "active" },
    });
    toast.success(u.status === "active" ? "User deactivated" : "User reactivated");
  };

  return (
    <>
      <PageHeader
        title="Users"
        description="Manage accounts, roles, and viewer access"
        actions={
          <Button
            variant="accent"
            onClick={() => {
              setEditing(null);
              setFormOpen(true);
            }}
          >
            <Plus className="h-4 w-4" /> Create User
          </Button>
        }
      />

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Input placeholder="Search users…" value={search} onChange={(e) => setSearch(e.target.value)} />
          <Select value={role} onValueChange={setRole}>
            <SelectTrigger>
              <SelectValue placeholder="Role" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Roles</SelectItem>
              <SelectItem value="admin">Admin</SelectItem>
              <SelectItem value="editor">Editor</SelectItem>
              <SelectItem value="viewer">Viewer</SelectItem>
            </SelectContent>
          </Select>
          <Select value={status} onValueChange={setStatus}>
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
          <EmptyState title="No users found" />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Email</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((u) => (
                <TableRow key={u.id}>
                  <TableCell className="font-medium">{u.name}</TableCell>
                  <TableCell className="text-muted-foreground">{u.email}</TableCell>
                  <TableCell className="capitalize">{u.role}</TableCell>
                  <TableCell>
                    <Badge variant={u.status === "active" ? "success" : "secondary"}>
                      {u.status}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="ghost" size="icon">
                          <MoreVertical className="h-4 w-4" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem
                          onClick={() => {
                            setEditing(u);
                            setFormOpen(true);
                          }}
                        >
                          Edit
                        </DropdownMenuItem>
                        {u.role === "viewer" && (
                          <DropdownMenuItem onClick={() => setAssignFor(u)}>
                            <KeyRound className="h-4 w-4" /> Assign Recipe Access
                          </DropdownMenuItem>
                        )}
                        <DropdownMenuItem onClick={() => toggleStatus(u)}>
                          {u.status === "active" ? "Deactivate" : "Reactivate"}
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Card>

      <UserForm open={formOpen} onOpenChange={setFormOpen} user={editing} />
      <AssignAccessDialog
        user={assignFor}
        open={!!assignFor}
        onOpenChange={(o) => !o && setAssignFor(null)}
      />
    </>
  );
}
