// Client-side permission layer mirroring the PRD §7.2 matrix, §7.3 viewer
// sub-types, and §14.2 view-mode data visibility. This maps 1:1 to the
// Postgres RLS policies (PRD §9.3) authored in db/migrations — when Supabase
// is added these checks are backed by RLS, not replaced.

import {
  BRANDS,
  OUTLETS,
  type Brand,
  type Outlet,
  type Recipe,
  type Role,
  type User,
  type ViewType,
} from "../data/types";

const ALL_BRANDS: Brand[] = BRANDS.map((b) => b.value);

export type Capability =
  // user management
  | "user.manage"
  // raw materials
  | "material.view"
  | "material.edit"
  // yield management (R&D)
  | "yield.manage"
  // operational wastage
  | "wastage.create"
  // recipes
  | "recipe.create"
  | "recipe.editAll"
  | "recipe.delete"
  | "recipe.duplicate"
  | "recipe.submit"
  // approval
  | "recipe.approve"
  // viewing
  | "recipe.viewAll"
  // viewer access management
  | "viewer.assign"
  // settings
  | "settings.manage"
  // reports
  | "report.excel"
  | "audit.view";

const MATRIX: Record<Role, Capability[]> = {
  admin: [
    "user.manage",
    "material.view",
    "material.edit",
    "yield.manage",
    "wastage.create",
    "recipe.create",
    "recipe.editAll",
    "recipe.delete",
    "recipe.duplicate",
    "recipe.submit",
    "recipe.approve",
    "recipe.viewAll",
    "viewer.assign",
    "settings.manage",
    "report.excel",
    "audit.view",
  ],
  // Editor: manages recipes, raw materials, pricing, yield, wastage; imports data.
  editor: [
    "material.view",
    "material.edit",
    "yield.manage",
    "wastage.create",
    "recipe.create",
    "recipe.editAll",
    "recipe.duplicate",
    "recipe.submit",
    "recipe.viewAll",
    "viewer.assign",
    "report.excel",
  ],
  // Head Chef: edits + sees everything, records wastage, and can grant chefs/viewers
  // recipe-view access — but does not change ingredient prices (admin/editor only).
  head_chef: [
    "material.view",
    "yield.manage",
    "wastage.create",
    "recipe.create",
    "recipe.editAll",
    "recipe.duplicate",
    "recipe.submit",
    "recipe.viewAll",
    "viewer.assign",
    "report.excel",
  ],
  // Chef: read-only, same as a Viewer.
  chef: [],
  viewer: [],
};

export function can(role: Role | undefined, cap: Capability): boolean {
  if (!role) return false;
  return MATRIX[role].includes(cap);
}

/** Roles that are read-only (treated like a Viewer everywhere). */
export function isReadOnlyRole(role: Role | undefined): boolean {
  return role === "viewer" || role === "chef";
}

/** Can this user edit this specific recipe? Admin/Editor/Head Chef, else the creator. */
export function canEditRecipe(user: User | null, recipe: Recipe): boolean {
  if (!user) return false;
  if (user.role === "admin" || user.role === "editor" || user.role === "head_chef") return true;
  return recipe.created_by === user.id;
}

// --- Viewer view-mode visibility (PRD §14.2) ------------------------------
export interface ViewVisibility {
  ingredients: boolean;
  process: boolean;
  quantities: boolean;
  unitCosts: boolean;
  totalCost: boolean;
  costPerPortion: boolean;
  sellingPrice: boolean;
  grossProfit: boolean;
}

const CAPICHE: ViewVisibility = {
  ingredients: true,
  process: true,
  quantities: true,
  unitCosts: false,
  totalCost: false,
  costPerPortion: false,
  sellingPrice: false,
  grossProfit: false,
};

const AIKO: ViewVisibility = {
  ingredients: true,
  process: true,
  quantities: true,
  unitCosts: true,
  totalCost: true,
  costPerPortion: true,
  sellingPrice: true,
  grossProfit: true,
};

/**
 * Visibility for a given audience. Admin/editor see everything; viewers see
 * according to their assigned view_type for the recipe.
 */
export function visibilityFor(
  role: Role,
  viewType: ViewType | null,
): ViewVisibility {
  // Admin/Editor/Head Chef see full costing; Viewer + Chef are restricted.
  if (!isReadOnlyRole(role)) return AIKO;
  if (viewType === "capiche") return CAPICHE;
  if (viewType === "aiko") return AIKO;
  return CAPICHE; // safest default for an unassigned viewer
}

/**
 * Brands a viewer can see. Default (unset) is EVERYTHING — a viewer gets full
 * access until an editor/admin restricts them to specific brands.
 */
export function viewerBrands(user: User | null): Brand[] {
  return user?.accessible_brands ?? ALL_BRANDS;
}

/** Viewers see costs by default; an editor/admin can turn this off. */
export function viewerShowCost(user: User | null): boolean {
  return user?.show_cost ?? true;
}

/** A viewer/chef can see a recipe if it's approved and in one of their brands. */
export function viewerCanAccess(user: User | null, recipe: Recipe): boolean {
  if (!user || !isReadOnlyRole(user.role)) return false;
  return recipe.status === "approved" && viewerBrands(user).includes(recipe.brand);
}

/** Visibility for any user: staff roles see all; viewer/chef per their show_cost grant. */
export function visibilityForUser(user: User): ViewVisibility {
  if (!isReadOnlyRole(user.role)) return visibilityFor(user.role, null);
  return visibilityFor("viewer", viewerShowCost(user) ? "aiko" : "capiche");
}

/**
 * Whether the user sees the Master Costing dashboard (food/packaging/selling/FC%
 * stats). Admins always do; any other role only when an admin grants
 * `dashboard_access`. Everyone else gets the plain overview dashboard.
 */
export function canViewMasterDashboard(user: User | null): boolean {
  if (!user) return false;
  return user.role === "admin" || user.dashboard_access === true;
}

/**
 * A self sign-up that an admin hasn't verified yet. Such users are authenticated
 * but blocked from the app (shown the pending-approval screen). Admins are never
 * pending. A missing `approved` value means approved (legacy/seed users).
 */
export function isPendingApproval(user: User | null): boolean {
  if (!user) return false;
  return user.approved === false && user.role !== "admin";
}

// --- Brand / outlet scope ------------------------------------------------
// Admin / Editor / Head Chef operate across everything; Viewer + Chef follow their
// accessible_brands grant.

/** Brands a user may act within (for scoping selectors + data). */
export function userBrands(user: User | null): Brand[] {
  if (!user) return [];
  if (isReadOnlyRole(user.role)) return user.accessible_brands ?? ALL_BRANDS;
  return ALL_BRANDS; // admin, editor, head_chef
}

/** Outlets a user may act within (all for staff roles; brand-scoped for viewer/chef). */
export function accessibleOutlets(user: User | null): Outlet[] {
  if (!user) return [];
  const brands = userBrands(user);
  return OUTLETS.filter((o) => brands.includes(o.brand));
}

export function canAccessOutlet(user: User | null, outletId: string): boolean {
  return accessibleOutlets(user).some((o) => o.id === outletId);
}

export function canAccessBrand(user: User | null, brand: Brand): boolean {
  return userBrands(user).includes(brand);
}

export const HOME_BY_ROLE: Record<Role, string> = {
  admin: "/dashboard",
  editor: "/dashboard",
  head_chef: "/dashboard",
  chef: "/dashboard",
  viewer: "/dashboard",
};
