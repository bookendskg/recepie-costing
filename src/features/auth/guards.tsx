import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useSession } from "@/lib/auth/session";
import { isPendingApproval } from "@/lib/auth/permissions";
import { PendingApprovalPage } from "./PendingApprovalPage";
import type { Role } from "@/lib/data/types";

/** Requires a logged-in (and admin-verified) user; otherwise redirect/gate. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const user = useSession((s) => s.user);
  const location = useLocation();
  if (!user) {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }
  // Self sign-ups await admin verification before they can use the app.
  if (isPendingApproval(user)) {
    return <PendingApprovalPage />;
  }
  return <>{children}</>;
}

/** Requires one of the given roles; otherwise bounce to the dashboard. */
export function RequireRole({ roles, children }: { roles: Role[]; children: ReactNode }) {
  const user = useSession((s) => s.user);
  if (!user) return <Navigate to="/login" replace />;
  // Super Admin satisfies every role requirement (it sits above Admin).
  if (user.role !== "super_admin" && !roles.includes(user.role)) {
    return <Navigate to="/dashboard" replace />;
  }
  return <>{children}</>;
}
