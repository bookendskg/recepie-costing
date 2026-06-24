// Seed data for the mock backend. Mirrors the PRD's worked examples so the
// app boots with believable data and the Chicken Alfredo recipe reproduces the
// §4.4 costing numbers live.

import { calculateCostPerBaseUnit, calculateIngredientCost } from "../costing";
import type { MockDb } from "./mock/db";
import type { RawMaterial, Recipe, RecipeIngredient, User } from "./types";

const SEED_TS = "2026-06-01T09:00:00.000Z";

// --- Users -----------------------------------------------------------------
const U_ADMIN = "u-admin";
const U_EDITOR = "u-editor";
const U_VIEWER = "u-viewer";

const users: User[] = [
  {
    id: U_ADMIN,
    name: "Rahul Sharma",
    email: "rahul@brand.com",
    role: "admin",
    status: "active",
    password: "password123",
    created_at: SEED_TS,
    updated_at: SEED_TS,
  },
  {
    id: U_EDITOR,
    name: "Priya Patel",
    email: "priya@brand.com",
    role: "editor",
    status: "active",
    password: "password123",
    created_at: SEED_TS,
    updated_at: SEED_TS,
  },
  {
    id: U_VIEWER,
    name: "Amit Roy",
    email: "amit@brand.com",
    role: "viewer",
    status: "active",
    password: "password123",
    created_at: SEED_TS,
    updated_at: SEED_TS,
  },
];

// --- Raw materials ---------------------------------------------------------
interface MatSeed {
  id: string;
  name: string;
  category: string;
  supplier: string | null;
  price: number | null;
  qty: number;
  pUnit: string;
  bUnit: string;
}

