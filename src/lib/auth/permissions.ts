// Client-side permission layer mirroring the PRD §7.2 matrix, §7.3 viewer
// sub-types, and §14.2 view-mode data visibility. This maps 1:1 to the
// Postgres RLS policies (PRD §9.3) authored in db/migrations — when Supabase
// is added these checks are backed by RLS, not replaced.

import { BRANDS, type Brand, type Recipe, type Role, type User, type ViewType } from "../data/types";

const ALL_BRANDS: Brand[] = BRANDS.map((b) => b.value);

export type Capability =
  // user management
  | "user.manage"
  // raw materials
  | "material.view"
  | "material.edit"
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
  editor: [
    // Ingredients are read-only for editors — only an admin changes them.
    "material.view",
    "recipe.create",
    "recipe.duplicate",
    "recipe.submit",
    "recipe.viewAll",
    "viewer.assign",
    "report.excel",
  ],
  // Head Chef: views everything (recipes, sub-recipes, costs) but can't change
  // prices/recipes; can grant sharing permissions to others.
  head_chef: [
    "material.view",
    "recipe.viewAll",
    "viewer.assign",
    "report.excel",
  ],
  // Chef: view-only.
  chef: ["material.view", "recipe.viewAll"],
  viewer: [],
};

export function can(role: Role | undefined, cap: Capability): boolean {
  if (!role) return false;
  return MATRIX[role].includes(cap);
}

/** Can this user edit this specific recipe? Creator or admin (PRD §3.6). */
export function canEditRecipe(user: User | null, recipe: Recipe): boolean {
  if (!user) return false;
  if (user.role === "admin") return true;
  if (user.role === "editor") return recipe.created_by === user.id;
  return false;
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
  // All staff roles (admin, editor, head chef, chef) see full costing.
  if (role !== "viewer") return AIKO;
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

/** A viewer can see a recipe if it's approved and in one of their brands. */
export function viewerCanAccess(user: User | null, recipe: Recipe): boolean {
  if (!user || user.role !== "viewer") return false;
  return recipe.status === "approved" && viewerBrands(user).includes(recipe.brand);
}

/** Visibility for any user: admin/editor see all; viewers per their show_cost grant. */
export function visibilityForUser(user: User): ViewVisibility {
  if (user.role !== "viewer") return visibilityFor(user.role, null);
  return visibilityFor("viewer", viewerShowCost(user) ? "aiko" : "capiche");
}

export const HOME_BY_ROLE: Record<Role, string> = {
  admin: "/dashboard",
  editor: "/dashboard",
  head_chef: "/dashboard",
  chef: "/dashboard",
  viewer: "/dashboard",
};
