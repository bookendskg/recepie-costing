import { useSession } from "@/lib/auth/session";
import { AdminDashboard } from "./AdminDashboard";
import { EditorDashboard } from "./EditorDashboard";
import { ViewerDashboard } from "./ViewerDashboard";

export function DashboardPage() {
  const user = useSession((s) => s.user);
  if (!user) return null;
  if (user.role === "editor") return <EditorDashboard />;
  if (user.role === "viewer") return <ViewerDashboard />;
  // Admin, Head Chef, and Chef all see the full Kitchen Operations overview.
  return <AdminDashboard />;
}
