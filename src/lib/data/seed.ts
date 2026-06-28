// Seed data — Capiche & Aiko menu recipes plus in-house prep sub-recipes from
// the kitchen costing sheet. Menu recipes reference prep recipes as components
// (component_type "recipe"); preps are costed from leaf raw materials and a
// prep's per-unit cost = total_cost ÷ yield (sum of its ingredient grams).

import { calculateCostPerBaseUnit, calculateIngredientCost, prepUnitCostFrom } from "../costing";
import { canConvert } from "../units";
import { costForCutYield } from "../yield";
import { COOKBOOK_RECIPES } from "./cookbook";
import { PIZZA_RECIPES, PIZZA_SIZE_LABEL, type PizzaSize } from "./pizzas";
import { resolveParentAndCut, cutYieldPct } from "./ingredientCuts";
import { MASTER_PRICES } from "./masterPrices";
import { MASTER_DISH_COSTS } from "./masterDishCosts";
import type { MockDb } from "./mock/db";
import type { Brand, RawMaterial, Recipe, RecipeIngredient, User } from "./types";

/** ₹ per gram for an ingredient from the master costing book (the only price
 *  source), matched by normalised name. Undefined when the book has no price. */
const priceNorm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();
const masterPerGram = (name: string): number | undefined => MASTER_PRICES[priceNorm(name)];

/** Per-dish making/packaging/selling from the master "…2026" summary sheets,
 *  matched to a recipe name (exact key, then a contains-based fuzzy fallback). */
