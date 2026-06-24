// Seed data for the mock backend — Capiche & Aiko menu recipes from the
// kitchen costing sheet. Our model is flat (recipes reference raw materials),
// so prep sub-recipes (sauces, pastes, doughs) are modelled as "prep" raw
// materials with a per-gram cost; the menu recipes reference them by grams.

import { calculateCostPerBaseUnit, calculateIngredientCost } from "../costing";
import type { MockDb } from "./mock/db";
import type { RawMaterial, Recipe, RecipeIngredient, User } from "./types";

const SEED_TS = "2026-06-01T09:00:00.000Z";
const round2 = (n: number) => parseFloat(n.toFixed(2));

// --- Users -----------------------------------------------------------------
const U_ADMIN = "u-admin";
const U_EDITOR = "u-editor";
const U_VIEWER = "u-viewer";

const users: User[] = [
  { id: U_ADMIN, name: "Rahul Sharma", email: "rahul@brand.com", role: "admin", status: "active", password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_EDITOR, name: "Priya Patel", email: "priya@brand.com", role: "editor", status: "active", password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_VIEWER, name: "Amit Roy", email: "amit@brand.com", role: "viewer", status: "active", password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
];

// --- Raw materials (leaves + prep components), costed per gram --------------
interface MatDef {
  id: string;
  name: string;
  category: string;
  perGram: number; // ₹ per gram
}

const matDefs: MatDef[] = [
  { id: "m-butter", name: "Butter", category: "Dairy", perGram: 0.55 },
  { id: "m-garlic-peeled", name: "Peeled Garlic", category: "Vegetables", perGram: 0.252 },
  { id: "m-olive-oil", name: "Olive Oil", category: "Oils & Fats", perGram: 0.867 },
  { id: "m-black-pepper", name: "Black Pepper", category: "Spices", perGram: 0.667 },
  { id: "m-spaghetti", name: "Boiled Spaghetti Pasta", category: "Grains & Flour", perGram: 0.1105 },
  { id: "m-chilli-flakes", name: "Chilli Flakes", category: "Spices", perGram: 0.333 },
  { id: "m-salt", name: "Salt", category: "Spices", perGram: 0.333 },
  { id: "m-parmesan", name: "Parmesan Cheese", category: "Dairy", perGram: 1.5 },
  { id: "m-green-garlic", name: "Green Garlic", category: "Vegetables", perGram: 0.5 },
  { id: "m-spring-onion-chopped", name: "Chopped Spring Onion", category: "Vegetables", perGram: 0.2 },
  { id: "m-parsley", name: "Parsley", category: "Vegetables", perGram: 0.432 },
  { id: "m-fried-garlic", name: "Fried Garlic", category: "Vegetables", perGram: 0.2 },
  { id: "m-chilli-crisp", name: "Chilli Crisp", category: "In-House Prep", perGram: 0.4 },
  { id: "m-bucatini", name: "Boiled Bucatini", category: "Grains & Flour", perGram: 0.0923 },
  { id: "m-pesto-white-base", name: "Pesto White Base Sauce", category: "In-House Prep", perGram: 0.1934 },
  { id: "m-pesto-sauce", name: "Pesto Sauce", category: "In-House Prep", perGram: 0.4 },
  { id: "m-red-paprika", name: "Red Paprika", category: "Spices", perGram: 0.5 },
  { id: "m-pizza-dough", name: "Pizza Dough", category: "In-House Prep", perGram: 0.0833 },
  { id: "m-mozzarella", name: "Mozzarella Grated", category: "Dairy", perGram: 0.603 },
  { id: "m-bechamel", name: "Bechamel Sauce", category: "In-House Prep", perGram: 0.1142 },
  { id: "m-chili-crunch-sauce", name: "Chili Crunch Sauce", category: "In-House Prep", perGram: 0.21 },
  { id: "m-burrata", name: "Burrata Cheese", category: "Dairy", perGram: 1.054 },
  { id: "m-black-sesame", name: "Black Sesame", category: "Spices", perGram: 0.5 },
  { id: "m-coriander", name: "Coriander", category: "Vegetables", perGram: 0.125 },
  { id: "m-spring-onion", name: "Spring Onion", category: "Vegetables", perGram: 0.125 },
  { id: "m-basil", name: "Basil", category: "Vegetables", perGram: 0.375 },
  { id: "m-dill-leaves", name: "Dill Leaves", category: "Vegetables", perGram: 0.3 },
  { id: "m-chilli-crisp-oil", name: "Chilli Crisp Oil", category: "In-House Prep", perGram: 0.125 },
  { id: "m-rice-flour", name: "Rice Flour", category: "Grains & Flour", perGram: 0.1 },
  { id: "m-sesame-sushi-rice", name: "Sesame Sushi Rice", category: "In-House Prep", perGram: 0.2507 },
  { id: "m-ponzu-wasabi-mayo", name: "Ponzu Wasabi Mayo", category: "In-House Prep", perGram: 0.17 },
  { id: "m-gochujang-mayo", name: "Gochujang Mayo", category: "In-House Prep", perGram: 0.25 },
  { id: "m-avo-guac", name: "Avo Guac", category: "In-House Prep", perGram: 0.65 },
  { id: "m-beetroot-chunks", name: "Marinated Beetroot Chunks", category: "In-House Prep", perGram: 0.1088 },
  { id: "m-bagel-seasoning", name: "Bagel Seasoning", category: "In-House Prep", perGram: 2.2 },
  { id: "m-white-spring-onion", name: "White Spring Onion", category: "Vegetables", perGram: 0.111 },
  { id: "m-oil", name: "Oil", category: "Oils & Fats", perGram: 0.3 },
  { id: "m-kashmiri-chilli-powder", name: "Kashmiri Chilli Powder", category: "Spices", perGram: 0.8 },
  { id: "m-kashmiri-red-paste", name: "Kashmiri Chilli Red Paste", category: "In-House Prep", perGram: 0.8 },
  { id: "m-sl-red-paste", name: "Sri Lankan Red Paste", category: "In-House Prep", perGram: 2.439 },
  { id: "m-tamarind-water", name: "Tamarind Water", category: "In-House Prep", perGram: 0.0633 },
  { id: "m-coconut-milk", name: "Coconut Milk", category: "Dairy", perGram: 0.421 },
  { id: "m-stock-water", name: "Stock Water", category: "Beverages", perGram: 0.09 },
  { id: "m-water", name: "Water", category: "Beverages", perGram: 0 },
  { id: "m-msg", name: "MSG", category: "Spices", perGram: 0.333 },
  { id: "m-white-pepper", name: "White Pepper", category: "Spices", perGram: 1 },
  { id: "m-stock-powder", name: "Stock Powder", category: "Spices", perGram: 0.5 },
  { id: "m-sl-curry-powder", name: "Sri Lankan Red Curry Powder Mix", category: "In-House Prep", perGram: 2.437 },
  { id: "m-tofu", name: "Tofu", category: "Protein", perGram: 0.25 },
  { id: "m-carrot", name: "Carrot", category: "Vegetables", perGram: 0.05 },
  { id: "m-mushroom", name: "Mushroom", category: "Vegetables", perGram: 0.2 },
  { id: "m-shimeji", name: "Shimeji Mushroom", category: "Vegetables", perGram: 1.675 },
  { id: "m-picked-red-paprika", name: "Pickled Red Paprika", category: "Vegetables", perGram: 0.2 },
  { id: "m-slit-onion", name: "Slit Onion", category: "Vegetables", perGram: 0.5 },
  { id: "m-red-chilli-oil", name: "Red Chilli Oil", category: "Oils & Fats", perGram: 1 },
  { id: "m-fried-onion", name: "Fried Onion", category: "Vegetables", perGram: 0.1 },
];

const raw_materials: RawMaterial[] = matDefs.map((d) => {
  const pricePerKg = round2(d.perGram * 1000);
  return {
    id: d.id,
    ingredient_name: d.name,
    category: d.category,
    supplier_name: null,
    purchase_price: pricePerKg,
    purchase_quantity: 1,
    purchase_unit: "KG",
    base_unit: "Gram",
    cost_per_base_unit: calculateCostPerBaseUnit(pricePerKg, 1, "KG", "Gram"),
    last_price_update: SEED_TS.slice(0, 10),
    status: "active",
    created_by: U_ADMIN,
    created_at: SEED_TS,
  } satisfies RawMaterial;
});

function mat(id: string): RawMaterial {
  return raw_materials.find((m) => m.id === id)!;
}

// --- Menu recipes ----------------------------------------------------------
interface RecipeSeed {
  id: string;
  name: string;
  category: string;
  brand: Recipe["brand"];
  description: string;
  prep: number;
  status: Recipe["status"];
  createdBy: string;
  approvedBy?: string;
  selling: number;
  lines: { matId: string; g: number }[];
}

const recipeSeeds: RecipeSeed[] = [
  {
    id: "r-aglio-olio",
    name: "Aglio Olio",
    category: "Pasta",
    brand: "capiche",
    description: "Garlic and olive oil spaghetti with chilli and parmesan.",
    prep: 20,
    status: "approved",
    createdBy: U_EDITOR,
    approvedBy: U_ADMIN,
    selling: 740,
    lines: [
      { matId: "m-butter", g: 20 },
      { matId: "m-garlic-peeled", g: 20 },
      { matId: "m-olive-oil", g: 15 },
      { matId: "m-black-pepper", g: 1.5 },
      { matId: "m-spaghetti", g: 190 },
      { matId: "m-chilli-flakes", g: 3 },
      { matId: "m-salt", g: 3 },
      { matId: "m-parmesan", g: 8 },
      { matId: "m-green-garlic", g: 4 },
      { matId: "m-spring-onion-chopped", g: 5 },
      { matId: "m-parsley", g: 5 },
      { matId: "m-fried-garlic", g: 5 },
      { matId: "m-chilli-crisp", g: 5 },
    ],
  },
  {
    id: "r-pesto-bucatini",
    name: "Pesto Bucatini",
    category: "Pasta",
    brand: "capiche",
    description: "Bucatini in a creamy basil pesto with parmesan.",
    prep: 25,
    status: "approved",
    createdBy: U_EDITOR,
    approvedBy: U_ADMIN,
    selling: 740,
    lines: [
      { matId: "m-bucatini", g: 120 },
      { matId: "m-butter", g: 20 },
      { matId: "m-olive-oil", g: 5 },
      { matId: "m-black-pepper", g: 1 },
      { matId: "m-salt", g: 3 },
      { matId: "m-pesto-white-base", g: 70 },
      { matId: "m-parmesan", g: 8 },
      { matId: "m-chilli-flakes", g: 3 },
      { matId: "m-pesto-sauce", g: 55 },
      { matId: "m-red-paprika", g: 2 },
    ],
  },
  {
    id: "r-chilli-crunch-pizza",
    name: "Chilli Crunch Pizza",
    category: "Pizza",
    brand: "capiche",
    description: "Wood-fired pizza with burrata, bechamel and chilli crunch.",
    prep: 18,
    status: "testing",
    createdBy: U_EDITOR,
    selling: 929,
    lines: [
      { matId: "m-pizza-dough", g: 180 },
      { matId: "m-mozzarella", g: 60 },
      { matId: "m-bechamel", g: 50 },
      { matId: "m-chili-crunch-sauce", g: 100 },
      { matId: "m-burrata", g: 130 },
      { matId: "m-black-sesame", g: 6 },
      { matId: "m-coriander", g: 8 },
      { matId: "m-spring-onion", g: 8 },
      { matId: "m-basil", g: 8 },
      { matId: "m-dill-leaves", g: 8 },
      { matId: "m-chilli-crisp-oil", g: 8 },
      { matId: "m-rice-flour", g: 10 },
    ],
  },
  {
    id: "r-avo-crispy-rice",
    name: "Avo Crispy Rice",
    category: "Sushi",
    brand: "aiko",
    description: "Crispy sushi rice with avocado, ponzu wasabi mayo and beetroot.",
    prep: 15,
    status: "approved",
    createdBy: U_EDITOR,
    approvedBy: U_ADMIN,
    selling: 840,
    lines: [
      { matId: "m-sesame-sushi-rice", g: 156 },
      { matId: "m-ponzu-wasabi-mayo", g: 2 },
      { matId: "m-gochujang-mayo", g: 4 },
      { matId: "m-avo-guac", g: 20 },
      { matId: "m-beetroot-chunks", g: 68 },
      { matId: "m-bagel-seasoning", g: 5 },
      { matId: "m-white-spring-onion", g: 18 },
    ],
  },
  {
    id: "r-sl-red-curry",
    name: "Sri Lankan Red Curry",
    category: "Mains",
    brand: "aiko",
    description: "Tofu and mushroom red curry in spiced coconut milk.",
    prep: 35,
    status: "draft",
    createdBy: U_EDITOR,
    selling: 640,
    lines: [
      { matId: "m-oil", g: 10 },
      { matId: "m-kashmiri-chilli-powder", g: 2.5 },
      { matId: "m-kashmiri-red-paste", g: 10 },
      { matId: "m-sl-red-paste", g: 10 },
      { matId: "m-tamarind-water", g: 15 },
      { matId: "m-coconut-milk", g: 200 },
      { matId: "m-stock-water", g: 100 },
      { matId: "m-water", g: 50 },
      { matId: "m-msg", g: 3 },
      { matId: "m-salt", g: 2 },
      { matId: "m-white-pepper", g: 2 },
      { matId: "m-stock-powder", g: 2 },
      { matId: "m-sl-curry-powder", g: 1 },
      { matId: "m-tofu", g: 20 },
      { matId: "m-carrot", g: 20 },
      { matId: "m-mushroom", g: 20 },
      { matId: "m-shimeji", g: 20 },
      { matId: "m-basil", g: 2 },
      { matId: "m-picked-red-paprika", g: 5 },
      { matId: "m-slit-onion", g: 2 },
      { matId: "m-red-chilli-oil", g: 1 },
      { matId: "m-fried-onion", g: 10 },
    ],
  },
];

const recipes: Recipe[] = [];
const recipe_ingredients: RecipeIngredient[] = [];

for (const rs of recipeSeeds) {
  let total = 0;
  rs.lines.forEach((line, idx) => {
    const m = mat(line.matId);
    const cost = calculateIngredientCost(m.cost_per_base_unit ?? 0, line.g, "Gram", "Gram");
    total += cost;
    recipe_ingredients.push({
      id: `${rs.id}-i${idx}`,
      recipe_id: rs.id,
      ingredient_id: line.matId,
      quantity_used: line.g,
      unit_used: "Gram",
      calculated_cost: cost,
      sort_order: idx,
    });
  });
  const totalCost = round2(total);
  recipes.push({
    id: rs.id,
    recipe_name: rs.name,
    category: rs.category,
    brand: rs.brand,
    description: rs.description,
    image_url: null,
    preparation_time: rs.prep,
    serving_size: 1,
    status: rs.status,
    selling_price: rs.selling,
    total_cost: totalCost,
    cost_per_portion: totalCost,
    created_by: rs.createdBy,
    approved_by: rs.approvedBy ?? null,
    approved_at: rs.approvedBy ? "2026-06-20T09:30:00.000Z" : null,
    rejection_note: null,
    version_no: 1,
    created_at: SEED_TS,
    updated_at: SEED_TS,
    updated_by: rs.approvedBy ?? rs.createdBy,
  });
}

export function buildSeed(): MockDb {
  const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();
  return {
    users: structuredClone(users),
    raw_materials: structuredClone(raw_materials),
    recipes: structuredClone(recipes),
    recipe_ingredients: structuredClone(recipe_ingredients),
    recipe_cost_history: [],
    ingredient_price_history: [
      { id: "iph-1", ingredient_id: "m-olive-oil", old_price: 800, new_price: 867, old_cost_per_base_unit: 0.8, new_cost_per_base_unit: 0.867, changed_by: U_EDITOR, changed_at: hoursAgo(2) },
      { id: "iph-2", ingredient_id: "m-burrata", old_price: 1100, new_price: 1054, old_cost_per_base_unit: 1.1, new_cost_per_base_unit: 1.054, changed_by: U_EDITOR, changed_at: hoursAgo(26) },
      { id: "iph-3", ingredient_id: "m-coconut-milk", old_price: 390, new_price: 421, old_cost_per_base_unit: 0.39, new_cost_per_base_unit: 0.421, changed_by: U_ADMIN, changed_at: hoursAgo(28) },
    ],
    recipe_versions: recipeSeeds.map((rs) => ({
      id: `${rs.id}-v1`,
      recipe_id: rs.id,
      version_no: 1,
      snapshot: null,
      notes: "Initial version",
      created_by: rs.createdBy,
      created_at: SEED_TS,
    })),
    // Viewer Amit gets Aiko access to the approved Avo Crispy Rice by default.
    user_recipe_views: [
      { id: "urv-1", user_id: U_VIEWER, recipe_id: "r-avo-crispy-rice", view_type: "aiko", assigned_by: U_ADMIN, assigned_at: SEED_TS },
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
          "In-House Prep", "Pasta", "Pizza", "Sushi", "Mains",
        ]),
        updated_by: U_ADMIN,
        updated_at: SEED_TS,
      },
    ],
  };
}
