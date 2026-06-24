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
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard, roles: ["admin", "editor", "head_chef", "chef", "viewer"] },
  { to: "/materials", label: "Raw Materials", icon: Beef, roles: ["admin", "editor", "head_chef", "chef"] },
  { to: "/recipes", label: "Recipes", icon: BookOpen, roles: ["admin", "editor", "head_chef", "chef", "viewer"] },
  { to: "/prep", label: "In-House Prep", icon: ChefHat, roles: ["admin", "editor", "head_chef", "chef"] },
  { to: "/approvals", label: "Approvals", icon: CheckCircle2, roles: ["admin"] },
  { to: "/reports", label: "Reports", icon: FileBarChart, roles: ["admin", "editor", "head_chef"] },
  { to: "/viewer-access", label: "Viewer Access", icon: Eye, roles: ["admin", "editor", "head_chef"] },
  { to: "/users", label: "Users", icon: Users, roles: ["admin"] },
  { to: "/audit", label: "Price Changes", icon: ScrollText, roles: ["admin"] },
  { to: "/settings", label: "Settings", icon: Settings, roles: ["admin"] },
];

export function navForRole(role: Role): NavItem[] {
  return NAV_ITEMS.filter((item) => item.roles.includes(role));
}