const dishKey = (s: string) =>
  priceNorm(s)
    .replace(/\(\d+\s*pcs?\)/g, "")
    .replace(/\bnew\b/g, "")
    .replace(/\b(pizza|pasta|salad|dimsum)\b/g, "")
    .replace(/[^a-z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const DISH_ENTRIES = Object.keys(MASTER_DISH_COSTS).map((k) => ({
  k,
  flat: k.replace(/ /g, ""),
  tokens: new Set(k.split(" ").filter(Boolean)),
}));
const dishCostFor = (name: string): (typeof MASTER_DISH_COSTS)[string] | null => {
  const k = dishKey(name);
  if (MASTER_DISH_COSTS[k]) return MASTER_DISH_COSTS[k];
  const flat = k.replace(/ /g, "");
  const kt = new Set(k.split(" ").filter(Boolean));
  // space-insensitive exact, then substring either way, then token-subset.
  let hit = DISH_ENTRIES.find((e) => e.flat === flat && flat.length >= 5);
  if (!hit && k.length >= 5) hit = DISH_ENTRIES.find((e) => e.k.length >= 5 && (e.k.includes(k) || k.includes(e.k)));
  if (!hit && kt.size >= 2)
    hit = DISH_ENTRIES.find((e) => {
      const [small, large] = kt.size <= e.tokens.size ? [kt, e.tokens] : [e.tokens, kt];
      return small.size >= 2 && [...small].every((t) => large.has(t));
    });
  return hit ? MASTER_DISH_COSTS[hit.k] : null;
};

/** Light keyword classifier for cookbook-derived ingredients (display only). */
function inferCategory(name: string): string {
  const n = name.toLowerCase();
  const has = (...w: string[]) => w.some((x) => n.includes(x));
  if (n.includes("bell") || n.includes("capsicum")) return "Vegetables";
  if (has("oil")) return "Oils & Fats";
  if (has("cheese", "cream", "butter", "milk", "mozzarella", "parmesan", "burrata", "ricotta", "mascarpone", "yogurt", "yoghurt", "paneer")) return "Dairy";
  if (has("black pepper", "white pepper", "peppercorn", "salt", "chilli", "chili", "spice", "powder", "cumin", "turmeric", "paprika", "oregano", "thyme", "cinnamon", "masala", "cardamom", "clove", "fennel", "fenugreek", "sesame", "seasoning", "msg")) return "Spices";
  if (has("sauce", "mayo", "ketchup", "vinegar", "paste", "syrup", "honey", "soy", "dressing", "vinaigrette", "pesto", "ponzu", "gochujang", "dashi", "mirin", "glaze")) return "Sauces & Condiments";
  if (has("flour", "pasta", "noodle", "bread", "dough", "panko", "crumb", "maida", "semolina", "spaghetti", "bucatini", "fettuccine", "linguini", "rice", "macaroni", "conchiglioni", "sheet", "bagel")) return "Grains & Flour";
  if (has("chicken", "prawn", "shrimp", "fish", "tofu", "egg", "lamb", "beef", "pork", "bacon", "crab", "squid", "octopus", "salmon", "tuna")) return "Protein";
  if (has("strawberry", "mango", "lemon", "lime", "grapefruit", "persimmon", "apple", "banana", "fruit", "berry", "orange", "pineapple", "grape", "melon")) return "Fruits";
  if (has("onion", "garlic", "tomato", "mushroom", "carrot", "beetroot", "lettuce", "basil", "spinach", "cabbage", "arugula", "romaine", "iceberg", "sprout", "corn", "potato", "pepper", "cucumber", "ginger", "parsley", "coriander", "scallion", "leek", "lotus", "choy")) return "Vegetables";
  if (has("sugar", "chocolate", "cocoa", "vanilla", "almond", "hazelnut", "pine nut", "pistachio", "nut", "caramel", "granola")) return "Bakery";
  if (has("water", "ice", "juice", "tea", "soda", "cola")) return "Beverages";
  return "Other";
}

const SEED_TS = "2026-06-01T09:00:00.000Z";
const round2 = (n: number) => parseFloat(n.toFixed(2));

// --- Users -----------------------------------------------------------------
const U_ADMIN = "u-admin";
const U_EDITOR = "u-editor";
const U_VIEWER = "u-viewer";

const users: User[] = [
  { id: U_ADMIN, name: "Rahul Sharma", email: "rahul@brand.com", role: "admin", status: "active", approved: true, email_verified: true, dashboard_access: true, password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_EDITOR, name: "Priya Patel", email: "priya@brand.com", role: "editor", status: "active", approved: true, email_verified: true, password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_VIEWER, name: "Amit Roy", email: "amit@brand.com", role: "viewer", status: "active", approved: true, email_verified: true, password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
];

// --- Leaf raw materials (₹ per gram) ---------------------------------------
interface MatDef { id: string; name: string; category: string; perGram: number }

const matDefs: MatDef[] = [
  // proteins / dairy
  { id: "m-butter", name: "Butter", category: "Dairy", perGram: 0.55 },
  { id: "m-parmesan", name: "Parmesan Cheese", category: "Dairy", perGram: 1.5 },
  { id: "m-mozzarella", name: "Mozzarella Grated", category: "Dairy", perGram: 0.603 },
  { id: "m-burrata", name: "Burrata Cheese", category: "Dairy", perGram: 1.054 },
  { id: "m-milk", name: "Amul Gold Milk", category: "Dairy", perGram: 0.0752 },
  { id: "m-fresh-cream", name: "Fresh Cream", category: "Dairy", perGram: 0.2156 },
  { id: "m-tofu", name: "Tofu", category: "Protein", perGram: 0.25 },
  // grains / flours
  { id: "m-spaghetti", name: "Boiled Spaghetti Pasta", category: "Grains & Flour", perGram: 0.1105 },
  { id: "m-bucatini", name: "Boiled Bucatini", category: "Grains & Flour", perGram: 0.0923 },
  { id: "m-rice-flour", name: "Rice Flour", category: "Grains & Flour", perGram: 0.1 },
  { id: "m-maida", name: "Maida", category: "Grains & Flour", perGram: 0.041 },
  { id: "m-00-flour", name: "00 Flour", category: "Grains & Flour", perGram: 0.1197 },
  { id: "m-sushi-rice", name: "Sushi Rice", category: "Grains & Flour", perGram: 0.252 },
  { id: "m-yeast", name: "Yeast", category: "Bakery", perGram: 0.368 },
  { id: "m-malt", name: "Malt", category: "Bakery", perGram: 0.12 },
  { id: "m-brown-sugar", name: "Brown Sugar", category: "Bakery", perGram: 0.086 },
  { id: "m-sugar", name: "Sugar", category: "Bakery", perGram: 0.052 },
  // oils & fats
  { id: "m-olive-oil", name: "Olive Oil", category: "Oils & Fats", perGram: 0.867 },
  { id: "m-sunflower-oil", name: "Sunflower Oil", category: "Oils & Fats", perGram: 0.1916 },
  { id: "m-oil", name: "Oil", category: "Oils & Fats", perGram: 0.3 },
  { id: "m-chilli-crisp-oil", name: "Chilli Crisp Oil", category: "Oils & Fats", perGram: 0.125 },
  { id: "m-red-chilli-oil", name: "Red Chilli Oil", category: "Oils & Fats", perGram: 1 },
  // vegetables / aromatics
  { id: "m-garlic-peeled", name: "Peeled Garlic", category: "Vegetables", perGram: 0.252 },
  { id: "m-garlic-chopped", name: "Garlic Chopped", category: "Vegetables", perGram: 0.24 },
  { id: "m-green-garlic", name: "Green Garlic", category: "Vegetables", perGram: 0.5 },
  { id: "m-fried-garlic", name: "Fried Garlic", category: "Vegetables", perGram: 0.2 },
  { id: "m-ginger", name: "Ginger", category: "Vegetables", perGram: 0.13 },
  { id: "m-onion", name: "Onion", category: "Vegetables", perGram: 0.15 },
  { id: "m-slit-onion", name: "Slit Onion", category: "Vegetables", perGram: 0.5 },
  { id: "m-fried-onion", name: "Fried Onion", category: "Vegetables", perGram: 0.1 },
  { id: "m-confit-onion", name: "Confit Onion", category: "Vegetables", perGram: 0.138 },
  { id: "m-confit-garlic", name: "Confit Garlic", category: "Vegetables", perGram: 0.219 },
  { id: "m-spring-onion", name: "Spring Onion", category: "Vegetables", perGram: 0.125 },
  { id: "m-spring-onion-chopped", name: "Chopped Spring Onion", category: "Vegetables", perGram: 0.2 },
  { id: "m-white-spring-onion", name: "White Spring Onion", category: "Vegetables", perGram: 0.111 },
  { id: "m-parsley", name: "Parsley", category: "Vegetables", perGram: 0.432 },
  { id: "m-coriander", name: "Coriander", category: "Vegetables", perGram: 0.125 },
  { id: "m-dill-leaves", name: "Dill Leaves", category: "Vegetables", perGram: 0.3 },
  { id: "m-basil", name: "Basil", category: "Vegetables", perGram: 0.375 },
  { id: "m-curry-leaves", name: "Curry Leaves", category: "Vegetables", perGram: 0.143 },
  { id: "m-green-chilli", name: "Green Chillies", category: "Vegetables", perGram: 0.1 },
  { id: "m-carrot", name: "Carrot", category: "Vegetables", perGram: 0.05 },
  { id: "m-mushroom", name: "Mushroom", category: "Vegetables", perGram: 0.2 },
  { id: "m-shimeji", name: "Shimeji Mushroom", category: "Vegetables", perGram: 1.675 },
  { id: "m-beetroot", name: "Beetroot", category: "Vegetables", perGram: 0.06 },
  { id: "m-picked-red-paprika", name: "Pickled Red Paprika", category: "Vegetables", perGram: 0.2 },
  { id: "m-dried-red-chilli", name: "Dried Red Chilli", category: "Spices", perGram: 0.425 },
  { id: "m-lemon-juice", name: "Lemon Juice", category: "Sauces & Condiments", perGram: 0.252 },
  // spices & seasonings
  { id: "m-black-pepper", name: "Black Pepper", category: "Spices", perGram: 0.667 },
  { id: "m-white-pepper", name: "White Pepper", category: "Spices", perGram: 1 },
  { id: "m-chilli-flakes", name: "Chilli Flakes", category: "Spices", perGram: 0.333 },
  { id: "m-red-paprika", name: "Red Paprika", category: "Spices", perGram: 0.5 },
  { id: "m-salt", name: "Salt", category: "Spices", perGram: 0.0273 },
  { id: "m-msg", name: "MSG", category: "Spices", perGram: 0.333 },
  { id: "m-stock-powder", name: "Stock Powder", category: "Spices", perGram: 0.5 },
  { id: "m-garlic-powder", name: "Garlic Powder", category: "Spices", perGram: 0.4 },
  { id: "m-onion-powder", name: "Onion Powder", category: "Spices", perGram: 0.84 },
  { id: "m-kashmiri-chilli-powder", name: "Kashmiri Chilli Powder", category: "Spices", perGram: 0.8 },
  { id: "m-turmeric", name: "Turmeric", category: "Spices", perGram: 0.667 },
  { id: "m-mustard-seeds", name: "Mustard Seeds", category: "Spices", perGram: 0.25 },
  { id: "m-fenugreek-seeds", name: "Fenugreek Seeds", category: "Spices", perGram: 1 },
  { id: "m-coriander-seeds", name: "Coriander Seeds", category: "Spices", perGram: 4 },
  { id: "m-cumin-seeds", name: "Cumin Seeds", category: "Spices", perGram: 0.933 },
  { id: "m-fennel-seeds", name: "Fennel Seeds", category: "Spices", perGram: 0.2 },
  { id: "m-cinnamon", name: "Cinnamon", category: "Spices", perGram: 6 },
  { id: "m-cloves", name: "Cloves", category: "Spices", perGram: 2 },
  { id: "m-cardamom", name: "Cardamom", category: "Spices", perGram: 4 },
  { id: "m-black-sesame", name: "Black Sesame", category: "Spices", perGram: 0.5 },
  { id: "m-white-sesame", name: "White Sesame", category: "Spices", perGram: 0.2 },
  { id: "m-bagel-seasoning", name: "Bagel Seasoning", category: "Spices", perGram: 2.2 },
  { id: "m-wasabi", name: "Wasabi", category: "Spices", perGram: 1 },
  { id: "m-almond", name: "Almond", category: "Dry Fruits", perGram: 0.833 },
  // sauces & condiments (bought)
  { id: "m-kashmiri-red-paste", name: "Kashmiri Chilli Red Paste", category: "Sauces & Condiments", perGram: 0.8 },
  { id: "m-chunky-tomato-sauce", name: "Chunky Tomato Sauce", category: "Sauces & Condiments", perGram: 0.235 },
  { id: "m-white-vinegar", name: "White Vinegar", category: "Sauces & Condiments", perGram: 0.05 },
  { id: "m-hot-sauce", name: "Hot Sauce", category: "Sauces & Condiments", perGram: 0.2 },
  { id: "m-plain-mayo", name: "Plain Mayo", category: "Sauces & Condiments", perGram: 0.1 },
  { id: "m-ponzu-mayo", name: "Ponzu Mayo", category: "Sauces & Condiments", perGram: 0.1532 },
  { id: "m-gochujang-mayo", name: "Gochujang Mayo", category: "Sauces & Condiments", perGram: 0.25 },
  { id: "m-avo-guac", name: "Avo Guac", category: "Sauces & Condiments", perGram: 0.65 },
  { id: "m-corn-slurry", name: "Corn Slurry", category: "Sauces & Condiments", perGram: 0.1 },
  { id: "m-coconut-milk", name: "Coconut Milk", category: "Dairy", perGram: 0.421 },
  { id: "m-tamarind", name: "Tamarind", category: "Sauces & Condiments", perGram: 0.19 },
  // beverages / water
  { id: "m-water", name: "Water", category: "Beverages", perGram: 0 },
  { id: "m-ice", name: "Ice", category: "Beverages", perGram: 0 },
  { id: "m-stock-water", name: "Stock Water", category: "Beverages", perGram: 0.09 },
];

// Price every leaf material from the master costing book where it lists one;
// fall back to the curated seed price only when the book has no entry.
const matEffPerGram = (d: MatDef) => masterPerGram(d.name) ?? d.perGram;
const raw_materials: RawMaterial[] = matDefs.map((d) => {
  const pricePerKg = round2(matEffPerGram(d) * 1000);
  return {
    id: d.id,
    ingredient_name: d.name,
    category: d.category,
    supplier_name: null,
    notes: null,
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
const matPerGram = new Map(matDefs.map((d) => [d.id, matEffPerGram(d)]));

// --- Recipe definitions (preps + menus) ------------------------------------
type LineRef = { m: string; g: number } | { r: string; g: number };
interface RecipeDef {
  id: string;
  name: string;
  category: string;
  brand: Brand;
  isPrep: boolean;
  description: string;
  prep: number;
  status: Recipe["status"];
  createdBy: string;
  approvedBy?: string;
  selling?: number;
  lines: LineRef[];
}

const prepDefs: RecipeDef[] = [
  { id: "r-prep-chilli-crisp", name: "Chilli Crisp", category: "In-House Prep", brand: "capiche", isPrep: true, description: "House chilli crisp.", prep: 60, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-dried-red-chilli", g: 1000 }, { m: "m-onion", g: 500 }, { m: "m-salt", g: 220 }, { m: "m-ginger", g: 500 }, { m: "m-garlic-chopped", g: 800 }, { m: "m-sugar", g: 250 }, { m: "m-sunflower-oil", g: 5000 },
  ] },
  { id: "r-prep-bechamel", name: "Bechamel Sauce", category: "In-House Prep", brand: "capiche", isPrep: true, description: "House bechamel.", prep: 30, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-butter", g: 100 }, { m: "m-milk", g: 1000 }, { m: "m-garlic-powder", g: 5 }, { m: "m-onion-powder", g: 5 }, { m: "m-maida", g: 100 },
  ] },
  { id: "r-prep-pizza-dough", name: "Pizza Dough", category: "In-House Prep", brand: "capiche", isPrep: true, description: "Cold-proofed pizza dough.", prep: 1440, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-00-flour", g: 10000 }, { m: "m-yeast", g: 19 }, { m: "m-ice", g: 4443 }, { m: "m-water", g: 2221 }, { m: "m-olive-oil", g: 221 }, { m: "m-salt", g: 269 }, { m: "m-malt", g: 75 }, { m: "m-brown-sugar", g: 40 },
  ] },
  { id: "r-prep-pesto-white-base", name: "Pesto White Base Sauce", category: "In-House Prep", brand: "capiche", isPrep: true, description: "White base for pesto pasta.", prep: 20, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-confit-onion", g: 10 }, { m: "m-confit-garlic", g: 10 }, { m: "m-corn-slurry", g: 10 }, { m: "m-water", g: 60 }, { m: "m-fresh-cream", g: 70 },
  ] },
  { id: "r-prep-hydroponic-pesto", name: "Hydroponic Basil Pesto", category: "In-House Prep", brand: "capiche", isPrep: true, description: "Fresh basil pesto.", prep: 15, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-olive-oil", g: 100 }, { m: "m-almond", g: 30 }, { m: "m-lemon-juice", g: 20 }, { m: "m-salt", g: 5 }, { m: "m-ice", g: 70 }, { m: "m-basil", g: 250 },
  ] },
  { id: "r-prep-chili-crunch-sauce", name: "Chili Crunch Sauce", category: "In-House Prep", brand: "capiche", isPrep: true, description: "Uses house chilli crisp.", prep: 30, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-olive-oil", g: 5 }, { m: "m-dill-leaves", g: 4 }, { m: "m-coriander", g: 10 }, { m: "m-spring-onion", g: 30 }, { m: "m-garlic-peeled", g: 30 }, { m: "m-onion", g: 5 }, { m: "m-coconut-milk", g: 30 }, { m: "m-white-vinegar", g: 20 }, { m: "m-water", g: 50 }, { r: "r-prep-chilli-crisp", g: 30 }, { m: "m-chunky-tomato-sauce", g: 200 }, { m: "m-msg", g: 0.5 }, { m: "m-salt", g: 1 }, { m: "m-black-pepper", g: 0.5 }, { m: "m-sugar", g: 2 },
  ] },
  { id: "r-prep-sesame-sushi-rice", name: "Sesame Sushi Rice", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Seasoned sushi rice.", prep: 40, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-sushi-rice", g: 1000 }, { m: "m-white-sesame", g: 25 },
  ] },
  { id: "r-prep-ponzu-wasabi-mayo", name: "Ponzu Wasabi Mayo", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Ponzu wasabi mayo.", prep: 10, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-ponzu-mayo", g: 100 }, { m: "m-wasabi", g: 2 },
  ] },
  { id: "r-prep-tamarind-water", name: "Tamarind Water", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Tamarind extraction.", prep: 15, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-tamarind", g: 100 }, { m: "m-water", g: 200 },
  ] },
  { id: "r-prep-beetroot", name: "Marinated Beetroot Chunks", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Marinated beetroot.", prep: 20, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-beetroot", g: 40 }, { m: "m-hot-sauce", g: 5 }, { m: "m-salt", g: 2 }, { m: "m-black-pepper", g: 1 }, { m: "m-plain-mayo", g: 20 },
  ] },
  { id: "r-prep-sl-curry-powder", name: "Sri Lankan Red Curry Powder Mix", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Roasted & ground spice mix.", prep: 30, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-coriander-seeds", g: 40 }, { m: "m-cumin-seeds", g: 15 }, { m: "m-fennel-seeds", g: 15 }, { m: "m-black-pepper", g: 10 }, { m: "m-cinnamon", g: 3 }, { m: "m-cloves", g: 2 }, { m: "m-cardamom", g: 2 },
  ] },
  { id: "r-prep-sl-red-paste", name: "Sri Lankan Red Paste", category: "In-House Prep", brand: "aiko", isPrep: true, description: "Uses house curry powder.", prep: 45, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, lines: [
    { m: "m-onion", g: 150 }, { m: "m-garlic-peeled", g: 10 }, { m: "m-ginger", g: 10 }, { m: "m-green-chilli", g: 10 }, { m: "m-oil", g: 30 }, { m: "m-mustard-seeds", g: 4 }, { m: "m-fenugreek-seeds", g: 1 }, { m: "m-curry-leaves", g: 7 }, { m: "m-basil", g: 7 }, { r: "r-prep-sl-curry-powder", g: 10 }, { m: "m-kashmiri-chilli-powder", g: 2.5 }, { m: "m-turmeric", g: 1.5 },
  ] },
];

