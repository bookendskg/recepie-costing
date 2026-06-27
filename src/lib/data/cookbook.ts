// AUTO-GENERATED from the Capiche & Aiko cookbooks (assets/*.pdf) — do not hand-edit.
// Ingredient quantities are the net weights printed on each recipe page. Prices are
// intentionally omitted; they are supplied later in the app and costs recompute then.
// 93 recipes · regenerate from the cookbook PDFs if the source changes.

export interface CookbookIngredient {
  name: string;
  qty: number;
  unit: "Gram" | "ML" | "Piece";
}

export interface CookbookRecipe {
  id: string;
  brand: "capiche" | "aiko";
  code: string;
  name: string;
  category: string;
  serving_size: number;
  /** Net dish weight in grams (0 if the page didn't state it). */
  yield_grams: number;
  ingredients: CookbookIngredient[];
}

export const COOKBOOK_RECIPES: CookbookRecipe[] = [
  {
    "id": "r-sl-02",
    "brand": "capiche",
    "code": "SL-02",
    "name": "Burrata Salad",
    "category": "Salads",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Arugula",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Iceberg",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Romaine",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Curly romaine",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Cherry tomato",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Grapefruit",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pine nuts",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Black olives",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Vinaigrette",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Sea salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Hot honey",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Edible flower",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Baby burrata",
        "qty": 80,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sl-01",
    "brand": "capiche",
    "code": "SL-01",
    "name": "Caesar Salad",
    "category": "Salads",
    "serving_size": 1,
    "yield_grams": 200,
    "ingredients": [
      {
        "name": "Romaine",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Iceberg",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Parmesan (grated)",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Crispy croutons",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Caesar mayo",
        "qty": 50,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sl-03",
    "brand": "capiche",
    "code": "SL-03",
    "name": "Burrata Salad",
    "category": "Salads",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Burrata cheese",
        "qty": 127,
        "unit": "Gram"
      },
      {
        "name": "Iceberg, romaine, purple cabbage, arugula",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Sundried tomato pesto",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Confit cherry tomato",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Hazelnut",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Fried fettuccine chip",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Seasoning TT",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Whole red chilli",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 125,
        "unit": "Gram"
      },
      {
        "name": "Sundried tomato",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Vinegar",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Lemon juice",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Boiled chickpeas",
        "qty": 50,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pr-a01",
    "brand": "capiche",
    "code": "PR-A01",
    "name": "Persimmon Salad",
    "category": "Salads",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Arugula",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Vinaigrette",
        "qty": 12,
        "unit": "Gram"
      },
      {
        "name": "Persimmon",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Strawberry",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Burrata",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Caviar",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Pine nuts",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Edible flowers",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Hot honey",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-s01",
    "brand": "capiche",
    "code": "CA-S01",
    "name": "Summer Burrata Salad",
    "category": "Salads",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Processed Iceberg lettuce",
        "qty": 31,
        "unit": "Gram"
      },
      {
        "name": "Processed Romaine lettuce",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Processed Lollo Rosso",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Vinaigrette",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Arugula",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Burrata",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Crushed black pepper",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Roasted hazelnuts",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Granola (chopped)",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Mango (cubed)",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Grapefruit (cubed)",
        "qty": 35,
        "unit": "Gram"
      },
      {
        "name": "Cherry tomatoes",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Edible flowers",
        "qty": 3,
        "unit": "Piece"
      },
      {
        "name": "Hot honey drizzle",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sp-01",
    "brand": "capiche",
    "code": "SP-01",
    "name": "Roasted Red Bell Pepper Soup",
    "category": "Soups",
    "serving_size": 1,
    "yield_grams": 370,
    "ingredients": [
      {
        "name": "Red bell peppers",
        "qty": 650,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 16,
        "unit": "Gram"
      },
      {
        "name": "Tomato",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Roasted bell pepper paste",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 160,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Hot sauce",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Sour cream",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pesto",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Sourdough",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Garlic butter",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sn-01",
    "brand": "capiche",
    "code": "SN-01",
    "name": "Arancini",
    "category": "Appetiser",
    "serving_size": 6,
    "yield_grams": 117,
    "ingredients": [
      {
        "name": "Cooked risotto rice mix",
        "qty": 96,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella",
        "qty": 18,
        "unit": "Gram"
      },
      {
        "name": "Arancini batter",
        "qty": 96,
        "unit": "Gram"
      },
      {
        "name": "Panko crumbs",
        "qty": 12,
        "unit": "Gram"
      },
      {
        "name": "Frying oil",
        "qty": 0,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-sn-02",
    "brand": "capiche",
    "code": "SN-02",
    "name": "Dough Balls",
    "category": "Appetiser",
    "serving_size": 1,
    "yield_grams": 150,
    "ingredients": [
      {
        "name": "Dough",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Green garlic",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sn-03",
    "brand": "capiche",
    "code": "SN-03",
    "name": "Garlic Bread",
    "category": "Appetiser",
    "serving_size": 1,
    "yield_grams": 105,
    "ingredients": [
      {
        "name": "Bread base",
        "qty": 105,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Green garlic (garnish)",
        "qty": 7,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-10",
    "brand": "capiche",
    "code": "PS-10",
    "name": "Pasta Fritti 2.0",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Ricotta",
        "qty": 200,
        "unit": "Gram"
      },
      {
        "name": "Oregano",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chilli flakes",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Thyme",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt & pepper",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Pasta sheet 22 g x 2",
        "qty": 44,
        "unit": "Gram"
      },
      {
        "name": "Tomato paste",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella 20 g each",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Ricotta filling 15 g each",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Batter",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Bread crumbs",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Seasoning",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-08",
    "brand": "capiche",
    "code": "PS-08",
    "name": "Butter Garlic Mushroom",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Mushroom",
        "qty": 280,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 23,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cowboy Butter",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Vinaigrette",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Chilli flakes",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-v01",
    "brand": "capiche",
    "code": "CA-V01",
    "name": "Saucy Brussels Sprouts",
    "category": "Vegetable",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Olive oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Brussels sprouts (halved)",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Garlic (chopped)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Red chilli flakes",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Balsamic vinegar",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt & black pepper",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 230,
        "unit": "Gram"
      },
      {
        "name": "Béchamel sauce",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Sour cream",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Plain mayonnaise",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Salt & black pepper",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Fresh Bhavnagri chilli",
        "qty": 4,
        "unit": "Piece"
      },
      {
        "name": "Pickled onions",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Feta crumbles",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-ts01",
    "brand": "capiche",
    "code": "CA-TS01",
    "name": "Miso Tomato Soup",
    "category": "Soups",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Olive oil",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Onion",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Tomatoes",
        "qty": 800,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 11,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 500,
        "unit": "ML"
      },
      {
        "name": "White miso paste",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Chili flakes (or fresh red chili - 5 g, deseeded)",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce (optional)",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Salt",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Basil (fresh, chopped)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Thyme (sprigs) (simmer, remove before blending)",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Bay leaf (remove before blending)",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Parsley stems (optional, simmer with base)",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-02",
    "brand": "capiche",
    "code": "PS-02",
    "name": "Pomodoro Spaghetti",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Cherry tomato",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 220,
        "unit": "Gram"
      },
      {
        "name": "Boiled spaghetti",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 6.8,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Chilli flakes",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-03",
    "brand": "capiche",
    "code": "PS-03",
    "name": "Spicy Tomato & Cream Macaroni",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Boiled macaroni",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Hot sauce",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Fresh cream",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Orange (creamy tomato) sauce",
        "qty": 200,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-05",
    "brand": "capiche",
    "code": "PS-05",
    "name": "Alfredo Fettuccine",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Boiled fettuccine",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Béchamel",
        "qty": 190,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Thyme",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 100,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-06",
    "brand": "capiche",
    "code": "PS-06",
    "name": "Lemon Linguini",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Boiled linguini",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "White sauce",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Mascarpone",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Lemon zest",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Lemon juice",
        "qty": 18,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Pepper",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-07",
    "brand": "capiche",
    "code": "PS-07",
    "name": "Risotto",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 250,
    "ingredients": [
      {
        "name": "Cooked arborio rice",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Asparagus",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Peas",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Béchamel",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 100,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-10-x",
    "brand": "capiche",
    "code": "PS-10",
    "name": "Lasagna",
    "category": "Pasta",
    "serving_size": 7,
    "yield_grams": 1300,
    "ingredients": [
      {
        "name": "Soy chunks (textured)",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Onion (diced)",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Carrot (diced)",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Celery (diced)",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Garlic (chopped)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Tomato passata",
        "qty": 400,
        "unit": "Gram"
      },
      {
        "name": "Tomato paste",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Dried oregano",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Plain flour",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Milk",
        "qty": 500,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Nutmeg",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Lasagna sheets (oven-ready)",
        "qty": 6,
        "unit": "Piece"
      },
      {
        "name": "Mozzarella (shredded)",
        "qty": 200,
        "unit": "Gram"
      },
      {
        "name": "Parmesan (grated)",
        "qty": 30,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ps-11",
    "brand": "capiche",
    "code": "PS-11",
    "name": "Stuffed Conchiglioni",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Ricotta cheese",
        "qty": 250,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Blanched kale",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Chopped jalapeño",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Xanthan gum",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Conchiglioni",
        "qty": 5,
        "unit": "Piece"
      },
      {
        "name": "Garlic pomodoro sauce",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Red paprika",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Slit onion",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Sunflower seeds",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pa-07",
    "brand": "capiche",
    "code": "PA-07",
    "name": "Caramelised Onion Pasta",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Olive oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Caramelised onion",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "1 ladle water",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Spaghetti",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Mix seasoning",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Fresh cream",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Soya sauce",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chill crisp",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Parsley",
        "qty": 1,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-ca-p02",
    "brand": "capiche",
    "code": "CA-P02",
    "name": "Pink Burrata Pasta",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Beetroot paste",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Farfalle pasta",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Pesto white base sauce",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Chilli flakes",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Burrata (smashed)",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Pumpkin seeds & pistachios (crushed & mixed)",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Crushed black pepper",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-r01",
    "brand": "capiche",
    "code": "CA-R01",
    "name": "Tomato Butter Risotto",
    "category": "Risotto",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Olive oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 50,
        "unit": "ML"
      },
      {
        "name": "Salt",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Risotto rice",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Confit cherry tomatoes",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pesto dollop",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Arugula",
        "qty": 5,
        "unit": "Piece"
      },
      {
        "name": "Kalonji (chopped)",
        "qty": 1,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-p01",
    "brand": "capiche",
    "code": "CA-P01",
    "name": "Truffle Mac & Cheese",
    "category": "Pasta",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Macaroni pasta",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Béchamel sauce",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Cheddar cheese",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella cheese",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cheddar cheese",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella cheese",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Truffle oil",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Truffle pâté",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 0.5,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-pz-01",
    "brand": "capiche",
    "code": "PZ-01",
    "name": "Margherita",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella (grated)",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 5,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-pz-02",
    "brand": "capiche",
    "code": "PZ-02",
    "name": "Peperone",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella (grated)",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Bell pepper",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Green chilli",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 35,
        "unit": "Gram"
      },
      {
        "name": "Black olives",
        "qty": 20,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-03",
    "brand": "capiche",
    "code": "PZ-03",
    "name": "Sid's Pizza",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Fresh jalapeño",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Marinated arugula (post-bake)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Ricotta (post-bake)",
        "qty": 80,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-04",
    "brand": "capiche",
    "code": "PZ-04",
    "name": "Ortolana",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 515,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Jalapeño",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Black olive",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Broccoli",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Green bell pepper",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Marinated arugula (post-bake)",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Sliced almonds (garnish)",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-05",
    "brand": "capiche",
    "code": "PZ-05",
    "name": "Third Wave",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 420,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Boiled broccoli",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Peeled garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Red paprika",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Jalapeños",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Chilli crisp (finish)",
        "qty": 15,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-06",
    "brand": "capiche",
    "code": "PZ-06",
    "name": "Garlic Pie",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 410,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Sliced garlic",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Green garlic (garnish)",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-07",
    "brand": "capiche",
    "code": "PZ-07",
    "name": "Truffle",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Truffle paste (post-bake)",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Truffle oil (post-bake)",
        "qty": 3,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-pz-08",
    "brand": "capiche",
    "code": "PZ-08",
    "name": "Rubirosa",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Tomato cream (spicy pomodoro)",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro (dollops)",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pesto (post-bake)",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Sriracha (swirl post-bake)",
        "qty": 15,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-09",
    "brand": "capiche",
    "code": "PZ-09",
    "name": "Triple Sauce",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 340,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Tomato cream",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Pesto",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Parmesan",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-10",
    "brand": "capiche",
    "code": "PZ-10",
    "name": "Burrata Hot Honey",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Oregano",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 5,
        "unit": "ML"
      },
      {
        "name": "Burrata (post-bake)",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Hot honey (post-bake)",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Garlic oil (post-bake)",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Gochugaru (garnish)",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-11",
    "brand": "capiche",
    "code": "PZ-11",
    "name": "Apollo",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Garlic slice",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Red paprik",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Zucchini",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Artichoke",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Caramelised onion",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Feta 10 g (post-bake)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Marinated arugula (garnish)",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Breadcrumbs (garnish)",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-12",
    "brand": "capiche",
    "code": "PZ-12",
    "name": "Affair",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 462,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Spicy pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Peeled garlic",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Capers",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Button mushrooms",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Shimeji mushrooms",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Garlic ricotta (post-bake)",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Spring onion (garnish)",
        "qty": 8,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-15",
    "brand": "capiche",
    "code": "PZ-15",
    "name": "Picante",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 411,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Chili oil",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Ghost pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Roasted bell pepper",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Gochugaru",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Garlic slice",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Green chilli",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Red paprika",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Jalapeño",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-16",
    "brand": "capiche",
    "code": "PZ-16",
    "name": "Diavolo",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 425,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Pomodoro",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "In-house jalapeño",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Vegan nduja",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Pickled onion (post-bake)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-19",
    "brand": "capiche",
    "code": "PZ-19",
    "name": "Hulk",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 395,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella grated",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Sriracha 10 g (mix)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Amul fresh cream 90 g (mix)",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Pesto 10 g (mix)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella 15 g",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Sour cream 20 g (post-bake)",
        "qty": 20,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-pz-21",
    "brand": "capiche",
    "code": "PZ-21",
    "name": "Potato Pie Pizza",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Leek cream cheese sauce",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Buffalo mozzarella",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Mozzarella (grated)",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Green chilli",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Garlic slices",
        "qty": 9,
        "unit": "Gram"
      },
      {
        "name": "Marinated potato",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Parmesan cheese",
        "qty": 9,
        "unit": "Gram"
      },
      {
        "name": "Olive oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "After Bake: Spicy pesto",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "After Bake: Bell pepper jam",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "After Bake: Fried potato julienne",
        "qty": 25,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ca-pz01",
    "brand": "capiche",
    "code": "CA-PZ01",
    "name": "Hell Boy Pizza",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Pizza dough",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Pomodoro sauce",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Red Sriracha",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Smoked cheese (grated)",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Cheddar cheese (grated)",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Garlic slices (roasted or raw)",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 170,
        "unit": "Gram"
      },
      {
        "name": "Honey",
        "qty": 85,
        "unit": "Gram"
      },
      {
        "name": "Fermented red chilli",
        "qty": 500,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 160,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 250,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Vinegar",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Chimichurri (chunky)",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Whipped feta dollop",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Honey butter drizzle",
        "qty": 1,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-ca-pz02",
    "brand": "capiche",
    "code": "CA-PZ02",
    "name": "Chilli Butter Corn Pizza",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Grilled corn",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Mayonnaise",
        "qty": 45,
        "unit": "Gram"
      },
      {
        "name": "Sour cream",
        "qty": 45,
        "unit": "Gram"
      },
      {
        "name": "Parmesan cheese",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Tajín",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Lime (juice + zest)",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Coriander (chopped)",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Fresh cream",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Garlic (chopped)",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Lemon juice",
        "qty": 0.8,
        "unit": "Gram"
      },
      {
        "name": "Butter",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Chilli crisp",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Red chilli powder",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chilli butter dollop",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Gochugaru",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Dynamite crunch",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-01",
    "brand": "capiche",
    "code": "DS-01",
    "name": "Sticky Toffee Pudding",
    "category": "Desserts",
    "serving_size": 1,
    "yield_grams": 215,
    "ingredients": [
      {
        "name": "Sticky toffee pudding",
        "qty": 105,
        "unit": "Gram"
      },
      {
        "name": "Caramel sauce",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Pecan ice cream",
        "qty": 60,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-04",
    "brand": "capiche",
    "code": "DS-04",
    "name": "Brownie With Ice Cream",
    "category": "Desserts",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Brownie",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Cookies & cream ice cream",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Nutella sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Caramel tuile",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-02",
    "brand": "capiche",
    "code": "DS-02",
    "name": "Pistachio Mousse Cake",
    "category": "Desserts",
    "serving_size": 1,
    "yield_grams": 140,
    "ingredients": [
      {
        "name": "Kunafa base",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Pistachio sponge",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pistachio mousse",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "White chocolate décor",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-05",
    "brand": "capiche",
    "code": "DS-05",
    "name": "Tiramisu 3.0",
    "category": "Desserts",
    "serving_size": 1,
    "yield_grams": 115,
    "ingredients": [
      {
        "name": "Coffee sponge",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Mascarpone mousse",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Coffee cream",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Sable",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Tuile décor",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-dr-01",
    "brand": "capiche",
    "code": "DR-01",
    "name": "Lemon Iced Tea",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 300,
    "ingredients": [
      {
        "name": "Lemon juice",
        "qty": 30,
        "unit": "ML"
      },
      {
        "name": "Sugar syrup",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Iced tea (Tata Gold)",
        "qty": 210,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-dr-02",
    "brand": "capiche",
    "code": "DR-02",
    "name": "Mint Mojito",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 245,
    "ingredients": [
      {
        "name": "Lemon juice",
        "qty": 30,
        "unit": "ML"
      },
      {
        "name": "Mint syrup",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Kinley Soda",
        "qty": 200,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-dr-03",
    "brand": "capiche",
    "code": "DR-03",
    "name": "Pina Colada",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 300,
    "ingredients": [
      {
        "name": "Kara Coconut milk",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Amul Gold milk",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Pineapple jam",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Vanilla ice cream",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Ice",
        "qty": 60,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-dr-04",
    "brand": "capiche",
    "code": "DR-04",
    "name": "Moscow Mule",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 320,
    "ingredients": [
      {
        "name": "Lemon juice",
        "qty": 30,
        "unit": "ML"
      },
      {
        "name": "Fresh ginger zest",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Gunsberg Ginger Beer",
        "qty": 292.5,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-dr-05",
    "brand": "capiche",
    "code": "DR-05",
    "name": "Sunset Cocktail",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 230,
    "ingredients": [
      {
        "name": "Lemon juice",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Orange juice",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Hibiscus syrup",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Sprite",
        "qty": 140,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-dr-08",
    "brand": "capiche",
    "code": "DR-08",
    "name": "Tamarind Fizz",
    "category": "Drinks",
    "serving_size": 1,
    "yield_grams": 220,
    "ingredients": [
      {
        "name": "Tamarind syrup",
        "qty": 45,
        "unit": "ML"
      },
      {
        "name": "Pinch of salt",
        "qty": 1,
        "unit": "Piece"
      },
      {
        "name": "Schweppes Ginger Ale",
        "qty": 170,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-sd-001",
    "brand": "aiko",
    "code": "SD-001",
    "name": "Tom Yum",
    "category": "Soups",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Thai chilli",
        "qty": 18,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Shiitake mushroom",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Tamarind paste",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Vinegar",
        "qty": 60,
        "unit": "ML"
      },
      {
        "name": "Brown sugar",
        "qty": 50,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-002",
    "brand": "aiko",
    "code": "SD-002",
    "name": "Thai Spring Roll",
    "category": "Appetiser",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Spring Roll Sheets",
        "qty": 13.75,
        "unit": "Gram"
      },
      {
        "name": "Thai Spring Filling",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Sichuan Sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Coriander Leaves",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Spring Onion Slit",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Sriracha Sauce",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Black Vinegar",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-003",
    "brand": "aiko",
    "code": "SD-003",
    "name": "Kwispy Lotus Root",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Lotus root",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Lotus root sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pok choy",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Bell pepper",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Thai red chilli",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-004",
    "brand": "aiko",
    "code": "SD-004",
    "name": "Kwispy Wonton",
    "category": "Appetiser",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Kwispy Wonton filling",
        "qty": 75,
        "unit": "Gram"
      },
      {
        "name": "Gyoza skin",
        "qty": 5,
        "unit": "Piece"
      },
      {
        "name": "Corn slurry",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Chilli crisps",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Coriander",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Oil (for frying)",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-005",
    "brand": "aiko",
    "code": "SD-005",
    "name": "Tteokbokki",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Water",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Rice cake (16 pcs)",
        "qty": 133.33,
        "unit": "Gram"
      },
      {
        "name": "Tteokbokki sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 0.3,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Fried garlic",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Spring onion slit (garnish)",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-006",
    "brand": "aiko",
    "code": "SD-006",
    "name": "Tofu Bao",
    "category": "Dimsum",
    "serving_size": 1,
    "yield_grams": 223,
    "ingredients": [
      {
        "name": "Bao",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Tofu",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Tofu batter",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Coleslaw",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Black & white sesame",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Bao sauce base",
        "qty": 20,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-007",
    "brand": "aiko",
    "code": "SD-007",
    "name": "General Tso's Water Chestnuts",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Water chestnut",
        "qty": 190,
        "unit": "Gram"
      },
      {
        "name": "Water chestnut flour",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Gyoza dip",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Yellow bell pepper",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Red bell pepper",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Thai red chilli",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Chopped garlic",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Drunken sauce",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Fried spring roll (garnish)",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-008",
    "brand": "aiko",
    "code": "SD-008",
    "name": "Steamed Edamame (Chilli / Salted)",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 172,
    "ingredients": [
      {
        "name": "With pods edamame",
        "qty": 160,
        "unit": "Gram"
      },
      {
        "name": "Chilli Crisp (for chilli version)",
        "qty": 12,
        "unit": "Gram"
      },
      {
        "name": "Salt (for salted version)",
        "qty": 4,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-009",
    "brand": "aiko",
    "code": "SD-009",
    "name": "Korean Mandu",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 106,
    "ingredients": [
      {
        "name": "Korean Mandu filling",
        "qty": 75,
        "unit": "Gram"
      },
      {
        "name": "Gyoza skin",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Spicy mayo",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Coriander mayo",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Toasted white sesame seeds",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Julienne cut nori sheet",
        "qty": 1,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-010",
    "brand": "aiko",
    "code": "SD-010",
    "name": "Creamy Corn Rocks",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 244,
    "ingredients": [
      {
        "name": "Fried Corn",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Corn Rocks sauce",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chopped Black sesame seeds",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Chopped spring onion",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Pickled red paprika sliced",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Mayonnaise",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Sweet corn puree",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Condensed milk",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Lemon juice",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Garlic (minced)",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 0.5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-011",
    "brand": "aiko",
    "code": "SD-011",
    "name": "Kwispy Scallion Pancake",
    "category": "Sides",
    "serving_size": 1,
    "yield_grams": 267,
    "ingredients": [
      {
        "name": "Sunflower oil",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Scallion Pancake",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Sichuan soy glaze",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Green garlic cream cheese",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Sriracha sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Scallion salad",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Toasted white sesame seeds",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-sd-012",
    "brand": "aiko",
    "code": "SD-012",
    "name": "Cold Spicy Sesame Noodles",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 260,
    "ingredients": [
      {
        "name": "Boiled soba noodles",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Cold Spicy Sesame sauce",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Cucumber slice",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Carrot slice",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Fried sesame",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Peanut (crushed)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "White Part Spring Onion",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Mix iceberg romain slice",
        "qty": 15,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-tpz-001",
    "brand": "aiko",
    "code": "TPZ-001",
    "name": "Tokyo Style Pizza (Dough Base)",
    "category": "Pizza",
    "serving_size": 1,
    "yield_grams": 150,
    "ingredients": [
      {
        "name": "00 flour (Biga)",
        "qty": 1125,
        "unit": "Gram"
      },
      {
        "name": "Water (Biga)",
        "qty": 550,
        "unit": "Gram"
      },
      {
        "name": "Dry yeast (Biga)",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "00 flour",
        "qty": 2625,
        "unit": "Gram"
      },
      {
        "name": "Cold water",
        "qty": 1900,
        "unit": "Gram"
      },
      {
        "name": "Dry yeast",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "EVOO",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Brown sugar",
        "qty": 25,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-kc-001",
    "brand": "aiko",
    "code": "KC-001",
    "name": "Katsu Curry",
    "category": "Mains",
    "serving_size": 1,
    "yield_grams": 481,
    "ingredients": [
      {
        "name": "Katsu curry",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Tofu",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Cabbage",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Togarashi",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Sesame seeds",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Jasmine steamed rice",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Scallion oil",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Unagi sauce",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-tc-002",
    "brand": "aiko",
    "code": "TC-002",
    "name": "Thai Curry",
    "category": "Mains",
    "serving_size": 1,
    "yield_grams": 961,
    "ingredients": [
      {
        "name": "Zucchini",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Baby corn",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Bell pepper",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Mushroom",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Green paste",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Coconut milk",
        "qty": 200,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Jasmine rice",
        "qty": 250,
        "unit": "Gram"
      },
      {
        "name": "Sesame mix",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Lotus stem",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Scallion oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chilli oil",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-src-001",
    "brand": "aiko",
    "code": "SRC-001",
    "name": "Sri Lankan Curry",
    "category": "Mains",
    "serving_size": 1,
    "yield_grams": 507.5,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Kashmiri chilli powder",
        "qty": 2.5,
        "unit": "Gram"
      },
      {
        "name": "Kashmiri chilli red paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Sri Lankan Red paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Tamarind water",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Coconut milk",
        "qty": 200,
        "unit": "Gram"
      },
      {
        "name": "Stock water",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Msg",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Stock Powder",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Fresh Sri Lankan Red Curry Powder Mix",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Tofu",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Mushroom",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Shimeji mushroom",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Picked red paprika",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Slit onion",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Red chilli oil",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Fried onion",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-mn-004",
    "brand": "aiko",
    "code": "MN-004",
    "name": "Custom Stir Fry",
    "category": "Mains",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Chilli Garlic Sauce - Sunflower oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chilli Garlic Sauce - Chopped garlic",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Chilli Garlic Sauce - Soy sauce",
        "qty": 70,
        "unit": "Gram"
      },
      {
        "name": "Chilli Garlic Sauce - Hot sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Chilli Garlic Sauce - Wok hei sauce",
        "qty": 600,
        "unit": "Gram"
      },
      {
        "name": "Chilli Garlic Sauce - Thai red chilli",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Chilli bean",
        "qty": 500,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Shao hsing",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Soy sauce",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Black pepper",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Cinnamon powder",
        "qty": 1.5,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Sugar",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Wok Hei Sauce - Water",
        "qty": 225,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Brown sugar",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Soy sauce",
        "qty": 250,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Rice vinegar",
        "qty": 34,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Corn starch",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Water",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Teriyaki Sauce - Sesame seed",
        "qty": 9,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Black pepper",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Crushed black pepper",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Oyster sauce",
        "qty": 556,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Soy sauce",
        "qty": 566,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Sugar",
        "qty": 56.8,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Corn starch",
        "qty": 56.8,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Water",
        "qty": 1701,
        "unit": "Gram"
      },
      {
        "name": "Yaki Soba Sauce - Hot sauce",
        "qty": 20,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-001",
    "brand": "aiko",
    "code": "DS-001",
    "name": "Chestnut Gyoza",
    "category": "Dimsum",
    "serving_size": 6,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Chestnut",
        "qty": 550,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Red Bhavnagri chilli",
        "qty": 75,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 110,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 12,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Slurry",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Gyoza wrappers",
        "qty": 6,
        "unit": "Piece"
      },
      {
        "name": "Oil + Water (for steaming)",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-002",
    "brand": "aiko",
    "code": "DS-002",
    "name": "Okonomiyaki Gyoza (6 Pcs)",
    "category": "Dimsum",
    "serving_size": 6,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Ginger (paste)",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Chinese cabbage",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Indian cabbage",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Water chestnut",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "White spring onion",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Chilli besan paste",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Gochujang",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Soy",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Sesame oil",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Stock pwd",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Boiled soy keema",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Coriander leaf",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Coriander stem",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Tempura flakes",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Ketchup",
        "qty": 80,
        "unit": "Gram"
      },
      {
        "name": "Soy",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Maple",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Oyster",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Rice vinegar",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Flour",
        "qty": 17,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Salt (pinch)",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Mayo",
        "qty": 200,
        "unit": "Gram"
      },
      {
        "name": "Mustard",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-003",
    "brand": "aiko",
    "code": "DS-003",
    "name": "Truffle Edamame Dimsums",
    "category": "Dimsum",
    "serving_size": 4,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Blanched edamame",
        "qty": 250,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Black pepper",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Truffle oil",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Truffle pate",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wrappers",
        "qty": 4,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-ds-004",
    "brand": "aiko",
    "code": "DS-004",
    "name": "Saucy Momos",
    "category": "Dimsum",
    "serving_size": 5,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Indian cabbage",
        "qty": 500,
        "unit": "Gram"
      },
      {
        "name": "Onion",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Silken tofu",
        "qty": 175,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Tomato",
        "qty": 500,
        "unit": "Gram"
      },
      {
        "name": "Gochujang",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Gochugaru",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Coconut cream",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Honey",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Wrappers",
        "qty": 5,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-ds-005",
    "brand": "aiko",
    "code": "DS-005",
    "name": "Cheese Chilli Dumplings",
    "category": "Dimsum",
    "serving_size": 5,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Cream cheese",
        "qty": 95,
        "unit": "Gram"
      },
      {
        "name": "Tofu",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Chestnut",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Hot sauce",
        "qty": 3.5,
        "unit": "Gram"
      },
      {
        "name": "Shaoxing wine",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Jalapeños",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Green Bhavnagari chilli",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Kaffir lime leaf",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Lemongrass",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Tomato",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Sugar",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Cumin powder",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Hing",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Rice vinegar",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Lemon juice",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Basil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Coriander",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Wrappers",
        "qty": 5,
        "unit": "Piece"
      },
      {
        "name": "Fried onion",
        "qty": 0,
        "unit": "Gram"
      },
      {
        "name": "Pickled red Bhavnagri",
        "qty": 0,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-006",
    "brand": "aiko",
    "code": "DS-006",
    "name": "Chilli Oil Dumplings",
    "category": "Dimsum",
    "serving_size": 5,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Gyoza skin",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chilli Oil Dumplings filling",
        "qty": 75,
        "unit": "Gram"
      },
      {
        "name": "Oil",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Red chilli powder",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Chilli Oil Dumplings paste",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Stock water",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Msg",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Sichuan powder",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Toasted Peanuts",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "White spring onion",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Green spring onion",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Fried glass noodles",
        "qty": 4,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-ds-007",
    "brand": "aiko",
    "code": "DS-007",
    "name": "New Dimsum Platter",
    "category": "Dimsum",
    "serving_size": 5,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Saucy Momos",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Forest Dumplings",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Truffle Edamame Dumplings",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Cheese & Chilli Dumplings",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Chestnut Gyoza",
        "qty": 2,
        "unit": "Piece"
      },
      {
        "name": "Broad Beans",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Gyoza Dip",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Chili Crisp",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Forest Dip",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Red Momos Sauce",
        "qty": 30,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-001",
    "brand": "aiko",
    "code": "SU-001",
    "name": "Avocado Roll",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori",
        "qty": 1.4,
        "unit": "Gram"
      },
      {
        "name": "Black sesame",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "White sesame",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Buffalo sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Avocado",
        "qty": 180,
        "unit": "Gram"
      },
      {
        "name": "Unagi sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Rice paper",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wasabi",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-002",
    "brand": "aiko",
    "code": "SU-002",
    "name": "Dragon Roll",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori half sheet",
        "qty": 1.4,
        "unit": "Gram"
      },
      {
        "name": "Black sesame",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "White sesame",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Red bell pepper",
        "qty": 9,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Fried stem lotus",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Spicy mayo",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Dragon sauce",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wasabi",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-003",
    "brand": "aiko",
    "code": "SU-003",
    "name": "Volcano 1",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori sheet",
        "qty": 1.4,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Red Bell pepper",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Alfanso mango",
        "qty": 100,
        "unit": "Gram"
      },
      {
        "name": "Spicy mayo",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chilly crisps and oil",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Ginger pickled",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wasabi paste",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Micro greens",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-004",
    "brand": "aiko",
    "code": "SU-004",
    "name": "Gimbap 1",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Nori sheets",
        "qty": 4.2,
        "unit": "Gram"
      },
      {
        "name": "Sushi Rice",
        "qty": 160,
        "unit": "Gram"
      },
      {
        "name": "Fried Tofu toss on soy",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Unagi",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Pickled radish",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Sautéed spinach with soy & garlic",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Sesame oil (for brushing)",
        "qty": 1,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-005",
    "brand": "aiko",
    "code": "SU-005",
    "name": "Bombay Blues Roll",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori",
        "qty": 1.4,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "English cucumber",
        "qty": 18,
        "unit": "Gram"
      },
      {
        "name": "Red capsicum",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Coriander",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Jalapeño",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Tempura flex",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Salsa",
        "qty": 35,
        "unit": "Gram"
      },
      {
        "name": "Sweet chilli sauce",
        "qty": 11,
        "unit": "Gram"
      },
      {
        "name": "Unagi sauce",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Sriracha",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Wasabi",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-006",
    "brand": "aiko",
    "code": "SU-006",
    "name": "Jalapeño Popper Roll",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori",
        "qty": 1.4,
        "unit": "Gram"
      },
      {
        "name": "Jalapeño",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Black sesame",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Bread crumbs",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Unagi sauce",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Sriracha",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Coriander",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Raw mango",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Fried spring roll",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Wasabi",
        "qty": 3,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-su-007",
    "brand": "aiko",
    "code": "SU-007",
    "name": "Corn Tempura Roll",
    "category": "Sushi",
    "serving_size": 8,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sushi rice",
        "qty": 130,
        "unit": "Gram"
      },
      {
        "name": "Nori",
        "qty": 2.8,
        "unit": "Gram"
      },
      {
        "name": "Cucumber",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Purple cabbage",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Cream cheese",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "American corn",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Tempura flour",
        "qty": 50,
        "unit": "Gram"
      },
      {
        "name": "Soy sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pickled ginger",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Wasabi",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Sriracha",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-rc-001",
    "brand": "aiko",
    "code": "RC-001",
    "name": "Fried Rice",
    "category": "Rice",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Ginger (minced)",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 25,
        "unit": "Gram"
      },
      {
        "name": "Corn",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Edamame",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Cooked rice",
        "qty": 300,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 0.6,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 0.8,
        "unit": "Gram"
      },
      {
        "name": "Light soy",
        "qty": 5,
        "unit": "ML"
      },
      {
        "name": "Spring onion",
        "qty": 4,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-rc-002",
    "brand": "aiko",
    "code": "RC-002",
    "name": "Burnt Garlic Fried Rice",
    "category": "Rice",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 22,
        "unit": "ML"
      },
      {
        "name": "Garlic (minced)",
        "qty": 16,
        "unit": "Gram"
      },
      {
        "name": "Broccoli",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Baby corn",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Spinach",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Cooked rice",
        "qty": 300,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 0.6,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 0.8,
        "unit": "Gram"
      },
      {
        "name": "Fried garlic",
        "qty": 8,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 4,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-rc-003",
    "brand": "aiko",
    "code": "RC-003",
    "name": "Mushroom Truffle Fried Rice",
    "category": "Rice",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 15,
        "unit": "ML"
      },
      {
        "name": "Garlic",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Button mushroom",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Chili bean paste",
        "qty": 2.5,
        "unit": "Gram"
      },
      {
        "name": "Oyster sauce",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Hot sauce",
        "qty": 2.5,
        "unit": "Gram"
      },
      {
        "name": "Cooked rice",
        "qty": 300,
        "unit": "Gram"
      },
      {
        "name": "Edamame",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 0.6,
        "unit": "Gram"
      },
      {
        "name": "Truffle pâté",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Truffle oil",
        "qty": 2.5,
        "unit": "ML"
      }
    ]
  },
  {
    "id": "r-nd-001",
    "brand": "aiko",
    "code": "ND-001",
    "name": "Hakka Noodles",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 22,
        "unit": "ML"
      },
      {
        "name": "Ginger-garlic paste",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Bell pepper",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Cabbage",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Boiled hakka noodles",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Hakka sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 0.5,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 0.8,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 4,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-nd-002",
    "brand": "aiko",
    "code": "ND-002",
    "name": "Drunken Noodles",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 22,
        "unit": "ML"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Mixed mushroom",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Spring onion whites",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Flat noodles",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Drunken sauce",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Bean sprouts",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Thai basil",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-nd-003",
    "brand": "aiko",
    "code": "ND-003",
    "name": "Pad Thai",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Oil",
        "qty": 22,
        "unit": "ML"
      },
      {
        "name": "Ginger-garlic paste",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Mushrooms",
        "qty": 60,
        "unit": "Gram"
      },
      {
        "name": "Carrot",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Rice noodles (soaked)",
        "qty": 150,
        "unit": "Gram"
      },
      {
        "name": "Pad Thai sauce",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Bean sprouts",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Roasted peanuts",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Coriander",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Lemon wedge",
        "qty": 1,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-nd-004",
    "brand": "aiko",
    "code": "ND-004",
    "name": "Shoyu Ramen",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Maida noodles",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Veg stock",
        "qty": 120,
        "unit": "Gram"
      },
      {
        "name": "Dashi",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Shoyu tare",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 1,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "White sesame",
        "qty": 7,
        "unit": "Gram"
      },
      {
        "name": "Corn",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Bell pepper",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Bean sprouts",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Spring onion",
        "qty": 15,
        "unit": "Gram"
      },
      {
        "name": "Scallion oil",
        "qty": 2,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-nd-005",
    "brand": "aiko",
    "code": "ND-005",
    "name": "Peanut Butter Ramen",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sunflower oil",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Ginger paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Garlic paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Gochujang",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Red chilli powder",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Chilli bean paste",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Peanut butter",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 350,
        "unit": "Gram"
      },
      {
        "name": "Ramen noodles",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 1.5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Caster sugar",
        "qty": 10,
        "unit": "Gram"
      }
    ]
  },
  {
    "id": "r-nd-006",
    "brand": "aiko",
    "code": "ND-006",
    "name": "Spiced Miso Ramen",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Sunflower oil",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Ginger paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Garlic paste",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Gochujang",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Chilli bean paste",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Chilli powder",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Water",
        "qty": 350,
        "unit": "Gram"
      },
      {
        "name": "Peanut butter",
        "qty": 40,
        "unit": "Gram"
      },
      {
        "name": "Ramen noodles",
        "qty": 90,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "White pepper",
        "qty": 1.5,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Caster sugar",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Peanuts (roasted)",
        "qty": 20,
        "unit": "Gram"
      },
      {
        "name": "Coriander (chopped)",
        "qty": 6,
        "unit": "Gram"
      },
      {
        "name": "Spring onion (chopped)",
        "qty": 18,
        "unit": "Gram"
      },
      {
        "name": "Edamame (boiled)",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Pokchoy (blanched)",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Chilli oil",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "Lemon wedges",
        "qty": 1,
        "unit": "Piece"
      }
    ]
  },
  {
    "id": "r-nd-007",
    "brand": "aiko",
    "code": "ND-007",
    "name": "Buttery Chilli Garlic Noodles",
    "category": "Noodles",
    "serving_size": 1,
    "yield_grams": 0,
    "ingredients": [
      {
        "name": "Butter",
        "qty": 30,
        "unit": "Gram"
      },
      {
        "name": "Garlic",
        "qty": 10,
        "unit": "Gram"
      },
      {
        "name": "Thai chilli",
        "qty": 4,
        "unit": "Gram"
      },
      {
        "name": "Chilli crisp",
        "qty": 12,
        "unit": "Gram"
      },
      {
        "name": "Stock powder",
        "qty": 3,
        "unit": "Gram"
      },
      {
        "name": "Salt",
        "qty": 2,
        "unit": "Gram"
      },
      {
        "name": "MSG",
        "qty": 0.8,
        "unit": "Gram"
      },
      {
        "name": "Boiled noodles",
        "qty": 140,
        "unit": "Gram"
      },
      {
        "name": "Spring onion (garnish)",
        "qty": 5,
        "unit": "Gram"
      },
      {
        "name": "Fried garlic (garnish)",
        "qty": 5,
        "unit": "Gram"
      }
    ]
  }
];
