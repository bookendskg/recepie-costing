import { Check, Minus, ShieldCheck } from "lucide-react";
import { PageHeader } from "@/components/PageHeader";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { ROLE_LABELS, type Role } from "@/lib/data/types";
import { ALL_CAPABILITIES, CAPABILITY_LABELS, roleCapabilities } from "@/lib/auth/permissions";

const ROLES: Role[] = ["super_admin", "admin", "editor", "head_chef", "chef", "viewer"];

/** Super-Admin-only Roles & Permissions. This first slice shows the effective
 *  permission matrix for every role; custom-role editing lands in the next phase. */
export function RolesPage() {
  const capsByRole = new Map(ROLES.map((r) => [r, new Set(roleCapabilities(r))]));

  return (
    <>
      <PageHeader
        title="Roles & Permissions"
        description="Effective permissions for every role. Only a Super Admin can view or change this."
      />

      <Card className="mb-4 flex items-center gap-3 border-emerald-200 bg-emerald-50/60 p-4">
        <ShieldCheck className="h-5 w-5 shrink-0 text-emerald-700" />
        <p className="text-sm text-emerald-900">
          <span className="font-semibold">Super Admin</span> is a protected role — it sits above Admin, cannot be
          deleted or deactivated, and is the only role that can manage roles and permissions.
        </p>
      </Card>

      <Card className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="min-w-56">Permission</TableHead>
              {ROLES.map((r) => (
                <TableHead key={r} className="text-center">
                  <div className="flex flex-col items-center gap-1">
                    <span>{ROLE_LABELS[r]}</span>
                    {r === "super_admin" && <Badge variant="success" className="text-[10px]">Protected</Badge>}
                  </div>
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {ALL_CAPABILITIES.map((cap) => (
              <TableRow key={cap}>
                <TableCell className="font-medium">
                  {CAPABILITY_LABELS[cap]}
                  <span className="ml-2 text-[11px] text-muted-foreground">{cap}</span>
                </TableCell>
                {ROLES.map((r) => (
                  <TableCell key={r} className="text-center">
                    {r === "super_admin" || capsByRole.get(r)!.has(cap) ? (
                      <Check className="mx-auto h-4 w-4 text-emerald-600" />
                    ) : (
                      <Minus className="mx-auto h-4 w-4 text-muted-foreground/40" />
                    )}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Card>
    </>
  );
}