// Menu dishes come from the cookbook import (see cookbook.ts) priced from the
// master book. The in-house preps above remain as reusable sub-recipes.
const menuDefs: RecipeDef[] = [];

const WASTAGE_PCT = 5; // standard wastage from the costing sheet

const allDefs = [...prepDefs, ...menuDefs];
const defById = new Map(allDefs.map((d) => [d.id, d]));
const yieldOf = (d: RecipeDef) => d.lines.reduce((s, l) => s + l.g, 0) || 1;

// Seeded standard yields (MUST match the ingredient_yields built in buildSeed).
// Effective per-gram = purchase cost ÷ usable grams, so seeded recipe costs match
// the yield-adjusted runtime recompute (§9).
const SEED_YIELD_WASTAGE: Record<string, number> = { "m-onion": 20, "m-ginger": 15, "m-carrot": 10 };
const yieldAdjPerGram = new Map<string, number>();
for (const [matId, wastagePct] of Object.entries(SEED_YIELD_WASTAGE)) {
  const perGram = matPerGram.get(matId);
  if (perGram == null) continue;
  const usableG = 1000 * (1 - wastagePct / 100);
  yieldAdjPerGram.set(matId, (perGram * 1000) / usableG);
}
const effPerGram = (id: string) => yieldAdjPerGram.get(id) ?? matPerGram.get(id) ?? 0;

