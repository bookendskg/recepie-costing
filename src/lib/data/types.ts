// Domain types mirroring PRD §9.2 table specifications.
// These map 1:1 to the Postgres schema authored in db/migrations.

export type Role = "admin" | "editor" | "viewer";
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

export interface User {
  id: string;
  name: string;
  email: string;
  role: Role;
  status: UserStatus;
  /** Mock-only: plaintext password for the local auth simulation. */
  password?: string;
  created_at: string;
  updated_at: string;
}

export interface RawMaterial {
  id: string;
  ingredient_name: string;
  category: string;
  supplier_name: string | null;
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
  /** Recipe photo as a data URL (mock) or external URL. */
  image_url: string | null;
  preparation_time: number | null;
  serving_size: number;
  status: RecipeStatus;
  total_cost: number | null;
  cost_per_portion: number | null;
  /** Actual menu price set by the chef. Null → use the suggested price. */
  selling_price: number | null;
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

/** A recipe ingredient joined with its raw material or sub-recipe, for the UI. */
export interface RecipeIngredientWithMaterial extends RecipeIngredient {
  material: RawMaterial | null;
  /** Set when component_type === 'recipe' — the referenced prep recipe. */
  subRecipe: Recipe | null;
}
