import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useSession } from "@/lib/auth/session";
import type { Role } from "@/lib/data/types";

/** Requires a logged-in user; otherwise redirect to login. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const user = useSession((s) => s.user);
  const location = useLocation();
  if (!user) {
    return <Navigate to="/login" replace state={{ from: location }} />;
  }
  return <>{children}</>;
}

/** Requires one of the given roles; otherwise bounce to the dashboard. */
export function RequireRole({ roles, children }: { roles: Role[]; children: ReactNode }) {
  const user = useSession((s) => s.user);
  if (!user) return <Navigate to="/login" replace />;
  if (!roles.includes(user.role)) {
    return <Navigate to="/dashboard" replace />;
  }
  return <>{children}</>;
}
