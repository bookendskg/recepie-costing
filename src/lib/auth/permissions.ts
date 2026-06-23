// Client-side permission layer mirroring the PRD §7.2 matrix, §7.3 viewer
// sub-types, and §14.2 view-mode data visibility. This maps 1:1 to the
// Postgres RLS policies (PRD §9.3) authored in db/migrations — when Supabase
// is added these checks are backed by RLS, not replaced.

import type { Recipe, Role, User, ViewType } from "../data/types";

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
    "settings.manage",
    "report.excel",
    "audit.view",
  ],
  editor: [
    "material.view",
    "material.edit",
    "recipe.create",
    "recipe.duplicate",
    "recipe.submit",
    "recipe.viewAll",
    "report.excel",
  ],
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
  if (role === "admin" || role === "editor") return AIKO;
  if (viewType === "capiche") return CAPICHE;
  if (viewType === "aiko") return AIKO;
  return CAPICHE; // safest default for an unassigned viewer
}

export const HOME_BY_ROLE: Record<Role, string> = {
  admin: "/dashboard",
  editor: "/dashboard",
  viewer: "/dashboard",
};
