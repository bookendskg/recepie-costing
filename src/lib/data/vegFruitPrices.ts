// AUTO-GENERATED from assets/Surat_VegFruits_PriceMaster.xlsx (sheet "Price Master").
// Regenerate with: node scripts/gen-vegfruit-prices.mjs  — do not edit by hand.
// ₹ per gram for produce; this is the authoritative produce price (overrides the
// older costing book for the items it lists).

/** Normalised produce name → ₹ per gram. */
export const VEG_FRUIT_PRICES: Record<string, number> = {
  "alphonso mango": 0.4269,
  "apple": 0.22,
  "apple (premium)": 1.4667,
  "avocado imported": 0.65,
  "banana": 0.0507,
  "black grapes": 0.46,
  "edible flowers": 0.9266,
  "gauva": 0.14,
  "grapefruit": 0.2277,
  "green apple": 0.33,
  "green grapes": 0.32,
  "hass avocado": 0.6054,
  "italian lemon": 0.7072,
  "jackfruit": 0.07,
  "jamun": 0.3106,
  "kaffir lime": 1.0273,
  "kiwi": 0.2286,
  "lemon": 0.0971,
  "litchi": 19.8367,
  "malta": 0.16,
  "mango": 0.2667,
  "orange imported": 0.1463,
  "peach": 2,
  "pear": 0.32,
  "pineapple": 0.1343,
  "pineapple (premium)": 0.1475,
  "pineapple peeled": 0.15,
  "pineapple peeled (premium)": 0.1982,
  "pineapple whole": 0.108,
  "pomegranate -anar": 0.1643,
  "raw mango": 0.0564,
  "row banana": 0.045,
  "watermelon": 0.0315,
  "baby spinach 100gms": 0.14,
  "basil": 0.32,
  "bean sprouts": 0.3427,
  "beans sprout": 0.2504,
  "beetroot": 0.05,
  "bhavnagari red chilli": 0.12,
  "bird eye thai red chilli": 1.0634,
  "bokchoy": 0.1185,
  "brinjal": 0.07,
  "broccoli": 0.224,
  "brussels sprouts.": 0.8225,
  "button mushrooms": 0.1478,
  "cabbage": 0.0311,
  "carrot": 0.0506,
  "cherry tomato": 0.5053,
  "chilli broad beans 120gm": 0.5345,
  "chinese cabbage": 0.1579,
  "chinese cucumber": 0.2857,
  "chinese cucumber (premium)": 0.3002,
  "coriander": 0.0721,
  "cucumber": 0.0525,
  "curly kale": 0.35,
  "curry leaves": 0.025,
  "dil leaves .": 0.07,
  "edamame kernal 500gm": 0.3992,
  "edamame pods 500gm": 0.4,
  "edible flower": 0.1043,
  "english cucumber": 0.054,
  "fansi- beans": 0.1625,
  "fennel bulb": 1.6,
  "flower": 0.0878,
  "fresh babycorn": 0.1374,
  "fresh jalapenos": 0.2371,
  "fresh jalepenos green": 0.2927,
  "fresh jalepenos red": 0.2642,
  "frozen american corn": 0.0807,
  "garlic chop": 0.023,
  "ginger.": 0.1295,
  "green bell pepper": 0.1215,
  "green bhavnagri": 0.0825,
  "green capsicum": 0.0879,
  "green chilli": 0.0415,
  "green chilli small": 0.0928,
  "green garlic": 0.2,
  "green zucchini": 0.1719,
  "hydronic iceburg lettuce": 0.15,
  "hydronics spinach": 0.075,
  "hydroponic english cucumber": 0.05,
  "hydroponic roquette wild": 0.66,
  "iceberg": 0.1791,
  "iceberg lettuce.": 0.1547,
  "iceburg lettuce": 0.16,
  "jalapeno hot chill red": 0.185,
  "jalapeno hot chilly green": 0.3094,
  "kafir lime leaves.": 1.05,
  "king oyster mushroom": 0.93,
  "leek": 0.5484,
  "leeks": 0.085,
  "lemon grass": 0.1239,
  "lemon green": 0.0958,
  "lollo rosso": 0.3731,
  "lolo lettuce": 0.4,
  "lotus roots": 0.1877,
  "lotus stem": 0.1865,
  "methi big fresh": 0.1,
  "micro green": 1.0435,
  "microgreen": 1.8261,
  "microgreens": 1.5652,
  "mint": 0.0257,
  "mint (premium)": 0.3449,
  "mint bunch": 0.2,
  "mint leaves": 0.2,
  "onion": 0.0275,
  "onion whole": 0.023,
  "oyster mushroom": 0.375,
  "parsley": 0.2891,
  "peeled garlic.": 0.1823,
  "potatoes": 0.023,
  "pumpkin": 0.045,
  "purple cabbage": 0.1881,
  "red bellpepper": 0.1807,
  "red bhavnagri": 0.12,
  "red cabbage": 0.1407,
  "red chilli": 0.0875,
  "red chilli small": 0.0957,
  "red potato": 0.03,
  "rocket /arugula leaves": 0.4626,
  "rocket /arugula leaves 100gm": 0.4627,
  "rocket /arugula leaves 100gm (premium)": 1.1095,
  "romaine": 0.2413,
  "romaine lettuce": 0.2375,
  "rosemary": 0.6,
  "shimeji mushroom": 0.4815,
  "shimeji mushroom 125": 1.0867,
  "shimeji white": 0.95,
  "small onion": 0.02,
  "spinach palak": 0.06,
  "spring onion .": 0.0753,
  "suva (premium)": 2.8,
  "suva": 0.07,
  "sweet corn bhutta": 0.085,
  "sweet corn frozen pkt": 0.09,
  "thyme": 0.6,
  "tomato": 0.0683,
  "tomato big": 0.0478,
  "whole parsley": 0.3,
  "yellow bellpepper": 0.1661,
  "zucchini cut": 0.15
};