// Memoised, cycle-guarded total cost incl. wastage (preps before the menus).
const totalMemo = new Map<string, number>();
function totalOf(id: string, stack = new Set<string>()): number {
  if (totalMemo.has(id)) return totalMemo.get(id)!;
  if (stack.has(id)) return 0;
  stack.add(id);
  const d = defById.get(id)!;
  let raw = 0;
  for (const l of d.lines) {
    if ("r" in l) {
      const sub = defById.get(l.r)!;
      // Use the prep's pre-wastage per-gram so wastage isn't double-counted.
      raw += round2(prepUnitCostFrom(totalOf(l.r, stack), yieldOf(sub), WASTAGE_PCT) * l.g);
    } else {
      raw += round2(effPerGram(l.m) * l.g);
    }
  }
  stack.delete(id);
  const t = round2(raw * (1 + WASTAGE_PCT / 100));
  totalMemo.set(id, t);
  return t;
}

const recipes: Recipe[] = [];
const recipe_ingredients: RecipeIngredient[] = [];

for (const d of allDefs) {
  const total = totalOf(d.id);
  d.lines.forEach((l, idx) => {
    const isRecipe = "r" in l;
    const refId = isRecipe ? l.r : l.m;
    const cost = isRecipe
      ? round2(prepUnitCostFrom(totalOf(refId), yieldOf(defById.get(refId)!), WASTAGE_PCT) * l.g)
      : round2(effPerGram(refId) * l.g);
    recipe_ingredients.push({
      id: `${d.id}-i${idx}`,
      recipe_id: d.id,
      ingredient_id: refId,
      component_type: isRecipe ? "recipe" : "material",
      quantity_used: l.g,
      unit_used: "Gram",
      calculated_cost: cost,
      sort_order: idx,
    });
  });
  recipes.push({
    id: d.id,
    recipe_name: d.name,
    category: d.category,
    brand: d.brand,
    description: d.description,
    method: [],
    image_url: null,
    preparation_time: d.prep,
    serving_size: 1,
    status: d.status,
    selling_price: d.selling ?? null,
    packaging_cost: 0,
    total_cost: total,
    cost_per_portion: total,
    wastage_pct: WASTAGE_PCT,
    is_prep: d.isPrep,
    yield_quantity: yieldOf(d),
    yield_unit: "Gram",
    created_by: d.createdBy,
    approved_by: d.approvedBy ?? null,
    approved_at: d.approvedBy ? "2026-06-20T09:30:00.000Z" : null,
    rejection_note: null,
    version_no: 1,
    created_at: SEED_TS,
    updated_at: SEED_TS,
    updated_by: d.approvedBy ?? d.createdBy,
  });
}

