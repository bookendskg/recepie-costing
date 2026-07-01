// Domain types mirroring PRD §9.2 table specifications.
// These map 1:1 to the Postgres schema authored in db/migrations.

export type Role = "super_admin" | "admin" | "editor" | "head_chef" | "chef" | "viewer";

export const ROLE_LABELS: Record<Role, string> = {
  super_admin: "Super Admin",
  admin: "Admin",
  editor: "Editor",
  head_chef: "Head Chef",
  chef: "Chef",
  viewer: "Viewer",
};
export type UserStatus = "active" | "inactive";
export type RecipeStatus = "draft" | "testing" | "approved" | "rejected";
/** Restaurant brands a recipe can belong to (PRD multi-brand operations). */
export type Brand = "capiche" | "aiko";
export const BRANDS: { value: Brand; label: string }[] = [
  { value: "capiche", label: "Capiche" },
  { value: "aiko", label: "Aiko" },
];
export type MaterialStatus = "active" | "inactive";
export type ViewType = "capiche" | "aiko";

/** A restaurant outlet under a brand (§12). Centralized constants — never store
 *  ad-hoc spellings of the same outlet. */
export interface Outlet {
  id: string;
  brand: Brand;
  name: string;
}
export const OUTLETS: Outlet[] = [
  { id: "capiche-piplod", brand: "capiche", name: "Capiche Piplod" },
  { id: "capiche-vesu", brand: "capiche", name: "Capiche Vesu" },
  { id: "capiche-ambli", brand: "capiche", name: "Capiche Ambli" },
  { id: "capiche-university", brand: "capiche", name: "Capiche University" },
  { id: "aiko-pal", brand: "aiko", name: "Aiko Pal" },
  { id: "aiko-ambli", brand: "aiko", name: "Aiko Ambli" },
];
export const outletById = (id: string): Outlet | undefined => OUTLETS.find((o) => o.id === id);
export const outletsForBrand = (brand: Brand): Outlet[] => OUTLETS.filter((o) => o.brand === brand);

/** Operational wastage taxonomy (§13). */
export const WASTAGE_TYPES = [
  "Raw Material Wastage",
  "Preparation Wastage",
  "Cooking Wastage",
  "Spoilage",
  "Expired Stock",
  "Overproduction",
  "Returned Food",
  "Incorrect Preparation",
  "Damaged Stock",
  "Quality Rejection",
  "Other",
] as const;
export type WastageType = (typeof WASTAGE_TYPES)[number];

export const DEPARTMENTS = [
  "Kitchen Staff",
  "Service Staff",
  "Other",
] as const;
export type Department = (typeof DEPARTMENTS)[number];

/** A recorded operational wastage event at an outlet (§11–§14). Separate from
 *  the Yield Management master data. */