export interface VegFruitItem { name: string; category: string; perGram: number }

/** Full produce list — used to add any item not already in the catalogue. */
export const VEG_FRUIT_ITEMS: VegFruitItem[] = [
  {
    "name": "Alphonso Mango",
    "category": "Fruits",
    "perGram": 0.4269
  },
  {
    "name": "Apple",
    "category": "Fruits",
    "perGram": 0.22
  },
  {
    "name": "Apple (Premium)",
    "category": "Fruits",
    "perGram": 1.4667
  },
  {
    "name": "Avocado Imported",
    "category": "Fruits",
    "perGram": 0.65
  },
  {
    "name": "Banana",
    "category": "Fruits",
    "perGram": 0.0507
  },
  {
    "name": "Black Grapes",
    "category": "Fruits",
    "perGram": 0.46
  },
  {
    "name": "Edible Flowers",
    "category": "Vegetables",
    "perGram": 0.9266
  },
  {
    "name": "Gauva",
    "category": "Fruits",
    "perGram": 0.14
  },
  {
    "name": "Grapefruit",
    "category": "Fruits",
    "perGram": 0.2277
  },
  {
    "name": "Green Apple",
    "category": "Fruits",
    "perGram": 0.33
  },
  {
    "name": "Green Grapes",
    "category": "Fruits",
    "perGram": 0.32
  },
  {
    "name": "Hass Avocado",
    "category": "Fruits",
    "perGram": 0.6054
  },
  {
    "name": "Italian Lemon",
    "category": "Fruits",
    "perGram": 0.7072
  },
  {
    "name": "Jackfruit",
    "category": "Fruits",
    "perGram": 0.07
  },
  {
    "name": "Jamun",
    "category": "Fruits",
    "perGram": 0.3106
  },
  {
    "name": "Kaffir Lime",
    "category": "Fruits",
    "perGram": 1.0273
  },
  {
    "name": "Kiwi",
    "category": "Fruits",
    "perGram": 0.2286
  },
  {
    "name": "Lemon",
    "category": "Fruits",
    "perGram": 0.0971
  },
  {
    "name": "Litchi",
    "category": "Fruits",
    "perGram": 19.8367
  },
  {
    "name": "Malta",
    "category": "Fruits",
    "perGram": 0.16
  },
  {
    "name": "Mango",
    "category": "Fruits",
    "perGram": 0.2667
  },
  {
    "name": "Orange Imported",
    "category": "Fruits",
    "perGram": 0.1463
  },
  {
    "name": "Peach",
    "category": "Fruits",
    "perGram": 2
  },
  {
    "name": "Pear",
    "category": "Fruits",
    "perGram": 0.32
  },
  {
    "name": "Pineapple",
    "category": "Fruits",
    "perGram": 0.1343
  },
  {
    "name": "Pineapple (Premium)",
    "category": "Fruits",
    "perGram": 0.1475
  },
  {
    "name": "Pineapple Peeled",
    "category": "Fruits",
    "perGram": 0.15
  },
  {
    "name": "Pineapple Peeled (Premium)",
    "category": "Fruits",
    "perGram": 0.1982
  },
  {
    "name": "Pineapple Whole",
    "category": "Fruits",
    "perGram": 0.108
  },
  {
    "name": "Pomegranate -anar",
    "category": "Fruits",
    "perGram": 0.1643
  },
  {
    "name": "Raw Mango",
    "category": "Fruits",
    "perGram": 0.0564
  },
  {
    "name": "Row Banana",
    "category": "Fruits",
    "perGram": 0.045
  },
  {
    "name": "Watermelon",
    "category": "Fruits",
    "perGram": 0.0315
  },
  {
    "name": "Baby Spinach 100gms",
    "category": "Vegetables",
    "perGram": 0.14
  },
  {
    "name": "Basil",
    "category": "Vegetables",
    "perGram": 0.32
  },
  {
    "name": "Bean Sprouts",
    "category": "Vegetables",
    "perGram": 0.3427
  },
  {
    "name": "Beans Sprout",
    "category": "Vegetables",
    "perGram": 0.2504
  },
  {
    "name": "Beetroot",
    "category": "Vegetables",
    "perGram": 0.05
  },
  {
    "name": "Bhavnagari Red Chilli",
    "category": "Vegetables",
    "perGram": 0.12
  },
  {
    "name": "Bird Eye Thai Red Chilli",
    "category": "Vegetables",
    "perGram": 1.0634
  },
  {
    "name": "Bokchoy",
    "category": "Vegetables",
    "perGram": 0.1185
  },
  {
    "name": "Brinjal",
    "category": "Vegetables",
    "perGram": 0.07
  },
  {
    "name": "Broccoli",
    "category": "Vegetables",
    "perGram": 0.224
  },
  {
    "name": "Brussels Sprouts.",
    "category": "Vegetables",
    "perGram": 0.8225
  },
  {
    "name": "Button Mushrooms",
    "category": "Vegetables",
    "perGram": 0.1478
  },
  {
    "name": "Cabbage",
    "category": "Vegetables",
    "perGram": 0.0311
  },
  {
    "name": "Carrot",
    "category": "Vegetables",
    "perGram": 0.0506
  },
  {
    "name": "Cherry Tomato",
    "category": "Vegetables",
    "perGram": 0.5053
  },
  {
    "name": "Chilli Broad Beans 120gm",
    "category": "Vegetables",
    "perGram": 0.5345
  },
  {
    "name": "Chinese Cabbage",
    "category": "Vegetables",
    "perGram": 0.1579
  },
  {
    "name": "Chinese Cucumber",
    "category": "Vegetables",
    "perGram": 0.2857
  },
  {
    "name": "Chinese Cucumber (Premium)",
    "category": "Vegetables",
    "perGram": 0.3002
  },
  {
    "name": "Coriander",
    "category": "Vegetables",
    "perGram": 0.0721
  },
  {
    "name": "Cucumber",
    "category": "Vegetables",
    "perGram": 0.0525
  },
  {
    "name": "Curly Kale",
    "category": "Vegetables",
    "perGram": 0.35
  },
  {
    "name": "Curry Leaves",
    "category": "Vegetables",
    "perGram": 0.025
  },
  {
    "name": "Dil Leaves .",
    "category": "Vegetables",
    "perGram": 0.07
  },
  {
    "name": "Edamame Kernal 500gm",
    "category": "Vegetables",
    "perGram": 0.3992
  },
  {
    "name": "Edamame Pods 500gm",
    "category": "Vegetables",
    "perGram": 0.4
  },
  {
    "name": "Edible Flower",
    "category": "Vegetables",
    "perGram": 0.1043
  },
  {
    "name": "English Cucumber",
    "category": "Vegetables",
    "perGram": 0.054
  },
  {
    "name": "Fansi- Beans",
    "category": "Vegetables",
    "perGram": 0.1625
  },
  {
    "name": "Fennel Bulb",
    "category": "Vegetables",
    "perGram": 1.6
  },
  {
    "name": "Flower",
    "category": "Vegetables",
    "perGram": 0.0878
  },
  {
    "name": "Fresh Babycorn",
    "category": "Vegetables",
    "perGram": 0.1374
  },
  {
    "name": "Fresh Jalapenos",
    "category": "Vegetables",
    "perGram": 0.2371
  },
  {
    "name": "Fresh Jalepenos Green",
    "category": "Vegetables",
    "perGram": 0.2927
  },
  {
    "name": "Fresh Jalepenos Red",
    "category": "Vegetables",
    "perGram": 0.2642
  },
  {
    "name": "Frozen American Corn",
    "category": "Vegetables",
    "perGram": 0.0807
  },
  {
    "name": "Garlic Chop",
    "category": "Vegetables",
    "perGram": 0.023
  },
  {
    "name": "Ginger.",
    "category": "Vegetables",
    "perGram": 0.1295
  },
  {
    "name": "Green Bell Pepper",
    "category": "Vegetables",
    "perGram": 0.1215
  },
  {
    "name": "Green Bhavnagri",
    "category": "Vegetables",
    "perGram": 0.0825
  },
  {
    "name": "Green Capsicum",
    "category": "Vegetables",
    "perGram": 0.0879
  },
  {
    "name": "Green Chilli",
    "category": "Vegetables",
    "perGram": 0.0415
  },
  {
    "name": "Green Chilli Small",
    "category": "Vegetables",
    "perGram": 0.0928
  },
  {
    "name": "Green Garlic",
    "category": "Vegetables",
    "perGram": 0.2
  },
  {
    "name": "Green Zucchini",
    "category": "Vegetables",
    "perGram": 0.1719
  },
  {
    "name": "Hydronic Iceburg Lettuce",
    "category": "Vegetables",
    "perGram": 0.15
  },
  {
    "name": "Hydronics Spinach",
    "category": "Vegetables",
    "perGram": 0.075
  },
  {
    "name": "Hydroponic English Cucumber",
    "category": "Vegetables",
    "perGram": 0.05
  },
  {
    "name": "Hydroponic Roquette Wild",
    "category": "Vegetables",
    "perGram": 0.66
  },
  {
    "name": "Iceberg",
    "category": "Vegetables",
    "perGram": 0.1791
  },
  {
    "name": "Iceberg Lettuce.",
    "category": "Vegetables",
    "perGram": 0.1547
  },
  {
    "name": "Iceburg Lettuce",
    "category": "Vegetables",
    "perGram": 0.16
  },
  {
    "name": "Jalapeno Hot Chill Red",
    "category": "Vegetables",
    "perGram": 0.185
  },
  {
    "name": "Jalapeno Hot Chilly Green",
    "category": "Vegetables",
    "perGram": 0.3094
  },
  {
    "name": "Kafir Lime Leaves.",
    "category": "Vegetables",
    "perGram": 1.05
  },
  {
    "name": "King Oyster Mushroom",
    "category": "Vegetables",
    "perGram": 0.93
  },
  {
    "name": "Leek",
    "category": "Vegetables",
    "perGram": 0.5484
  },
  {
    "name": "Leeks",
    "category": "Vegetables",
    "perGram": 0.085
  },
  {
    "name": "Lemon Grass",
    "category": "Vegetables",
    "perGram": 0.1239
  },
  {
    "name": "Lemon Green",
    "category": "Vegetables",
    "perGram": 0.0958
  },
  {
    "name": "Lollo Rosso",
    "category": "Vegetables",
    "perGram": 0.3731
  },
  {
    "name": "Lolo Lettuce",
    "category": "Vegetables",
    "perGram": 0.4
  },
  {
    "name": "Lotus Roots",
    "category": "Vegetables",
    "perGram": 0.1877
  },
  {
    "name": "Lotus Stem",
    "category": "Vegetables",
    "perGram": 0.1865
  },
  {
    "name": "Methi Big Fresh",
    "category": "Vegetables",
    "perGram": 0.1
  },
  {
    "name": "Micro Green",
    "category": "Vegetables",
    "perGram": 1.0435
  },
  {
    "name": "Microgreen",
    "category": "Vegetables",
    "perGram": 1.8261
  },
  {
    "name": "Microgreens",
    "category": "Vegetables",
    "perGram": 1.5652
  },
  {
    "name": "Mint",
    "category": "Vegetables",
    "perGram": 0.0257
  },
  {
    "name": "Mint (Premium)",
    "category": "Vegetables",
    "perGram": 0.3449
  },
  {
    "name": "Mint Bunch",
    "category": "Vegetables",
    "perGram": 0.2
  },
  {
    "name": "Mint Leaves",
    "category": "Vegetables",
    "perGram": 0.2
  },
  {
    "name": "Onion",
    "category": "Vegetables",
    "perGram": 0.0275
  },
  {
    "name": "Onion Whole",
    "category": "Vegetables",
    "perGram": 0.023
  },
  {
    "name": "Oyster Mushroom",
    "category": "Vegetables",
    "perGram": 0.375
  },
  {
    "name": "Parsley",
    "category": "Vegetables",
    "perGram": 0.2891
  },
  {
    "name": "Peeled Garlic.",
    "category": "Vegetables",
    "perGram": 0.1823
  },
  {
    "name": "Potatoes",
    "category": "Vegetables",
    "perGram": 0.023
  },
  {
    "name": "Pumpkin",
    "category": "Vegetables",
    "perGram": 0.045
  },
  {
    "name": "Purple Cabbage",
    "category": "Vegetables",
    "perGram": 0.1881
  },
  {
    "name": "Red Bellpepper",
    "category": "Vegetables",
    "perGram": 0.1807
  },
  {
    "name": "Red Bhavnagri",
    "category": "Vegetables",
    "perGram": 0.12
  },
  {
    "name": "Red Cabbage",
    "category": "Vegetables",
    "perGram": 0.1407
  },
  {
    "name": "Red Chilli",
    "category": "Vegetables",
    "perGram": 0.0875
  },
  {
    "name": "Red Chilli Small",
    "category": "Vegetables",
    "perGram": 0.0957
  },
  {
    "name": "Red Potato",
    "category": "Vegetables",
    "perGram": 0.03
  },
  {
    "name": "Rocket /arugula Leaves",
    "category": "Vegetables",
    "perGram": 0.4626
  },
  {
    "name": "Rocket /arugula Leaves 100gm",
    "category": "Vegetables",
    "perGram": 0.4627
  },
  {
    "name": "Rocket /arugula Leaves 100gm (Premium)",
    "category": "Vegetables",
    "perGram": 1.1095
  },
  {
    "name": "Romaine",
    "category": "Vegetables",
    "perGram": 0.2413
  },
  {
    "name": "Romaine Lettuce",
    "category": "Vegetables",
    "perGram": 0.2375
  },
  {
    "name": "Rosemary",
    "category": "Vegetables",
    "perGram": 0.6
  },
  {
    "name": "Shimeji Mushroom",
    "category": "Vegetables",
    "perGram": 0.4815
  },
  {
    "name": "Shimeji Mushroom 125",
    "category": "Vegetables",
    "perGram": 1.0867
  },
  {
    "name": "Shimeji White",
    "category": "Vegetables",
    "perGram": 0.95
  },
  {
    "name": "Small Onion",
    "category": "Vegetables",
    "perGram": 0.02
  },
  {
    "name": "Spinach Palak",
    "category": "Vegetables",
    "perGram": 0.06
  },
  {
    "name": "Spring Onion .",
    "category": "Vegetables",
    "perGram": 0.0753
  },
  {
    "name": "Suva (Premium)",
    "category": "Vegetables",
    "perGram": 2.8
  },
  {
    "name": "Suva",
    "category": "Vegetables",
    "perGram": 0.07
  },
  {
    "name": "Sweet Corn Bhutta",
    "category": "Vegetables",
    "perGram": 0.085
  },
  {
    "name": "Sweet Corn Frozen Pkt",
    "category": "Vegetables",
    "perGram": 0.09
  },
  {
    "name": "Thyme",
    "category": "Vegetables",
    "perGram": 0.6
  },
  {
    "name": "Tomato",
    "category": "Vegetables",
    "perGram": 0.0683
  },
  {
    "name": "Tomato Big",
    "category": "Vegetables",
    "perGram": 0.0478
  },
  {
    "name": "Whole Parsley",
    "category": "Vegetables",
    "perGram": 0.3
  },
  {
    "name": "Yellow Bellpepper",
    "category": "Vegetables",
    "perGram": 0.1661
  },
  {
    "name": "Zucchini Cut",
    "category": "Vegetables",
    "perGram": 0.15
  }
];