// --- Cookbook menu (Capiche & Aiko) ----------------------------------------
// Full dish catalogue extracted from the cookbook PDFs (see cookbook.ts). Each
// ingredient is priced from the master costing book where it lists one (the only
// price source); unlisted ingredients stay unpriced and don't contribute to the
// making cost. Shared items are de-duped by name against the seed materials.
// Recipes carry no selling price yet, so FC% appears once a selling price is set.
{
  const norm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();
  const matByName = new Map(raw_materials.map((m) => [norm(m.ingredient_name), m.id]));
  const cpbuById = new Map(raw_materials.map((m) => [m.id, m.cost_per_base_unit]));
  const existingRecipeNames = new Set(recipes.map((r) => norm(r.recipe_name)));
  const usedMatIds = new Set(raw_materials.map((m) => m.id));
  const slugify = (s: string) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const purchaseUnitFor = (base: string) => (base === "Gram" ? "KG" : base === "ML" ? "Litre" : "Piece");

  for (const cb of COOKBOOK_RECIPES) {
    if (existingRecipeNames.has(norm(cb.name))) continue; // never duplicate a seeded dish
    // Capiche pizzas come from the 11"/15" master sheets (built below) — skip the
    // single-size cookbook versions so each pizza appears once with both sizes.
    if (cb.category === "Pizza" && cb.brand === "capiche") continue;
    let totalGrams = 0;
    let rawCost = 0;
    let anyPriced = false;
    cb.ingredients.forEach((ing, idx) => {
      let matId = matByName.get(norm(ing.name));
      if (!matId) {
        let id = "m-cb-" + slugify(ing.name);
        while (usedMatIds.has(id)) id += "-x";
        usedMatIds.add(id);
        matId = id;
        matByName.set(norm(ing.name), id);
        const pg = masterPerGram(ing.name); // ₹ per base unit (the book costs per-gram)
        const cpbu = pg ?? null;
        cpbuById.set(id, cpbu);
        raw_materials.push({
          id,
          ingredient_name: ing.name,
          category: inferCategory(ing.name),
          supplier_name: null,
          notes: null,
          purchase_price: pg == null ? null : ing.unit === "Piece" ? round2(pg) : round2(pg * 1000),
          purchase_quantity: 1,
          purchase_unit: purchaseUnitFor(ing.unit),
          base_unit: ing.unit,
          cost_per_base_unit: cpbu,
          last_price_update: pg == null ? null : SEED_TS.slice(0, 10),
          status: "active",
          created_by: U_ADMIN,
          created_at: SEED_TS,
        });
      }
      const cpbu = cpbuById.get(matId) ?? null;
      const lineCost = cpbu == null ? null : round2(ing.qty * cpbu);
      if (lineCost != null) {
        rawCost += lineCost;
        anyPriced = true;
      }
      recipe_ingredients.push({
        id: `${cb.id}-i${idx}`,
        recipe_id: cb.id,
        ingredient_id: matId,
        component_type: "material",
        quantity_used: ing.qty,
        unit_used: ing.unit,
        calculated_cost: lineCost,
        sort_order: idx,
      });
      if (ing.unit === "Gram") totalGrams += ing.qty;
    });
    // Prefer the master summary's authoritative per-dish making/packaging/selling
    // when the dish is listed there; otherwise use the ingredient-derived making cost.
    const ingredientTotal = anyPriced ? round2(rawCost * (1 + WASTAGE_PCT / 100)) : null;
    const ingredientPerPortion =
      ingredientTotal != null && cb.serving_size > 0 ? round2(ingredientTotal / cb.serving_size) : ingredientTotal;
    const dc = dishCostFor(cb.name);
    const total = dc && dc.making != null ? dc.making : ingredientTotal;
    const perPortion = dc && dc.making != null ? dc.making : ingredientPerPortion;
    recipes.push({
      id: cb.id,
      recipe_name: cb.name,
      category: cb.category,
      brand: cb.brand,
      description: null,
      method: cb.method ?? [],
      image_url: null,
      preparation_time: null,
      serving_size: cb.serving_size,
      status: "approved",
      selling_price: dc ? dc.selling : null,
      packaging_cost: dc ? dc.packaging : 0,
      total_cost: total,
      cost_per_portion: perPortion,
      wastage_pct: WASTAGE_PCT,
      is_prep: false,
      yield_quantity: cb.yield_grams > 0 ? cb.yield_grams : round2(totalGrams),
      yield_unit: "Gram",
      created_by: U_EDITOR,
      approved_by: U_ADMIN,
      approved_at: "2026-06-20T09:30:00.000Z",
      rejection_note: null,
      version_no: 1,
      created_at: SEED_TS,
      updated_at: SEED_TS,
      updated_by: U_ADMIN,
    });
  }
}

