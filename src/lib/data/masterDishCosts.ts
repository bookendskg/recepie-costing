// AUTO-GENERATED from the "CAPICHE 2026" / "Aiko 2026" master-costing summary
// sheets in assets/CAPICHE COSTING 2026.xlsx — per-dish making cost, packaging and
// selling price (the master book's authoritative figures). Keyed by a normalised
// dish key. 132 dishes. Regenerate from source.

export interface MasterDishCost {
  name: string;
  brand: "capiche" | "aiko";
  making: number | null;
  packaging: number;
  selling: number | null;
}

export const MASTER_DISH_COSTS: Record<string, MasterDishCost> = {
  "tom yum soup": {
    "name": "Tom Yum Soup",
    "brand": "aiko",
    "making": 17.46,
    "packaging": 13.12,
    "selling": 360
  },
  "corn rocks": {
    "name": "Corn Rocks",
    "brand": "aiko",
    "making": 70.14,
    "packaging": 0,
    "selling": 440
  },
  "general tso s water chestnut": {
    "name": "General Tso’s Water Chestnut",
    "brand": "aiko",
    "making": 81.22,
    "packaging": 0,
    "selling": 540
  },
  "steamed edamame chilli": {
    "name": "Steamed Edamame (Chilli)",
    "brand": "aiko",
    "making": 104.77,
    "packaging": 0,
    "selling": 540
  },
  "mushroom tempura": {
    "name": "Mushroom Tempura",
    "brand": "aiko",
    "making": 207.97,
    "packaging": 0,
    "selling": 480
  },
  "tofu bao": {
    "name": "Tofu Bao (2 pcs)",
    "brand": "aiko",
    "making": 40.95,
    "packaging": 0,
    "selling": 540
  },
  "kwispy wonton": {
    "name": "Kwispy Wonton (5 pcs)",
    "brand": "aiko",
    "making": 33.04,
    "packaging": 0,
    "selling": 460
  },
  "kwispy lotus root": {
    "name": "Kwispy Lotus Root",
    "brand": "aiko",
    "making": 32.05,
    "packaging": 0,
    "selling": 460
  },
  "vietnamese spring roll": {
    "name": "Vietnamese Spring Roll (2 pcs)",
    "brand": "aiko",
    "making": 85.86,
    "packaging": 0,
    "selling": 380
  },
  "kwispy spring roll": {
    "name": "Kwispy Spring Roll (4 pcs)",
    "brand": "aiko",
    "making": 42.21,
    "packaging": 0,
    "selling": 460
  },
  "summer": {
    "name": "Summer Salad",
    "brand": "aiko",
    "making": 47.46,
    "packaging": 0,
    "selling": 460
  },
  "tteokbokki": {
    "name": "Tteokbokki",
    "brand": "aiko",
    "making": 108.6,
    "packaging": 0,
    "selling": 540
  },
  "korean mandu": {
    "name": "Korean Mandu",
    "brand": "aiko",
    "making": 52.77,
    "packaging": 0,
    "selling": 540
  },
  "creamy corn rocks": {
    "name": "Creamy Corn Rocks",
    "brand": "aiko",
    "making": 71.65,
    "packaging": 0,
    "selling": 580
  },
  "crispy scallion pancake": {
    "name": "Crispy Scallion Pancake",
    "brand": "aiko",
    "making": 78.25,
    "packaging": 0,
    "selling": 620
  },
  "cold spicy sesame noodles": {
    "name": "Cold Spicy Sesame Noodles",
    "brand": "aiko",
    "making": 71.18,
    "packaging": 0,
    "selling": 640
  },
  "forest dumplings": {
    "name": "Forest Dumplings (2 pcs)",
    "brand": "aiko",
    "making": 22.8,
    "packaging": 0,
    "selling": 480
  },
  "truffle edamame": {
    "name": "Truffle Edamame Dimsum (4 pcs)",
    "brand": "aiko",
    "making": 138.89,
    "packaging": 0,
    "selling": 840
  },
  "platter": {
    "name": "NEW Dimsum Platter (10 pcs)",
    "brand": "aiko",
    "making": 200.19,
    "packaging": 0,
    "selling": 1640
  },
  "cheese chilli dumplings": {
    "name": "Cheese & Chilli Dumplings (5 pcs)",
    "brand": "aiko",
    "making": 106.28,
    "packaging": 0,
    "selling": 480
  },
  "saucy momos": {
    "name": "Saucy Momos (5 pcs)",
    "brand": "aiko",
    "making": 39.31,
    "packaging": 0,
    "selling": 480
  },
  "chestnut gyoza": {
    "name": "Chestnut Gyoza (6 pcs)",
    "brand": "aiko",
    "making": 64.05,
    "packaging": 0,
    "selling": 540
  },
  "chilli oil dumplings": {
    "name": "Chilli Oil Dumplings (5 pcs)",
    "brand": "aiko",
    "making": 62.35,
    "packaging": 0,
    "selling": 620
  },
  "dragon roll": {
    "name": "Dragon Roll",
    "brand": "aiko",
    "making": 86.42,
    "packaging": 0,
    "selling": 720
  },
  "jalape o poppers": {
    "name": "Jalapeño Poppers",
    "brand": "aiko",
    "making": 94.27,
    "packaging": 0,
    "selling": 720
  },
  "bombay blues sushi": {
    "name": "Bombay Blues Sushi",
    "brand": "aiko",
    "making": 98.49,
    "packaging": 0,
    "selling": 720
  },
  "corn tempura": {
    "name": "Corn Tempura",
    "brand": "aiko",
    "making": 140.24,
    "packaging": 0,
    "selling": 720
  },
  "avocado roll": {
    "name": "Avocado Roll",
    "brand": "aiko",
    "making": 186.3,
    "packaging": 0,
    "selling": 840
  },
  "volcano roll": {
    "name": "Volcano Roll",
    "brand": "aiko",
    "making": 105.75,
    "packaging": 0,
    "selling": 720
  },
  "kwispy edamame roll": {
    "name": "Kwispy Edamame Roll",
    "brand": "aiko",
    "making": 115.96,
    "packaging": 0,
    "selling": 840
  },
  "gimbap": {
    "name": "Gimbap",
    "brand": "aiko",
    "making": 111.12,
    "packaging": 0,
    "selling": 980
  },
  "volcano roll 2026": {
    "name": "Volcano Roll 2026",
    "brand": "aiko",
    "making": 105.75,
    "packaging": 0,
    "selling": 980
  },
  "fried rice": {
    "name": "Fried Rice",
    "brand": "aiko",
    "making": 95.47,
    "packaging": 0,
    "selling": 540
  },
  "burnt garlic rice": {
    "name": "Burnt Garlic Rice",
    "brand": "aiko",
    "making": 96.79,
    "packaging": 0,
    "selling": 540
  },
  "mushroom truffle fried rice": {
    "name": "Mushroom Truffle Fried Rice",
    "brand": "aiko",
    "making": 235.98,
    "packaging": 0,
    "selling": 680
  },
  "mille feuille": {
    "name": "Mille-Feuille",
    "brand": "aiko",
    "making": 117.05,
    "packaging": 0,
    "selling": 540
  },
  "chocolate coconut souffl": {
    "name": "Chocolate Coconut Soufflé",
    "brand": "aiko",
    "making": 72.45,
    "packaging": 0,
    "selling": 540
  },
  "mango tres leches": {
    "name": "Mango Tres Leches",
    "brand": "aiko",
    "making": 64.53,
    "packaging": 0,
    "selling": 540
  },
  "lemon cake": {
    "name": "Lemon Cake",
    "brand": "aiko",
    "making": 28.6,
    "packaging": 0,
    "selling": 500
  },
  "ferrero crunch": {
    "name": "Ferrero Crunch",
    "brand": "aiko",
    "making": 97.98,
    "packaging": 0,
    "selling": 500
  },
  "raspberry kafir fizz": {
    "name": "Raspberry Kafir Fizz",
    "brand": "aiko",
    "making": 15,
    "packaging": 0,
    "selling": 300
  },
  "thai lemon boba tea": {
    "name": "Thai Lemon Boba Tea",
    "brand": "aiko",
    "making": 24.95,
    "packaging": 0,
    "selling": 300
  },
  "scarlett": {
    "name": "Scarlett",
    "brand": "aiko",
    "making": 24.36,
    "packaging": 0,
    "selling": 300
  },
  "tropical pop": {
    "name": "Tropical Pop",
    "brand": "aiko",
    "making": 84.72,
    "packaging": 0,
    "selling": 300
  },
  "berry breeze": {
    "name": "Berry Breeze",
    "brand": "aiko",
    "making": 62.32,
    "packaging": 0,
    "selling": 300
  },
  "clarified mojito": {
    "name": "Clarified Mojito",
    "brand": "aiko",
    "making": 14.98,
    "packaging": 0,
    "selling": 300
  },
  "mango schezwan chamoy": {
    "name": "Mango Schezwan Chamoy",
    "brand": "aiko",
    "making": 13.65,
    "packaging": 0,
    "selling": 300
  },
  "kala khatta soda": {
    "name": "Kala Khatta Soda",
    "brand": "aiko",
    "making": 33.6,
    "packaging": 0,
    "selling": 300
  },
  "katsu curry": {
    "name": "Katsu Curry",
    "brand": "aiko",
    "making": 36.46,
    "packaging": 0,
    "selling": 580
  },
  "thai curry": {
    "name": "Thai Curry",
    "brand": "aiko",
    "making": 131.54,
    "packaging": 0,
    "selling": 580
  },
  "coconut curry ramen": {
    "name": "Coconut Curry Ramen",
    "brand": "aiko",
    "making": 48.51,
    "packaging": 0,
    "selling": 640
  },
  "tofu and mushroom curry": {
    "name": "Tofu and Mushroom Curry",
    "brand": "aiko",
    "making": 166.22,
    "packaging": 0,
    "selling": 580
  },
  "kwispy burmese curry": {
    "name": "Kwispy Burmese Curry",
    "brand": "aiko",
    "making": 107.1,
    "packaging": 0,
    "selling": 580
  },
  "hakka noodles": {
    "name": "Hakka Noodles",
    "brand": "aiko",
    "making": 36.96,
    "packaging": 0,
    "selling": 580
  },
  "drunken noodles": {
    "name": "Drunken Noodles",
    "brand": "aiko",
    "making": 38.55,
    "packaging": 0,
    "selling": 580
  },
  "pad thai": {
    "name": "Pad Thai",
    "brand": "aiko",
    "making": 65.61,
    "packaging": 0,
    "selling": 580
  },
  "peanut butter ramen": {
    "name": "Peanut Butter Ramen",
    "brand": "aiko",
    "making": 61.81,
    "packaging": 0,
    "selling": 640
  },
  "shoyu ramen": {
    "name": "Shoyu Ramen",
    "brand": "aiko",
    "making": 42.6,
    "packaging": 0,
    "selling": 640
  },
  "buttery chilli garlic noodles": {
    "name": "Buttery Chilli Garlic Noodles",
    "brand": "aiko",
    "making": 24.29,
    "packaging": 0,
    "selling": 580
  },
  "maggi udon": {
    "name": "Maggi Udon",
    "brand": "aiko",
    "making": 181.78,
    "packaging": 0,
    "selling": 540
  },
  "margherita": {
    "name": "Margherita Pizza",
    "brand": "capiche",
    "making": 125.2,
    "packaging": 24.46,
    "selling": 940
  },
  "sid s pizz": {
    "name": "Sid's pizz",
    "brand": "capiche",
    "making": 131.5,
    "packaging": 24.46,
    "selling": 940
  },
  "peperone": {
    "name": "Peperone Pizza",
    "brand": "capiche",
    "making": 113.09,
    "packaging": 24.46,
    "selling": 940
  },
  "prime hulk": {
    "name": "Prime Hulk  Pizza",
    "brand": "capiche",
    "making": 131.13,
    "packaging": 24.46,
    "selling": 940
  },
  "baby hulk": {
    "name": "Baby Hulk  Pizza",
    "brand": "capiche",
    "making": 112.9,
    "packaging": 24.46,
    "selling": 940
  },
  "mid hulk": {
    "name": "Mid Hulk  Pizza",
    "brand": "capiche",
    "making": 116.11,
    "packaging": 24.46,
    "selling": 940
  },
  "third wave": {
    "name": "Third Wave Pizza",
    "brand": "capiche",
    "making": 125.21,
    "packaging": 24.46,
    "selling": 940
  },
  "garlic pie": {
    "name": "Garlic pie Pizza",
    "brand": "capiche",
    "making": 128.88,
    "packaging": 24.46,
    "selling": 940
  },
  "truffle": {
    "name": "Truffle Pizza",
    "brand": "capiche",
    "making": 189.25,
    "packaging": 24.46,
    "selling": 1140
  },
  "rubirosa": {
    "name": "Rubirosa Pizza",
    "brand": "capiche",
    "making": 125.63,
    "packaging": 24.46,
    "selling": 940
  },
  "ortolana": {
    "name": "Ortolana pizza",
    "brand": "capiche",
    "making": 156.21,
    "packaging": 24.46,
    "selling": 940
  },
  "chilli crunch": {
    "name": "CHILLI CRUNCH",
    "brand": "capiche",
    "making": 220.88,
    "packaging": 24.46,
    "selling": 1140
  },
  "affair": {
    "name": "Affair Pizza",
    "brand": "capiche",
    "making": 147.5,
    "packaging": 24.46,
    "selling": 940
  },
  "apollo": {
    "name": "Apollo pizza",
    "brand": "capiche",
    "making": 165.84,
    "packaging": 24.46,
    "selling": 940
  },
  "triple sauce": {
    "name": "Triple sauce",
    "brand": "capiche",
    "making": 106.53,
    "packaging": 24.46,
    "selling": 1140
  },
  "diavolo": {
    "name": "Diavolo",
    "brand": "capiche",
    "making": 114,
    "packaging": 24.46,
    "selling": 940
  },
  "picante": {
    "name": "Picante",
    "brand": "capiche",
    "making": 218.01,
    "packaging": 30,
    "selling": 1240
  },
  "burrata hot honey": {
    "name": "Burrata hot honey",
    "brand": "capiche",
    "making": 136.63,
    "packaging": 24.46,
    "selling": 1140
  },
  "tofu xo": {
    "name": "Tofu xo Pizza",
    "brand": "capiche",
    "making": 113.4,
    "packaging": 24.46,
    "selling": 940
  },
  "hot corn": {
    "name": "Hot Corn",
    "brand": "capiche",
    "making": 110.25,
    "packaging": 24.46,
    "selling": 940
  },
  "hell boy": {
    "name": "Hell Boy Pizza",
    "brand": "capiche",
    "making": 111.85,
    "packaging": 24.46,
    "selling": 1140
  },
  "chilli butter corn": {
    "name": "Chilli Butter Corn",
    "brand": "capiche",
    "making": 129.23,
    "packaging": 24.46,
    "selling": 1140
  },
  "picanate": {
    "name": "Picanate",
    "brand": "capiche",
    "making": 128.6,
    "packaging": 24.46,
    "selling": 940
  },
  "soup and toast": {
    "name": "SOUP AND TOAST",
    "brand": "capiche",
    "making": 52.57,
    "packaging": 0,
    "selling": 400
  },
  "doughballs": {
    "name": "DOUGHBALLS",
    "brand": "capiche",
    "making": 97.65,
    "packaging": 0,
    "selling": 540
  },
  "garlic bread": {
    "name": "GARLIC BREAD",
    "brand": "capiche",
    "making": 51.42,
    "packaging": 0,
    "selling": 540
  },
  "caesar": {
    "name": "CAESAR SALAD",
    "brand": "capiche",
    "making": 41.12,
    "packaging": 0,
    "selling": 480
  },
  "butter garlic mushrooms": {
    "name": "BUTTER GARLIC MUSHROOMS",
    "brand": "capiche",
    "making": 115.34,
    "packaging": 0,
    "selling": 540
  },
  "arancini": {
    "name": "ARANCINI",
    "brand": "capiche",
    "making": 48.04,
    "packaging": 0,
    "selling": 480
  },
  "burrata": {
    "name": "BURRATA SALAD",
    "brand": "capiche",
    "making": 164.65,
    "packaging": 0,
    "selling": 620
  },
  "toamto burrata": {
    "name": "Toamto Burrata",
    "brand": "capiche",
    "making": 148.75,
    "packaging": 0,
    "selling": 620
  },
  "tahina": {
    "name": "Tahina Salad",
    "brand": "capiche",
    "making": 74.55,
    "packaging": 0,
    "selling": 480
  },
  "fritii 2 0": {
    "name": "Pasta Fritii 2.0",
    "brand": "capiche",
    "making": 135.65,
    "packaging": 0,
    "selling": 640
  },
  "miso tomato soup": {
    "name": "Miso Tomato Soup",
    "brand": "capiche",
    "making": 47.14,
    "packaging": 0,
    "selling": 440
  },
  "tomato butter risotto": {
    "name": "TOMATO BUTTER RISOTTO",
    "brand": "capiche",
    "making": 109.5,
    "packaging": 0,
    "selling": 740
  },
  "saucy brussels": {
    "name": "Saucy Brussels",
    "brand": "capiche",
    "making": 165.74,
    "packaging": 0,
    "selling": 580
  },
  "summer burrata": {
    "name": "Summer Burrata Salad",
    "brand": "capiche",
    "making": 141.38,
    "packaging": 0,
    "selling": 680
  },
  "tiramisu": {
    "name": "TIRAMISU",
    "brand": "capiche",
    "making": 111.93,
    "packaging": 0,
    "selling": 640
  },
  "sticky toffee pudding": {
    "name": "STICKY TOFFEE PUDDING",
    "brand": "capiche",
    "making": 52.6,
    "packaging": 0,
    "selling": 600
  },
  "pistachio mousse cake": {
    "name": "PISTACHIO MOUSSE CAKE",
    "brand": "capiche",
    "making": 139.58,
    "packaging": 0,
    "selling": 600
  },
  "cassata": {
    "name": "CASSATA",
    "brand": "capiche",
    "making": 99.87,
    "packaging": 0,
    "selling": 640
  },
  "mango cream": {
    "name": "MANGO & CREAM",
    "brand": "capiche",
    "making": 170.76,
    "packaging": 0,
    "selling": 680
  },
  "chocolate crunch cake": {
    "name": "CHOCOLATE CRUNCH CAKE",
    "brand": "capiche",
    "making": 108.56,
    "packaging": 0,
    "selling": 600
  },
  "caramel custard": {
    "name": "CARAMEL CUSTARD",
    "brand": "capiche",
    "making": 46.89,
    "packaging": 0,
    "selling": 580
  },
  "brownie with ice cream": {
    "name": "BROWNIE WITH ICE-CREAM",
    "brand": "capiche",
    "making": 108.15,
    "packaging": 0,
    "selling": 640
  },
  "mango cheese cake": {
    "name": "MANGO CHEESE CAKE",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 680
  },
  "aerated chocolate": {
    "name": "Aerated Chocolate",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 600
  },
  "aglio olio": {
    "name": "AGLIO OLIO",
    "brand": "capiche",
    "making": 76.15,
    "packaging": 0,
    "selling": 740
  },
  "pomodoro": {
    "name": "POMODORO",
    "brand": "capiche",
    "making": 102.17,
    "packaging": 0,
    "selling": 740
  },
  "pesto bucatini": {
    "name": "PESTO BUCATINI",
    "brand": "capiche",
    "making": 70.4,
    "packaging": 0,
    "selling": 740
  },
  "spicy tomato cream": {
    "name": "SPICY TOMATO & CREAM",
    "brand": "capiche",
    "making": 71.94,
    "packaging": 0,
    "selling": 740
  },
  "alfredo": {
    "name": "ALFREDO",
    "brand": "capiche",
    "making": 71.69,
    "packaging": 0,
    "selling": 740
  },
  "lasagna": {
    "name": "LASAGNA",
    "brand": "capiche",
    "making": 143.63,
    "packaging": 0,
    "selling": 740
  },
  "limon linguini": {
    "name": "LIMON LINGUINI",
    "brand": "capiche",
    "making": 72.71,
    "packaging": 0,
    "selling": 640
  },
  "risotto": {
    "name": "RISOTTO",
    "brand": "capiche",
    "making": 134.96,
    "packaging": 0,
    "selling": 780
  },
  "smoked tomato risotto": {
    "name": "Smoked tomato risotto",
    "brand": "capiche",
    "making": 116.13,
    "packaging": 0,
    "selling": 840
  },
  "stuffed conchiglioni": {
    "name": "Stuffed conchiglioni",
    "brand": "capiche",
    "making": 103.03,
    "packaging": 0,
    "selling": 780
  },
  "caramelised onion": {
    "name": "CARAMELISED ONION PASTA",
    "brand": "capiche",
    "making": 62.24,
    "packaging": 0,
    "selling": 780
  },
  "truffle mac cheese": {
    "name": "Truffle Mac & Cheese",
    "brand": "capiche",
    "making": 164.71,
    "packaging": 0,
    "selling": 840
  },
  "pink burrata": {
    "name": "Pink Burrata Pasta",
    "brand": "capiche",
    "making": 124.8,
    "packaging": 0,
    "selling": 780
  },
  "moscow mule": {
    "name": "MOSCOW MULE",
    "brand": "capiche",
    "making": 91.7,
    "packaging": 0,
    "selling": 360
  },
  "lemon iced tea": {
    "name": "LEMON ICED TEA",
    "brand": "capiche",
    "making": 14.66,
    "packaging": 0,
    "selling": 360
  },
  "mint mojito": {
    "name": "MINT MOJITO",
    "brand": "capiche",
    "making": 19.13,
    "packaging": 0,
    "selling": 360
  },
  "pina colada": {
    "name": "PINA COLADA",
    "brand": "capiche",
    "making": 84.9,
    "packaging": 0,
    "selling": 360
  },
  "mango picante": {
    "name": "MANGO PICANTE",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 360
  },
  "melon fresca": {
    "name": "MELON FRESCA",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 360
  },
  "basil smash": {
    "name": "BASIL SMASH",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 360
  },
  "red bull ginger ale perrier": {
    "name": "RED BULL / GINGER ALE / PERRIER",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 250
  },
  "coke sprite coke zero": {
    "name": "COKE / SPRITE / COKE ZERO",
    "brand": "capiche",
    "making": null,
    "packaging": 0,
    "selling": 200
  },
  "tamarind fizz": {
    "name": "TAMARIND FIZZ",
    "brand": "capiche",
    "making": 56.97,
    "packaging": 0,
    "selling": 300
  },
  "sunset": {
    "name": "SUNSET",
    "brand": "capiche",
    "making": 67.54,
    "packaging": 0,
    "selling": 300
  },
  "creamy fresca": {
    "name": "CREAMY FRESCA",
    "brand": "capiche",
    "making": 41.95,
    "packaging": 0,
    "selling": 300
  }
};
