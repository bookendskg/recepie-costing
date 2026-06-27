import { MasterCostingDashboard } from "./MasterCostingDashboard";
import { useDashboardBrand } from "./brandTheme";

// Every role sees the same brand-themed Master Costing dashboard. The brand
// toggle in the header re-scopes it: BOOKENDS = both restaurants, Capiche =
// Capiche only, Aiko = Aiko only.
export function DashboardPage() {
  const brand = useDashboardBrand((s) => s.brand);
  return <MasterCostingDashboard brand={brand} />;
}
