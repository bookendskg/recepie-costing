import { MasterCostingDashboard } from "./MasterCostingDashboard";
import { SimpleDashboard } from "./SimpleDashboard";
import { useDashboardBrand } from "./brandTheme";
import { useSession } from "@/lib/auth/session";
import { canViewMasterDashboard } from "@/lib/auth/permissions";

// Admins (and anyone an admin grants dashboard access) see the brand-themed
// Master Costing dashboard with full cost stats. Everyone else — viewers and
// users without access — sees the plain overview dashboard (no cost figures).
// The header brand toggle re-scopes either view: BOOKENDS = both, Capiche/Aiko = one.
export function DashboardPage() {
  const brand = useDashboardBrand((s) => s.brand);
  const user = useSession((s) => s.user);
  return canViewMasterDashboard(user) ? (
    <MasterCostingDashboard brand={brand} />
  ) : (
    <SimpleDashboard brand={brand} />
  );
}
