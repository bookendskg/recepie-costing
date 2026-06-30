// localStorage-backed mock database. Simulates async latency so React Query
// behaves identically to a real Supabase backend. Swapped out wholesale when
// the Supabase repos are added — UI/feature code never imports this directly.

import type {
  AuditLog,
  IngredientPriceHistory,
  IngredientYield,
  RawMaterial,
  Recipe,
  RecipeCostHistory,
  RecipeIngredient,
  RecipeVersion,
  SystemSetting,
  User,
  UserRecipeView,
  WastageEntry,
} from "../types";
import { buildSeed } from "../seed";

export interface MockDb {
  users: User[];
  raw_materials: RawMaterial[];
  recipes: Recipe[];
  recipe_ingredients: RecipeIngredient[];
  recipe_cost_history: RecipeCostHistory[];
  ingredient_price_history: IngredientPriceHistory[];
  ingredient_yields: IngredientYield[];
  wastage_entries: WastageEntry[];
  recipe_versions: RecipeVersion[];
  user_recipe_views: UserRecipeView[];
  audit_logs: AuditLog[];
  system_settings: SystemSetting[];
}

// Bump this when the seed/DB shape changes so stale localStorage data is reseeded.
const STORAGE_KEY = "rcms.mockdb.v35";

let cache: MockDb | null = null;

function load(): MockDb {
  if (cache) return cache;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      cache = JSON.parse(raw) as MockDb;
      return cache;
    }
  } catch {
    // fall through to seed
  }
  cache = buildSeed();
  persist();
  return cache;
}

function persist() {
  if (!cache) return;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cache));
  } catch {
    // ignore quota / serialization errors in the mock layer
  }
}

/** Reset the mock DB back to seed data (used by tests / a dev "reset" button). */
export function resetDb() {
  cache = buildSeed();
  persist();
}

/** Read-only accessor to the in-memory DB. */
export function getDb(): MockDb {
  return load();
}

/** Mutate the DB then persist. Returns the mutation's result. */
export function mutate<T>(fn: (db: MockDb) => T): T {
  const db = load();
  const result = fn(db);
  persist();
  return result;
}

/** Simulated network latency (ms). */
const LATENCY = 80;

export function delay<T>(value: T): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), LATENCY));
}

export function uid(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `id-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
}

export function nowISO(): string {
  return new Date().toISOString();
}

export function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}
