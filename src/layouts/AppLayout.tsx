import { useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router-dom";
import {
  ChefHat,
  LogOut,
  Menu,
  Moon,
  Sun,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { useTheme } from "@/lib/theme";
import { navForRole } from "./nav";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { ROLE_LABELS } from "@/lib/data/types";
import { useDashboardBrand, brandBgClass, brandAccentText, brandActiveNav, brandWordmark } from "@/features/dashboard/brandTheme";
import { BrandFilter } from "@/features/dashboard/BrandFilter";

export function AppLayout() {
  const user = useSession((s) => s.user);
  const logout = useSession((s) => s.logout);
  const { dark, toggle } = useTheme();
  const navigate = useNavigate();
  const brand = useDashboardBrand((s) => s.brand);
  const setBrand = useDashboardBrand((s) => s.setBrand);
  const [mobileOpen, setMobileOpen] = useState(false);

  if (!user) return null;
  const items = navForRole(user.role);

  const handleLogout = () => {
    logout();
    navigate("/login");
  };

  const sidebar = (
    <div className="flex h-full flex-col">
      <div className={cn("flex h-14 items-center gap-2 border-b border-black/5 px-4", dark ? "" : brandAccentText(brand))}>
        <ChefHat className="h-6 w-6" />
        <span className="text-sm font-semibold leading-tight">Recipe Costing</span>
      </div>
      <nav className="flex-1 space-y-1 overflow-y-auto p-3">
        {items.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            onClick={() => setMobileOpen(false)}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                isActive
                  ? dark
                    ? "bg-accent text-accent-foreground"
                    : brandActiveNav(brand)
                  : "text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/10",
              )
            }
          >
            <item.icon className="h-4 w-4" />
            {item.label}
          </NavLink>
        ))}
      </nav>
      <div className="border-t border-black/5 p-3">
        <div className="mb-2 px-1">
          <p className="truncate text-sm font-medium">{user.name}</p>
          <Badge variant="outline" className="mt-1 border-black/15">
            {ROLE_LABELS[user.role]}
          </Badge>
        </div>
        <Button variant="ghost" className="w-full justify-start" onClick={handleLogout}>
          <LogOut className="h-4 w-4" />
          Sign out
        </Button>
      </div>
    </div>
  );

  return (
    <div
      className={cn(
        "flex h-screen",
        // Soft brand tint fills the screen in light mode; neutral in dark.
        dark ? "bg-background" : brandBgClass(brand),
      )}
    >
      {/* Desktop sidebar */}
      <aside
        className={cn(
          "hidden w-60 shrink-0 border-r md:block",
          dark ? "border-border bg-background" : "border-black/5 bg-white/50",
        )}
      >
        {sidebar}
      </aside>

      {/* Mobile drawer */}
      {mobileOpen && (
        <div className="fixed inset-0 z-50 md:hidden">
          <div className="absolute inset-0 bg-black/50" onClick={() => setMobileOpen(false)} />
          <aside
            className={cn(
              "absolute left-0 top-0 h-full w-64 shadow-lg",
              dark ? "bg-background" : "bg-white",
            )}
          >
            {sidebar}
          </aside>
        </div>
      )}

      <div className="flex flex-1 flex-col overflow-hidden">
        <header
          className={cn(
            "flex h-14 items-center justify-between border-b px-4",
            dark ? "border-border bg-background" : "border-black/5 bg-white/50",
          )}
        >
          <Button
            variant="ghost"
            size="icon"
            className="md:hidden"
            onClick={() => setMobileOpen((v) => !v)}
          >
            {mobileOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
          </Button>
          <div className="flex-1" />
          {user.role !== "viewer" && (
            <div className="mr-2 hidden sm:block">
              <BrandFilter value={brand} onChange={setBrand} />
            </div>
          )}
          <Button variant="ghost" size="icon" onClick={toggle} title="Toggle theme">
            {dark ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
          </Button>
        </header>
        <main className="relative flex-1 overflow-y-auto p-4 transition-colors sm:p-6">
          {/* Brand wordmark watermark behind the content — sized to fit the width */}
          {!dark && (
            <div
              aria-hidden
              className="pointer-events-none absolute inset-x-0 top-0 z-0 flex h-[70vh] items-center justify-center overflow-hidden"
            >
              <span
                className={cn("select-none whitespace-nowrap font-black leading-none tracking-tighter opacity-[0.05]", brandAccentText(brand))}
                style={{ fontSize: `${Math.min(22, 92 / brandWordmark[brand].length)}vw` }}
              >
                {brandWordmark[brand]}
              </span>
            </div>
          )}
          <div className="relative z-10 mx-auto max-w-7xl">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