// --- Consolidate cut-specific materials under their parent vegetable ----------
// A material whose name encodes a known cut ("Sliced Onion", "Onion Rings",
// "Chopped Spring Onion") is folded into its parent vegetable + a cut_type on the
// recipe line, so recipes show one "Onion" with a cut option bar. The cut's yield
// re-prices the line; the now-unused cut-specific material is deactivated.
{
  const cnorm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();
  const matById = new Map(raw_materials.map((m) => [m.id, m]));
  const matByName = new Map(raw_materials.map((m) => [cnorm(m.ingredient_name), m]));
  const folded = new Set<string>();
  const foldedRecipes = new Set<string>();
  for (const line of recipe_ingredients) {
    if (line.component_type !== "material") continue;
    const m = matById.get(line.ingredient_id);
    if (!m) continue;
    const { parent, cut } = resolveParentAndCut(m.ingredient_name);
    if (!parent || !cut) continue; // only fold names that encode a known cut
    const parentMat = matByName.get(parent);
    if (!parentMat || parentMat.id === m.id) continue;
    line.ingredient_id = parentMat.id;
    line.cut_type = cut;
    const y = cutYieldPct(parent, cut);
    const rate = y != null ? costForCutYield(parentMat.cost_per_base_unit, y) : parentMat.cost_per_base_unit;
    line.calculated_cost =
      rate != null && canConvert(line.unit_used, parentMat.base_unit)
        ? calculateIngredientCost(rate, line.quantity_used, line.unit_used, parentMat.base_unit)
        : null;
    folded.add(m.id);
    foldedRecipes.add(line.recipe_id);
  }
  // Keep totals consistent with the rewritten lines. Recipes pinned to a master
  // dish cost keep that authoritative making cost; the rest re-sum their lines.
  for (const rid of foldedRecipes) {
    const rec = recipes.find((r) => r.id === rid);
    if (!rec) continue;
    const dc = dishCostFor(rec.recipe_name);
    if (dc && dc.making != null) continue;
    const raw = recipe_ingredients
      .filter((l) => l.recipe_id === rid)
      .reduce((s, l) => s + (l.calculated_cost ?? 0), 0);
    const total = raw > 0 ? round2(raw * (1 + (rec.wastage_pct ?? 0) / 100)) : null;
    rec.total_cost = total;
    rec.cost_per_portion = total != null && rec.serving_size > 0 ? round2(total / rec.serving_size) : total;
  }
  // Deactivate folded materials no longer referenced by any line.
  for (const id of folded) {
    const stillUsed = recipe_ingredients.some((l) => l.component_type === "material" && l.ingredient_id === id);
    if (!stillUsed) {
      const mm = matById.get(id);
      if (mm) mm.status = "inactive";
    }
  }
}