const matSeeds: MatSeed[] = [
  { id: "m-chicken", name: "Chicken", category: "Protein", supplier: "ABC Ltd", price: 250, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-pasta", name: "Pasta", category: "Grains & Flour", supplier: "Italia Foods", price: 180, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-cream", name: "Cream", category: "Dairy", supplier: "Fresh Co", price: 120, qty: 1, pUnit: "Litre", bUnit: "ML" },
  { id: "m-butter", name: "Butter", category: "Dairy", supplier: "Fresh Co", price: 400, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-garlic", name: "Garlic", category: "Vegetables", supplier: "Local", price: 50, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-onion", name: "Onion", category: "Vegetables", supplier: "Local", price: 100, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-milk", name: "Milk", category: "Dairy", supplier: "Fresh Co", price: 80, qty: 1, pUnit: "Litre", bUnit: "ML" },
  { id: "m-rice", name: "Basmati Rice", category: "Grains & Flour", supplier: "Grain House", price: 150, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-tomato", name: "Tomato", category: "Vegetables", supplier: "Local", price: 40, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-oil", name: "Sunflower Oil", category: "Oils & Fats", supplier: "Gold Drop", price: 140, qty: 1, pUnit: "Litre", bUnit: "ML" },
  { id: "m-sugar", name: "Sugar", category: "Bakery", supplier: "Sweet Co", price: 45, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-cocoa", name: "Cocoa Powder", category: "Bakery", supplier: "Choco Imports", price: 600, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-tea", name: "Tea Leaves", category: "Beverages", supplier: "Assam Estates", price: 300, qty: 1, pUnit: "KG", bUnit: "Gram" },
  { id: "m-saffron", name: "Saffron", category: "Spices", supplier: "Imports", price: null, qty: 1, pUnit: "Gram", bUnit: "Gram" },
];

const raw_materials: RawMaterial[] = matSeeds.map((m) => ({
  id: m.id,
  ingredient_name: m.name,
  category: m.category,
  supplier_name: m.supplier,
  purchase_price: m.price,
  purchase_quantity: m.qty,
  purchase_unit: m.pUnit,
  base_unit: m.bUnit,
  cost_per_base_unit:
    m.price === null ? null : calculateCostPerBaseUnit(m.price, m.qty, m.pUnit, m.bUnit),
  last_price_update: m.price === null ? null : SEED_TS.slice(0, 10),
  status: "active",
  created_by: U_ADMIN,
  created_at: SEED_TS,
}));

function mat(id: string): RawMaterial {
  return raw_materials.find((m) => m.id === id)!;
}

// --- Recipes + their ingredients ------------------------------------------
interface RecipeSeed {
  id: string;
  name: string;
  category: string;
  brand: Recipe["brand"];
  description: string;
  prep: number;
  serving: number;
  status: Recipe["status"];
  createdBy: string;
  approvedBy?: string;
  selling?: number;
  lines: { matId: string; qty: number; unit: string }[];
}

const recipeSeeds: RecipeSeed[] = [
  {
    id: "r-alfredo",
    name: "Chicken Alfredo Pasta",
    category: "Pasta",
    brand: "capiche",
    description: "Creamy chicken alfredo with garlic butter.",
    prep: 45,
    serving: 4,
    status: "approved",
    createdBy: U_EDITOR,
    approvedBy: U_ADMIN,
    selling: 199,
    lines: [
      { matId: "m-chicken", qty: 500, unit: "Gram" },
      { matId: "m-pasta", qty: 200, unit: "Gram" },
      { matId: "m-cream", qty: 150, unit: "ML" },
      { matId: "m-butter", qty: 50, unit: "Gram" },
      { matId: "m-garlic", qty: 10, unit: "Gram" },
    ],
  },
  {
    id: "r-biryani",
    name: "Veg Biryani",
    category: "Rice",
    brand: "aiko",
    description: "Fragrant layered vegetable biryani.",
    prep: 60,
    serving: 6,
    status: "testing",
    createdBy: U_EDITOR,
    selling: 52,
    lines: [
      { matId: "m-rice", qty: 500, unit: "Gram" },
      { matId: "m-onion", qty: 200, unit: "Gram" },
      { matId: "m-tomato", qty: 150, unit: "Gram" },
      { matId: "m-oil", qty: 60, unit: "ML" },
    ],
  },
  {
    id: "r-mousse",
    name: "Chocolate Mousse",
    category: "Dessert",
    brand: "capiche",
    description: "Rich eggless chocolate mousse.",
    prep: 30,
    serving: 8,
    status: "draft",
    createdBy: U_EDITOR,
    selling: 28,
    lines: [
      { matId: "m-cream", qty: 400, unit: "ML" },
      { matId: "m-cocoa", qty: 80, unit: "Gram" },
      { matId: "m-sugar", qty: 100, unit: "Gram" },
    ],
  },
  {
    id: "r-chai",
    name: "Masala Chai",
    category: "Beverage",
    brand: "aiko",
    description: "Spiced Indian milk tea.",
    prep: 15,
    serving: 10,
    status: "draft",
    createdBy: U_EDITOR,
    selling: 92,
    lines: [
      { matId: "m-milk", qty: 1500, unit: "ML" },
      { matId: "m-tea", qty: 40, unit: "Gram" },
      { matId: "m-sugar", qty: 120, unit: "Gram" },
    ],
  },
];

const recipes: Recipe[] = [];
const recipe_ingredients: RecipeIngredient[] = [];

for (const rs of recipeSeeds) {
  let total = 0;
  rs.lines.forEach((line, idx) => {
    const m = mat(line.matId);
    const cost =
      m.cost_per_base_unit === null
        ? 0
        : calculateIngredientCost(m.cost_per_base_unit, line.qty, line.unit, m.base_unit);
    total += cost;
    recipe_ingredients.push({
      id: `${rs.id}-i${idx}`,
      recipe_id: rs.id,
      ingredient_id: line.matId,
      quantity_used: line.qty,
      unit_used: line.unit,
      calculated_cost: m.cost_per_base_unit === null ? null : cost,
      sort_order: idx,
    });
  });
  const totalCost = parseFloat(total.toFixed(2));
  recipes.push({
    id: rs.id,
    recipe_name: rs.name,
    category: rs.category,
    brand: rs.brand,
    description: rs.description,
    preparation_time: rs.prep,
    serving_size: rs.serving,
    status: rs.status,
    selling_price: rs.selling ?? null,
    total_cost: totalCost,
    cost_per_portion: parseFloat((totalCost / rs.serving).toFixed(2)),
    created_by: rs.createdBy,
    approved_by: rs.approvedBy ?? null,
    approved_at: rs.approvedBy ? "2026-06-20T09:30:00.000Z" : null,
    rejection_note: null,
    version_no: 1,
    created_at: SEED_TS,
    updated_at: SEED_TS,
  });
}

export function buildSeed(): MockDb {
  return {
    users: structuredClone(users),
    raw_materials: structuredClone(raw_materials),
    recipes: structuredClone(recipes),
    recipe_ingredients: structuredClone(recipe_ingredients),
    recipe_cost_history: [],
    ingredient_price_history: [],
    recipe_versions: recipeSeeds.map((rs) => ({
      id: `${rs.id}-v1`,
      recipe_id: rs.id,
      version_no: 1,
      snapshot: null,
      notes: "Initial version",
      created_by: rs.createdBy,
      created_at: SEED_TS,
    })),
    // Viewer Amit gets Aiko access to the approved Alfredo recipe by default.
    user_recipe_views: [
      {
        id: "urv-1",
        user_id: U_VIEWER,
        recipe_id: "r-alfredo",
        view_type: "aiko",
        assigned_by: U_ADMIN,
        assigned_at: SEED_TS,
      },
    ],
    audit_logs: [],
    system_settings: [
      { id: "s-foodcost", key: "food_cost_pct", value: "30", updated_by: U_ADMIN, updated_at: SEED_TS },
      { id: "s-margin", key: "margin_alert_pct", value: "35", updated_by: U_ADMIN, updated_at: SEED_TS },
      {
        id: "s-categories",
        key: "ingredient_categories",
        value: JSON.stringify([
          "Vegetables", "Protein", "Dairy", "Grains & Flour", "Oils & Fats",
          "Spices", "Sauces & Condiments", "Beverages", "Bakery", "Dry Fruits",
        ]),
        updated_by: U_ADMIN,
        updated_at: SEED_TS,
      },
    ],
  };
}
