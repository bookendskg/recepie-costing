// Seed data — Capiche & Aiko menu recipes plus in-house prep sub-recipes from
// the kitchen costing sheet. Menu recipes reference prep recipes as components
// (component_type "recipe"); preps are costed from leaf raw materials and a
// prep's per-unit cost = total_cost ÷ yield (sum of its ingredient grams).

import { calculateCostPerBaseUnit, prepUnitCostFrom } from "../costing";
import type { MockDb } from "./mock/db";
import type { Brand, RawMaterial, Recipe, RecipeIngredient, User } from "./types";

const SEED_TS = "2026-06-01T09:00:00.000Z";
const round2 = (n: number) => parseFloat(n.toFixed(2));

// --- Users -----------------------------------------------------------------
const U_ADMIN = "u-admin";
const U_EDITOR = "u-editor";
const U_VIEWER = "u-viewer";

const users: User[] = [
  { id: U_ADMIN, name: "Rahul Sharma", email: "rahul@brand.com", role: "admin", status: "active", password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_EDITOR, name: "Priya Patel", email: "priya@brand.com", role: "editor", status: "active", password: "password123", created_at: SEED_TS, updated_at: SEED_TS },
  { id: U_VIEWER, name: "Amit Roy", email: "amit@brand.com", role: "viewer", status: "active", password: "password123", accessible_brands: ["aiko"], show_cost: true, created_at: SEED_TS, updated_at: SEED_TS },
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
const matPerGram = new Map(matDefs.map((d) => [d.id, d.perGram]));

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

const menuDefs: RecipeDef[] = [
  { id: "r-aglio-olio", name: "Aglio Olio", category: "Pasta", brand: "capiche", isPrep: false, description: "Garlic and olive oil spaghetti with chilli and parmesan.", prep: 20, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, selling: 740, lines: [
    { m: "m-butter", g: 20 }, { m: "m-garlic-peeled", g: 20 }, { m: "m-olive-oil", g: 15 }, { m: "m-black-pepper", g: 1.5 }, { m: "m-spaghetti", g: 190 }, { m: "m-chilli-flakes", g: 3 }, { m: "m-salt", g: 3 }, { m: "m-parmesan", g: 8 }, { m: "m-green-garlic", g: 4 }, { m: "m-spring-onion-chopped", g: 5 }, { m: "m-parsley", g: 5 }, { m: "m-fried-garlic", g: 5 }, { r: "r-prep-chilli-crisp", g: 5 },
  ] },
  { id: "r-pesto-bucatini", name: "Pesto Bucatini", category: "Pasta", brand: "capiche", isPrep: false, description: "Bucatini in a creamy basil pesto with parmesan.", prep: 25, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, selling: 740, lines: [
    { m: "m-bucatini", g: 120 }, { m: "m-butter", g: 20 }, { m: "m-olive-oil", g: 5 }, { m: "m-black-pepper", g: 1 }, { m: "m-salt", g: 3 }, { r: "r-prep-pesto-white-base", g: 70 }, { m: "m-parmesan", g: 8 }, { m: "m-chilli-flakes", g: 3 }, { r: "r-prep-hydroponic-pesto", g: 55 }, { m: "m-red-paprika", g: 2 },
  ] },
  { id: "r-chilli-crunch-pizza", name: "Chilli Crunch Pizza", category: "Pizza", brand: "capiche", isPrep: false, description: "Wood-fired pizza with burrata, bechamel and chilli crunch.", prep: 18, status: "testing", createdBy: U_EDITOR, selling: 929, lines: [
    { r: "r-prep-pizza-dough", g: 180 }, { m: "m-mozzarella", g: 60 }, { r: "r-prep-bechamel", g: 50 }, { r: "r-prep-chili-crunch-sauce", g: 100 }, { m: "m-burrata", g: 130 }, { m: "m-black-sesame", g: 6 }, { m: "m-coriander", g: 8 }, { m: "m-spring-onion", g: 8 }, { m: "m-basil", g: 8 }, { m: "m-dill-leaves", g: 8 }, { m: "m-chilli-crisp-oil", g: 8 }, { m: "m-rice-flour", g: 10 },
  ] },
  { id: "r-avo-crispy-rice", name: "Avo Crispy Rice", category: "Sushi", brand: "aiko", isPrep: false, description: "Crispy sushi rice with avocado, ponzu wasabi mayo and beetroot.", prep: 15, status: "approved", createdBy: U_EDITOR, approvedBy: U_ADMIN, selling: 840, lines: [
    { r: "r-prep-sesame-sushi-rice", g: 156 }, { r: "r-prep-ponzu-wasabi-mayo", g: 2 }, { m: "m-gochujang-mayo", g: 4 }, { m: "m-avo-guac", g: 20 }, { r: "r-prep-beetroot", g: 68 }, { m: "m-bagel-seasoning", g: 5 }, { m: "m-white-spring-onion", g: 18 },
  ] },
  { id: "r-sl-red-curry", name: "Sri Lankan Red Curry", category: "Mains", brand: "aiko", isPrep: false, description: "Tofu and mushroom red curry in spiced coconut milk.", prep: 35, status: "draft", createdBy: U_EDITOR, selling: 640, lines: [
    { m: "m-oil", g: 10 }, { m: "m-kashmiri-chilli-powder", g: 2.5 }, { m: "m-kashmiri-red-paste", g: 10 }, { r: "r-prep-sl-red-paste", g: 10 }, { r: "r-prep-tamarind-water", g: 15 }, { m: "m-coconut-milk", g: 200 }, { m: "m-stock-water", g: 100 }, { m: "m-water", g: 50 }, { m: "m-msg", g: 3 }, { m: "m-salt", g: 2 }, { m: "m-white-pepper", g: 2 }, { m: "m-stock-powder", g: 2 }, { r: "r-prep-sl-curry-powder", g: 1 }, { m: "m-tofu", g: 20 }, { m: "m-carrot", g: 20 }, { m: "m-mushroom", g: 20 }, { m: "m-shimeji", g: 20 }, { m: "m-basil", g: 2 }, { m: "m-picked-red-paprika", g: 5 }, { m: "m-slit-onion", g: 2 }, { m: "m-red-chilli-oil", g: 1 }, { m: "m-fried-onion", g: 10 },
  ] },
];

const WASTAGE_PCT = 5; // standard wastage from the costing sheet

const allDefs = [...prepDefs, ...menuDefs];
const defById = new Map(allDefs.map((d) => [d.id, d]));
const yieldOf = (d: RecipeDef) => d.lines.reduce((s, l) => s + l.g, 0) || 1;

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
      raw += round2((matPerGram.get(l.m) ?? 0) * l.g);
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
      : round2((matPerGram.get(refId) ?? 0) * l.g);
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
    image_url: null,
    preparation_time: d.prep,
    serving_size: 1,
    status: d.status,
    selling_price: d.selling ?? null,
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
    recipe_versions: allDefs.map((d) => ({
      id: `${d.id}-v1`, recipe_id: d.id, version_no: 1, snapshot: null, notes: "Initial version", created_by: d.createdBy, created_at: SEED_TS,
    })),
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
