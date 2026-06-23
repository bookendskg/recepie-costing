import { useSession } from "@/lib/auth/session";
import { AdminDashboard } from "./AdminDashboard";
import { EditorDashboard } from "./EditorDashboard";
import { ViewerDashboard } from "./ViewerDashboard";

export function DashboardPage() {
  const user = useSession((s) => s.user);
  if (!user) return null;
  if (user.role === "admin") return <AdminDashboard />;
  if (user.role === "editor") return <EditorDashboard />;
  return <ViewerDashboard />;
}
