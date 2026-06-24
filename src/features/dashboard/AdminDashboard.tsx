import { useDashboardBrand } from "./brandTheme";
import { OperationsDashboard } from "./OperationsDashboard";

// Admin / Head Chef / Chef see the brand-themed Operations Dashboard. The brand
// toggle in the header switches the accent: BOOKENDS blue, Capiche red, Aiko gold.
export function AdminDashboard() {
  const brand = useDashboardBrand((s) => s.brand);
  return <OperationsDashboard brand={brand} />;
}