// --- Pizza size variants (Capiche, from the 11"/15" master sheets) -----------
// One master per pizza (the 15-inch, shown in lists) plus an 11-inch variant
// linked by parent_recipe_id. Each size carries its own ingredient quantities and
// cost. Ingredients are priced from the master book; the 15" master takes its
// authoritative making/selling from the summary, the 11" is costed from its lines.
{
  const pnorm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();
  const matByName = new Map(raw_materials.map((m) => [pnorm(m.ingredient_name), m.id]));
  const cpbuById = new Map(raw_materials.map((m) => [m.id, m.cost_per_base_unit]));
  const usedMatIds = new Set(raw_materials.map((m) => m.id));
  const slugify = (s: string) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const purchaseUnitFor = (base: string) => (base === "Gram" ? "KG" : base === "ML" ? "Litre" : "Piece");

  const buildVariant = (
    id: string,
    name: string,
    parentId: string | null,
    size: PizzaSize,
    ings: { name: string; qty: number; unit: "Gram" }[],
    dc: (typeof MASTER_DISH_COSTS)[string] | null,
  ) => {
    let totalGrams = 0;
    let rawCost = 0;
    let anyPriced = false;
    ings.forEach((ing, idx) => {
      let matId = matByName.get(pnorm(ing.name));
      if (!matId) {
        let mid = "m-cb-" + slugify(ing.name);
        while (usedMatIds.has(mid)) mid += "-x";
        usedMatIds.add(mid);
        const pg = masterPerGram(ing.name);
        cpbuById.set(mid, pg ?? null);
        raw_materials.push({
          id: mid,
          ingredient_name: ing.name,
          category: inferCategory(ing.name),
          supplier_name: null,
          notes: null,
          purchase_price: pg == null ? null : round2(pg * 1000),
          purchase_quantity: 1,
          purchase_unit: purchaseUnitFor(ing.unit),
          base_unit: ing.unit,
          cost_per_base_unit: pg ?? null,
          last_price_update: pg == null ? null : SEED_TS.slice(0, 10),
          status: "active",
          created_by: U_ADMIN,
          created_at: SEED_TS,
        });
        matByName.set(pnorm(ing.name), mid);
        matId = mid;
      }
      const cpbu = cpbuById.get(matId) ?? null;
      const lineCost = cpbu == null ? null : round2(ing.qty * cpbu);
      if (lineCost != null) {
        rawCost += lineCost;
        anyPriced = true;
      }
      recipe_ingredients.push({
        id: `${id}-i${idx}`,
        recipe_id: id,
        ingredient_id: matId,
        component_type: "material",
        quantity_used: ing.qty,
        unit_used: ing.unit,
        calculated_cost: lineCost,
        sort_order: idx,
      });
      if (ing.unit === "Gram") totalGrams += ing.qty;
    });
    const ingredientTotal = anyPriced ? round2(rawCost * (1 + WASTAGE_PCT / 100)) : null;
    const making = dc && dc.making != null ? dc.making : ingredientTotal;
    recipes.push({
      id,
      recipe_name: name,
      category: "Pizza",
      brand: "capiche",
      description: null,
      method: [],
      parent_recipe_id: parentId,
      size_code: size,
      size_label: PIZZA_SIZE_LABEL[size],
      image_url: null,
      preparation_time: null,
      serving_size: 1,
      status: "approved",
      selling_price: dc ? dc.selling : null,
      packaging_cost: dc ? dc.packaging : 0,
      total_cost: making,
      cost_per_portion: making,
      wastage_pct: WASTAGE_PCT,
      is_prep: false,
      yield_quantity: round2(totalGrams),
      yield_unit: "Gram",
      created_by: U_EDITOR,
      approved_by: U_ADMIN,
      approved_at: "2026-06-20T09:30:00.000Z",
      rejection_note: null,
      version_no: 1,
      created_at: SEED_TS,
      updated_at: SEED_TS,
      updated_by: U_ADMIN,
    });
  };

  for (const pz of PIZZA_RECIPES) {
    const masterId = "r-pizza-" + slugify(pz.name);
    const dc = dishCostFor(pz.name);
    const fifteen = pz.variants["15_INCH"];
    const eleven = pz.variants["11_INCH"];
    const masterIngs = fifteen ?? eleven;
    if (!masterIngs) continue;
    buildVariant(masterId, pz.name, null, fifteen ? "15_INCH" : "11_INCH", masterIngs, dc);
    if (fifteen && eleven) buildVariant(`${masterId}-11`, pz.name, masterId, "11_INCH", eleven, null);
  }
}

export function buildSeed(): MockDb {
  return {
    // Yield + wastage start empty; seed real entries from the app.
    ingredient_yields: [],
    wastage_entries: [],
    users: structuredClone(users),
    raw_materials: structuredClone(raw_materials),
    recipes: structuredClone(recipes),
    recipe_ingredients: structuredClone(recipe_ingredients),
    recipe_cost_history: [],
    ingredient_price_history: [],
    recipe_versions: allDefs.map((d) => ({
      id: `${d.id}-v1`, recipe_id: d.id, version_no: 1, snapshot: null, notes: "Initial version", created_by: d.createdBy, created_at: SEED_TS,
    })),
    user_recipe_views: [],
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
          "In-House Prep",
        ]),
        updated_by: U_ADMIN, updated_at: SEED_TS,
      },
      {
        id: "s-recipe-categories",
        key: "recipe_categories",
        value: JSON.stringify([
          "Pasta", "Pizza", "Sushi", "Mains", "Appetizers", "Small Plates",
          "Sides", "Salad", "Dessert", "Beverage", "In-House Prep",
        ]),
        updated_by: U_ADMIN, updated_at: SEED_TS,
      },
    ],
  };
}
