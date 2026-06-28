import { useMemo, useState } from "react";
import { BadgeCheck, Clock, KeyRound, LayoutDashboard, Mail, MoreVertical, Plus } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { TableSkeleton } from "@/components/TableSkeleton";
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
import { toast } from "@/components/ui/use-toast";
import { OUTLETS, ROLE_LABELS, type User } from "@/lib/data/types";
import { isFirebaseConfigured } from "@/lib/firebase/client";
import { firebaseResetPassword } from "@/lib/firebase/auth";
import { useUpdateUser, useUsers } from "./hooks";
import { UserForm } from "./UserForm";
import { AssignAccessDialog } from "@/features/viewers/AssignAccessDialog";

const outletLabel = (id?: string | null) => {
  const o = OUTLETS.find((x) => x.id === id);
  return o ? o.name : null;
};

const fmtDate = (iso?: string | null) => {
  if (!iso) return "Never";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toLocaleDateString(undefined, { day: "2-digit", month: "short", year: "numeric" });
};

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
        if (status === "pending") {
          if (u.approved !== false) return false;
        } else if (status !== "all" && u.status !== status) return false;
        return true;
      }),
    [users, search, role, status],
  );

  const [deactivating, setDeactivating] = useState<User | null>(null);

  const setUserStatus = async (u: User, next: "active" | "inactive") => {
    try {
      await updateMut.mutateAsync({ id: u.id, patch: { status: next } });
      toast.success(next === "inactive" ? "User deactivated" : "User reactivated");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    }
  };

  const sendReset = async (u: User) => {
    try {
      await firebaseResetPassword(u.email);
      toast.success(`Password reset email sent to ${u.email}`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not send reset email");
    }
  };

  const toggleDashboard = async (u: User) => {
    try {
      await updateMut.mutateAsync({ id: u.id, patch: { dashboard_access: !u.dashboard_access } });
      toast.success(u.dashboard_access ? "Dashboard access revoked" : "Dashboard access granted");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    }
  };

  const approveUser = async (u: User) => {
    try {
      await updateMut.mutateAsync({ id: u.id, patch: { approved: true } });
      toast.success(`${u.name} verified — they can now sign in`);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    }
  };

  const pendingCount = users.filter((u) => u.approved === false).length;

  return (
    <>
      <PageHeader
        title="User Management"
        description="Manage accounts, roles, verification, and brand/outlet access"
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

      {pendingCount > 0 && (
        <button
          onClick={() => setStatus("pending")}
          className="mb-4 flex w-full items-center gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-left text-sm text-amber-700 dark:text-amber-400"
        >
          <Clock className="h-4 w-4 shrink-0" />
          <span className="font-medium">
            {pendingCount} {pendingCount === 1 ? "user is" : "users are"} awaiting verification.
          </span>
          <span className="text-amber-700/70 dark:text-amber-400/70">Review &amp; approve →</span>
        </button>
      )}

      <Card className="mb-4 p-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Input placeholder="Search users…" value={search} onChange={(e) => setSearch(e.target.value)} />
          <Select value={role} onValueChange={setRole}>
            <SelectTrigger>
              <SelectValue placeholder="Role" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Roles</SelectItem>
              {(Object.keys(ROLE_LABELS) as (keyof typeof ROLE_LABELS)[]).map((r) => (
                <SelectItem key={r} value={r}>{ROLE_LABELS[r]}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select value={status} onValueChange={setStatus}>
            <SelectTrigger>
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All Statuses</SelectItem>
              <SelectItem value="pending">Pending Verification</SelectItem>
              <SelectItem value="active">Active</SelectItem>
              <SelectItem value="inactive">Inactive</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </Card>

      <Card>
        {isLoading ? (
          <TableSkeleton rows={5} cols={4} />
        ) : filtered.length === 0 ? (
          <EmptyState title="No users found" />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Email</TableHead>
                <TableHead>Role</TableHead>
                <TableHead className="hidden lg:table-cell">Assigned</TableHead>
                <TableHead>Account</TableHead>
                <TableHead className="hidden md:table-cell">Last Login</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((u) => {
                const outlet = outletLabel(u.assigned_outlet);
                const scoped = u.role === "outlet_manager" || u.role === "staff";
                return (
                <TableRow key={u.id}>
                  <TableCell className="font-medium">{u.name}</TableCell>
                  <TableCell className="text-muted-foreground">
                    <div className="flex items-center gap-1.5">
                      {u.email}
                      {u.email_verified && (
                        <BadgeCheck className="h-3.5 w-3.5 text-emerald-500" aria-label="Email verified" />
                      )}
                    </div>
                    {u.firebase_uid && (
                      <span className="block font-mono text-[10px] text-muted-foreground/70" title={u.firebase_uid}>
                        UID {u.firebase_uid.slice(0, 12)}…
                      </span>
                    )}
                  </TableCell>
                  <TableCell>{ROLE_LABELS[u.role]}</TableCell>
                  <TableCell className="hidden lg:table-cell text-muted-foreground">
                    {scoped ? outlet ?? "All outlets" : "—"}
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap items-center gap-1">
                      {u.approved === false ? (
                        <Badge variant="outline" className="gap-1 border-amber-500/50 text-amber-600 dark:text-amber-400">
                          <Clock className="h-3 w-3" /> Pending
                        </Badge>
                      ) : (
                        <Badge variant={u.status === "active" ? "success" : "secondary"}>
                          {u.status}
                        </Badge>
                      )}
                      {(u.role === "admin" || u.dashboard_access) && (
                        <Badge variant="outline" className="gap-1" title="Can view Master Costing dashboard">
                          <LayoutDashboard className="h-3 w-3" /> Costing
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="hidden md:table-cell text-muted-foreground">
                    {fmtDate(u.last_login)}
                  </TableCell>
                  <TableCell>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button variant="ghost" size="icon">
                          <MoreVertical className="h-4 w-4" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        {u.approved === false && (
                          <DropdownMenuItem onClick={() => approveUser(u)} className="text-emerald-600 dark:text-emerald-400">
                            <BadgeCheck className="h-4 w-4" /> Verify &amp; Approve
                          </DropdownMenuItem>
                        )}
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
                        {u.role !== "admin" && (
                          <DropdownMenuItem onClick={() => toggleDashboard(u)}>
                            <LayoutDashboard className="h-4 w-4" />
                            {u.dashboard_access ? "Revoke dashboard access" : "Grant dashboard access"}
                          </DropdownMenuItem>
                        )}
                        {isFirebaseConfigured && (
                          <DropdownMenuItem onClick={() => sendReset(u)}>
                            <Mail className="h-4 w-4" /> Send Password Reset
                          </DropdownMenuItem>
                        )}
                        <DropdownMenuItem
                          onClick={() =>
                            u.status === "active" ? setDeactivating(u) : setUserStatus(u, "active")
                          }
                        >
                          {u.status === "active" ? "Deactivate" : "Reactivate"}
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                </TableRow>
                );
              })}
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
      <ConfirmDialog
        open={!!deactivating}
        onOpenChange={(o) => !o && setDeactivating(null)}
        title={`Deactivate ${deactivating?.name}?`}
        description="They'll lose access until reactivated. Their data is kept."
        confirmLabel="Deactivate"
        destructive
        onConfirm={() => deactivating && setUserStatus(deactivating, "inactive")}
      />
    </>
  );
}
