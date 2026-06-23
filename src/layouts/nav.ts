import {
  LayoutDashboard,
  Beef,
  BookOpen,
  CheckCircle2,
  FileBarChart,
  Users,
  Settings,
  ScrollText,
  type LucideIcon,
} from "lucide-react";
import type { Role } from "@/lib/data/types";

export interface NavItem {
  to: string;
  label: string;
  icon: LucideIcon;
  roles: Role[];
}

export const NAV_ITEMS: NavItem[] = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard, roles: ["admin", "editor", "viewer"] },
  { to: "/materials", label: "Raw Materials", icon: Beef, roles: ["admin", "editor"] },
  { to: "/recipes", label: "Recipes", icon: BookOpen, roles: ["admin", "editor", "viewer"] },
  { to: "/approvals", label: "Approvals", icon: CheckCircle2, roles: ["admin"] },
  { to: "/reports", label: "Reports", icon: FileBarChart, roles: ["admin", "editor"] },
  { to: "/users", label: "Users", icon: Users, roles: ["admin"] },
  { to: "/audit", label: "Audit Log", icon: ScrollText, roles: ["admin"] },
  { to: "/settings", label: "Settings", icon: Settings, roles: ["admin"] },
];

export function navForRole(role: Role): NavItem[] {
  return NAV_ITEMS.filter((item) => item.roles.includes(role));
}