export interface WastageEntry {
  id: string;
  wastage_date: string;
  brand: Brand;
  outlet_id: string;
  wastage_type: WastageType;
  /** Whether a raw ingredient or a finished recipe was wasted. */
  item_type: "ingredient" | "recipe";
  ingredient_id: string | null;
  recipe_id: string | null;
  quantity: number;
  unit: string;
  unit_cost: number;
  total_cost: number;
  reason: string | null;
  department: Department;
  shift: string | null;
  /** Free-text name of the person who caused/handled the wastage. */
  done_by: string | null;
  entered_by: string | null;
  approved_by: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface User {
  id: string;
  name: string;
  email: string;
  role: Role;
  status: UserStatus;
  /** Mock-only: plaintext password for the local auth simulation. */
  password?: string;
  /** Optional contact number shown on the profile. */
  phone?: string | null;
  /** Avatar image as a data URL (mock) or external URL. */
  avatar_url?: string | null;
  /** Whether the user's email is verified (mirrored from Supabase auth on sign-in). */
  email_verified?: boolean;
  /** Brand assignment for Outlet Manager / Staff. */
  assigned_brand?: Brand | null;
  /** Outlet assignment (outlet id) for Outlet Manager / Staff. */
  assigned_outlet?: string | null;
  /** Last successful sign-in timestamp (set by the auth layer). */
  last_login?: string | null;
  /** When the role was last changed + who changed it (role history). */
  last_role_update?: string | null;
  role_updated_by?: string | null;
  /** Saved UI theme preference ('light' | 'dark' | 'capiche' | 'aiko'). */
  theme_pref?: string | null;
  /** Viewer-only: which brands' approved recipes this viewer can see. */
  accessible_brands?: Brand[];
  /** Viewer-only: whether this viewer sees costs/pricing (else Capiche-style). */
  show_cost?: boolean;
  /** Whether this user sees the Master Costing dashboard (cost stats). Admins
   *  always do; other roles only when an admin grants it. */
  dashboard_access?: boolean;
  /** Self sign-ups start unapproved (false) and can't enter the app until an
   *  admin verifies them. Owners/admin-created/seed users are approved. A missing
   *  value means approved (legacy/seed users). */
  approved?: boolean;
  created_at: string;
  updated_at: string;
}

export interface RawMaterial {
  id: string;
  ingredient_name: string;
  category: string;
  supplier_name: string | null;
  /** Free-text note about the ingredient (storage, brand, prep, etc.). */
  notes: string | null;
  purchase_price: number | null;
  purchase_quantity: number;
  purchase_unit: string;
  base_unit: string;
  /** Generated: purchase_price / (purchase_quantity × conversion). Null if no price. */
  cost_per_base_unit: number | null;
  last_price_update: string | null;
  status: MaterialStatus;
  created_by: string | null;
  created_at: string;
}

export interface Recipe {
  id: string;
  recipe_name: string;
  category: string;
  brand: Brand;
  description: string | null;
  /** Ordered preparation/cooking steps (from the cookbook METHOD section). */
  method: string[];
  /** Pizza size variants (§14–§20): a variant points at its master recipe; the
   *  master itself is the primary (15-inch) and is the only row shown in lists. */
  parent_recipe_id?: string | null;
  size_code?: "11_INCH" | "15_INCH" | null;
  size_label?: string | null;
  /** Recipe photo as a data URL (mock) or external URL. */
  image_url: string | null;
  preparation_time: number | null;
  serving_size: number;
  status: RecipeStatus;
  total_cost: number | null;
  cost_per_portion: number | null;
  /** Actual menu price set by the chef. Null → use the suggested price. */
  selling_price: number | null;
  /** Per-portion packaging cost (box/container), added on top of food cost. */
  packaging_cost: number;
  /** Wastage % added on top of the raw ingredient cost (PRD / sheet "Wastage"). */
  wastage_pct: number;
  /** True for in-house prep recipes (sauces, doughs, pastes) used as components. */
  is_prep: boolean;
  /** Batch output used to derive a prep's per-unit cost (defaults to sum of grams). */
  yield_quantity: number;
  yield_unit: string;
  created_by: string | null;
  approved_by: string | null;
  approved_at: string | null;
  rejection_note: string | null;
  version_no: number;
  created_at: string;
  updated_at: string;
  updated_by: string | null;
}

/** A recipe line is either a raw material or another (prep) recipe. */
export type ComponentType = "material" | "recipe";

export interface RecipeIngredient {
  id: string;
  recipe_id: string;
  /** Points at a raw_material (component_type 'material') or a recipe ('recipe'). */
  ingredient_id: string;
  component_type: ComponentType;
  quantity_used: number;
  unit_used: string;
  calculated_cost: number | null;
  sort_order: number;
  /** Recipe-specific wastage % override (§10). Null → use the ingredient's standard yield. */
  wastage_override_pct?: number | null;
  /** Selected cut/prep variant for a vegetable (e.g. "Sliced", "Diced"). Its yield
   *  drives the yield-adjusted cost; null → use the ingredient as-is. */
  cut_type?: string | null;
}

export interface RecipeCostHistory {
  id: string;
  recipe_id: string;
  old_total_cost: number | null;
  new_total_cost: number | null;
  old_cost_per_portion: number | null;
  new_cost_per_portion: number | null;
  change_reason: string | null;
  changed_by: string | null;
  changed_at: string;
}

/**
 * Standard yield (preparation-loss) data for an ingredient. The full purchase
 * cost is distributed across the USABLE quantity, giving the effective rate.
 */
export interface IngredientYield {
  id: string;
  ingredient_id: string;
  purchase_cost: number;
  purchase_quantity: number;
  purchase_unit: string;
  /** Raw quantity expressed in the base unit (Gram/ML/piece). */
  raw_quantity: number;
  raw_unit: string;
  wastage_quantity: number;
  wastage_unit: string;
  usable_quantity: number;
  wastage_percentage: number;
  yield_percentage: number;
  /** Per base unit. */
  original_unit_cost: number;
  /** Per base unit, distributing full cost over the usable quantity. */
  yield_adjusted_unit_cost: number;
  effective_from: string;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
}

export interface IngredientPriceHistory {
  id: string;
  ingredient_id: string;
  old_price: number | null;
  new_price: number | null;
  old_cost_per_base_unit: number | null;
  new_cost_per_base_unit: number | null;
  changed_by: string | null;
  changed_at: string;
}

export interface RecipeVersion {
  id: string;
  recipe_id: string;
  version_no: number;
  snapshot: unknown;
  notes: string | null;
  created_by: string | null;
  created_at: string;
}

export interface UserRecipeView {
  id: string;
  user_id: string;
  recipe_id: string;
  view_type: ViewType;
  assigned_by: string | null;
  assigned_at: string;
}

export type AuditEntityType = "recipe" | "ingredient" | "user";
export type AuditAction = "create" | "update" | "delete" | "approve" | "reject" | "submit";

export interface AuditLog {
  id: string;
  entity_type: AuditEntityType;
  entity_id: string;
  action: AuditAction;
  old_values: unknown | null;
  new_values: unknown | null;
  performed_by: string | null;
  performed_at: string;
  notes: string | null;
}

export interface SystemSetting {
  id: string;
  key: string;
  value: string;
  updated_by: string | null;
  updated_at: string;
}

export type ExportFormat = "pdf" | "csv" | "xlsx";
export type ExportEntityType = "recipe" | "report";
export type ExportStatus = "success" | "failed";

/** §14 Controlled access types for a shared recipe link (no free-text). */
export type AccessType = "READ_ONLY" | "DOWNLOAD_PDF" | "VIEW_AND_DOWNLOAD";
export type AccessLinkStatus = "ACTIVE" | "EXPIRED" | "REVOKED";

/** §15 A temporary, read-only recipe share link. The raw token is never stored —
 *  only its hash — and expiry/revocation are checked when the token is resolved. */
export interface RecipeAccessLink {
  id: string;
  token_hash: string;
  recipe_id: string;
  granted_by_user_id: string | null;
  granted_by_name: string;
  granted_by_role: Role;
  granted_to_user_id: string | null;
  granted_to_email: string | null;
  granted_to_role: Role | null;
  granted_to_brand_id: Brand | null;
  granted_to_outlet_id: string | null;
  access_type: AccessType;
  created_at: string;
  expires_at: string;
  revoked_at: string | null;
  revoked_by_user_id: string | null;
  last_accessed_at: string | null;
  access_count: number;
  status: AccessLinkStatus;
}

/** §9 One audit row per successful export. Exporter identity + timestamp are
 *  snapshotted from the authenticated session at export time (never user-typed). */
export interface ExportHistory {
  id: string;
  exported_by_user_id: string | null;
  exporter_name_snapshot: string;
  exporter_email_snapshot: string | null;
  exporter_role_snapshot: Role;
  export_type: string; // e.g. "single_recipe", "recipe_report"
  entity_type: ExportEntityType;
  entity_id: string | null;
  recipe_name_snapshot: string | null;
  report_name: string | null;
  brand_id: Brand | null;
  outlet_id: string | null;
  filters_used: string | null;
  file_format: ExportFormat;
  exported_at: string; // UTC ISO
  timezone: string; // e.g. "Asia/Kolkata"
  status: ExportStatus;
}

/** A recipe ingredient joined with its raw material or sub-recipe, for the UI. */
export interface RecipeIngredientWithMaterial extends RecipeIngredient {
  material: RawMaterial | null;
  /** Set when component_type === 'recipe' — the referenced prep recipe. */
  subRecipe: Recipe | null;
}
