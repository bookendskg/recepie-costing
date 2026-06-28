import { Suspense, useEffect, useState } from "react";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router-dom";
import {
  ChefHat,
  Loader2,
  LogOut,
  Menu,
  Moon,
  PanelLeftClose,
  PanelLeftOpen,
  Search,
  Sun,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useSession } from "@/lib/auth/session";
import { useTheme } from "@/lib/theme";
import { usePrefs } from "@/lib/prefs";
import { navGroupsForRole } from "./nav";
import { Button } from "@/components/ui/button";
import { ROLE_LABELS } from "@/lib/data/types";
import { useDashboardBrand, applyBrand, brandBgClass, brandAccentText, brandWordmark } from "@/features/dashboard/brandTheme";
import { BrandFilter } from "@/features/dashboard/BrandFilter";
import { ProfileMenu } from "./HeaderControls";
import { CommandPalette, useCommandPalette } from "./CommandPalette";

export function AppLayout() {
  const user = useSession((s) => s.user);
  const logout = useSession((s) => s.logout);
  const { dark, toggle } = useTheme();
  const navigate = useNavigate();
  const brand = useDashboardBrand((s) => s.brand);
  const setBrand = useDashboardBrand((s) => s.setBrand);
  const [mobileOpen, setMobileOpen] = useState(false);
  const collapsed = usePrefs((s) => s.sidebarCollapsed);
  const toggleSidebar = usePrefs((s) => s.toggleSidebar);
  const location = useLocation();
  const palette = useCommandPalette();

  // Re-theme the whole app to the active brand (sets --primary/--accent/--ring).
  useEffect(() => {
    applyBrand(brand);
  }, [brand]);

  // On logout the shell unmounts — drop the brand class so the auth pages fall
  // back to the neutral BOOKENDS-blue base instead of a stale brand accent.
  useEffect(() => {
    return () => {
      document.documentElement.classList.remove("brand-all", "brand-capiche", "brand-aiko");
    };
  }, []);

  if (!user) return null;
  const groups = navGroupsForRole(user.role);

  const handleLogout = async () => {
    await logout();
    navigate("/login");
  };

  // `rail` collapses the desktop sidebar to icons only. The mobile drawer always
  // shows the full sidebar (rail=false).
  const sidebar = (rail: boolean) => (
    <div className="flex h-full flex-col">
      <div
        className={cn(
          "flex h-14 items-center gap-2 border-b border-black/5 px-4",
          dark ? "" : brandAccentText(brand),
          rail && "justify-center px-2",
        )}
      >
        <ChefHat className="h-6 w-6 shrink-0" />
        {!rail && <span className="text-sm font-semibold leading-tight">Recipe Costing</span>}
      </div>
      <nav className="flex-1 space-y-3 overflow-y-auto p-3">
        {groups.map(({ group, items }) => (
          <div key={group} className="space-y-1">
            {!rail && (
              <p className="px-3 pb-0.5 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground/70">
                {group}
              </p>
            )}
            {items.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                onClick={() => setMobileOpen(false)}
                title={rail ? item.label : undefined}
                className={({ isActive }) =>
                  cn(
                    "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                    rail && "justify-center px-2",
                    isActive
                      ? // Theme-aware active state: primary tint + left indicator, so the
                        // chosen theme (Capiche red / Aiko yellow / etc.) is always visible.
                        "border-l-2 border-primary bg-primary/10 font-semibold text-foreground"
                      : "border-l-2 border-transparent text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/10",
                  )
                }
              >
                <item.icon className="h-4 w-4 shrink-0" />
                {!rail && item.label}
              </NavLink>
            ))}
          </div>
        ))}
      </nav>
      {!rail && (
        <div className="border-t border-black/5 p-3">
          <div className="mb-2 px-1">
            <p className="truncate text-sm font-medium">{user.name}</p>
            <p className="text-xs text-muted-foreground">{ROLE_LABELS[user.role]}</p>
          </div>
          <Button variant="ghost" className="w-full justify-start" onClick={handleLogout}>
            <LogOut className="h-4 w-4" />
            Sign out
          </Button>
        </div>
      )}
    </div>
  );

  return (
    <div
      className={cn(
        "flex h-screen transition-colors duration-300",
        // Soft brand tint fills the screen in light mode; neutral in dark.
        dark ? "bg-background" : brandBgClass(brand),
      )}
    >
      {/* Desktop sidebar */}
      <aside
        className={cn(
          "hidden shrink-0 border-r transition-[width] duration-200 md:block",
          collapsed ? "w-16" : "w-60",
          dark ? "border-border bg-background" : "border-black/5 bg-white/50",
        )}
      >
        {sidebar(collapsed)}
      </aside>

      {/* Mobile drawer */}
      {mobileOpen && (
        <div className="fixed inset-0 z-50 md:hidden">
          <div
            className="absolute inset-0 animate-fade-in bg-black/50"
            onClick={() => setMobileOpen(false)}
          />
          <aside
            className={cn(
              "absolute left-0 top-0 flex h-full w-72 max-w-[85vw] animate-slide-in-left flex-col shadow-xl",
              dark ? "bg-background" : "bg-white",
            )}
          >
            <div className="shrink-0 border-b p-3">
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Brand</p>
              <BrandFilter value={brand} onChange={(b) => setBrand(b)} className="w-full" />
            </div>
            <div className="min-h-0 flex-1 overflow-y-auto">{sidebar(false)}</div>
          </aside>
        </div>
      )}

      <div className="flex flex-1 flex-col overflow-hidden">
        <header
          className={cn(
            "sticky top-0 z-30 flex h-14 items-center gap-1 border-b px-3 sm:px-4",
            dark ? "border-border bg-background" : "border-black/5 bg-white/70 backdrop-blur",
          )}
        >
          {/* Mobile: open drawer. Desktop: collapse rail. */}
          <Button
            variant="ghost"
            size="icon"
            className="md:hidden"
            onClick={() => setMobileOpen((v) => !v)}
            aria-label="Toggle navigation"
          >
            {mobileOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="hidden md:inline-flex"
            onClick={toggleSidebar}
            aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
          >
            {collapsed ? <PanelLeftOpen className="h-5 w-5" /> : <PanelLeftClose className="h-5 w-5" />}
          </Button>

          {/* Menu search trigger */}
          <button
            onClick={() => palette.setOpen(true)}
            className="ml-1 hidden items-center gap-2 rounded-md border bg-background/60 px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:bg-muted sm:flex"
          >
            <Search className="h-4 w-4" />
            <span>Search…</span>
            <kbd className="ml-2 rounded border bg-muted px-1.5 text-[10px] font-medium">⌘K</kbd>
          </button>
          <Button
            variant="ghost"
            size="icon"
            className="sm:hidden"
            onClick={() => palette.setOpen(true)}
            aria-label="Search menu"
          >
            <Search className="h-5 w-5" />
          </Button>

          <div className="flex-1" />

          {/* Mobile: brand chip (tap to open the drawer, which holds the selector). */}
          <button
            onClick={() => setMobileOpen(true)}
            className={cn(
              "mr-1 rounded-full border px-2.5 py-1 text-xs font-bold uppercase tracking-wide sm:hidden",
              brandAccentText(brand),
            )}
            aria-label={`Brand ${brandWordmark[brand]} — tap to change`}
          >
            {brandWordmark[brand]}
          </button>
          <div className="mr-1 hidden sm:block">
            <BrandFilter value={brand} onChange={setBrand} />
          </div>
          <Button variant="ghost" size="icon" onClick={toggle} title="Toggle light/dark" aria-label="Toggle light/dark">
            {dark ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
          </Button>
          <ProfileMenu />
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
          {/* Keyed on the route so each navigation replays the entrance animation. */}
          <div key={location.pathname} className="relative z-10 mx-auto max-w-7xl animate-fade-in-up">
            <Suspense
              fallback={
                <div className="flex items-center justify-center py-24 text-muted-foreground">
                  <Loader2 className="h-6 w-6 animate-spin" />
                </div>
              }
            >
              <Outlet />
            </Suspense>
          </div>
        </main>
      </div>

      <CommandPalette role={user.role} open={palette.open} onOpenChange={palette.setOpen} />
    </div>
  );
}
