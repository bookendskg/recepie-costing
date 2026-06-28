import {
  LayoutDashboard,
  Beef,
  BookOpen,
  CheckCircle2,
  FileBarChart,
  Users,
  Settings,
  ScrollText,
  ChefHat,
  Eye,
  Sprout,
  Trash2,
  type LucideIcon,
} from "lucide-react";
import type { Role } from "@/lib/data/types";

/** Sidebar section a nav item belongs to (rendered as a labelled group). */
export type NavGroup = "Overview" | "Catalog" | "Operations" | "Admin";

export const NAV_GROUP_ORDER: NavGroup[] = ["Overview", "Catalog", "Operations", "Admin"];

export interface NavItem {
  to: string;
  label: string;
  icon: LucideIcon;
  roles: Role[];
  group: NavGroup;
}

export const NAV_ITEMS: NavItem[] = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard, group: "Overview", roles: ["admin", "editor", "head_chef", "chef", "viewer"] },
  { to: "/materials", label: "Raw Materials", icon: Beef, group: "Catalog", roles: ["admin", "editor", "head_chef"] },
  { to: "/recipes", label: "Recipes", icon: BookOpen, group: "Catalog", roles: ["admin", "editor", "head_chef", "chef", "viewer"] },
  { to: "/prep", label: "In-House Prep", icon: ChefHat, group: "Catalog", roles: ["admin", "editor", "head_chef"] },
  { to: "/yield", label: "Yield Management", icon: Sprout, group: "Catalog", roles: ["admin", "editor", "head_chef"] },
  { to: "/wastage", label: "Wastage Management", icon: Trash2, group: "Operations", roles: ["admin", "editor", "head_chef"] },
  { to: "/approvals", label: "Approvals", icon: CheckCircle2, group: "Operations", roles: ["admin"] },
  { to: "/reports", label: "Reports", icon: FileBarChart, group: "Operations", roles: ["admin", "editor", "head_chef"] },
  { to: "/viewer-access", label: "Viewer Access", icon: Eye, group: "Operations", roles: ["admin", "editor", "head_chef"] },
  { to: "/users", label: "User Management", icon: Users, group: "Admin", roles: ["admin"] },
  { to: "/audit", label: "Price Changes", icon: ScrollText, group: "Admin", roles: ["admin"] },
  { to: "/settings", label: "Settings", icon: Settings, group: "Admin", roles: ["admin"] },
];

export function navForRole(role: Role): NavItem[] {
  return NAV_ITEMS.filter((item) => item.roles.includes(role));
}

/** Nav items for a role, bucketed into their groups in display order. */
export function navGroupsForRole(role: Role): { group: NavGroup; items: NavItem[] }[] {
  const items = navForRole(role);
  return NAV_GROUP_ORDER.map((group) => ({
    group,
    items: items.filter((i) => i.group === group),
  })).filter((g) => g.items.length > 0);
}
