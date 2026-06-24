import type {
  Brand,
  ComponentType,
  Recipe,
  RecipeCostHistory,
  RecipeIngredient,
  RecipeIngredientWithMaterial,
  RecipeVersion,
} from "../types";
import { delay, getDb, type MockDb, mutate, nowISO, uid } from "./db";
import { findMaterial, recomputeAndPropagate, recordAudit } from "./recompute";

export interface RecipeHeaderInput {
  recipe_name: string;
  category: string;
  brand: Brand;
  description?: string | null;
  preparation_time?: number | null;
  serving_size: number;
  selling_price?: number | null;
  wastage_pct?: number;
  is_prep?: boolean;
  yield_quantity?: number;
  yield_unit?: string;
}

export interface RecipeLineInput {
  ingredient_id: string;
  component_type?: ComponentType;
  quantity_used: number;
  unit_used: string;
}

function attachMaterials(
  db: MockDb,
  lines: RecipeIngredient[],
): RecipeIngredientWithMaterial[] {
  return lines
    .slice()
    .sort((a, b) => a.sort_order - b.sort_order)
    .map((l) => ({
      ...l,
      material: l.component_type === "recipe" ? null : findMaterial(db, l.ingredient_id) ?? null,
      subRecipe:
        l.component_type === "recipe"
          ? db.recipes.find((r) => r.id === l.ingredient_id) ?? null
          : null,
    }));
}

function snapshotVersion(
  db: MockDb,
  recipe: Recipe,
  actorId: string | null,
  notes: string,
): void {
  const lines = db.recipe_ingredients.filter((ri) => ri.recipe_id === recipe.id);
  db.recipe_versions.push({
    id: uid(),
    recipe_id: recipe.id,
    version_no: recipe.version_no,
    snapshot: structuredClone({ recipe, lines }),
    notes,
    created_by: actorId,
    created_at: nowISO(),
  });
}

function writeLines(db: MockDb, recipeId: string, lines: RecipeLineInput[]): void {
  db.recipe_ingredients = db.recipe_ingredients.filter((ri) => ri.recipe_id !== recipeId);
  lines.forEach((line, idx) => {
    db.recipe_ingredients.push({
      id: uid(),
      recipe_id: recipeId,
      ingredient_id: line.ingredient_id,
      component_type: line.component_type ?? "material",
      quantity_used: line.quantity_used,
      unit_used: line.unit_used,
      calculated_cost: null,
      sort_order: idx,
    });
  });
}

/** Default a prep's batch yield to the sum of its ingredient grams. */
function defaultYield(lines: RecipeLineInput[]): number {
  const sum = lines.reduce((s, l) => s + (l.quantity_used || 0), 0);
  return sum > 0 ? sum : 1;
}

export const recipesRepo = {
  async list(): Promise<Recipe[]> {
    return delay([...getDb().recipes]);
  },

  async getById(id: string): Promise<Recipe | null> {
    return delay(getDb().recipes.find((r) => r.id === id) ?? null);
  },

  async getWithIngredients(
    id: string,
  ): Promise<{ recipe: Recipe; ingredients: RecipeIngredientWithMaterial[] } | null> {
    const db = getDb();
    const recipe = db.recipes.find((r) => r.id === id);
    if (!recipe) return delay(null);
    const ingredients = attachMaterials(
      db,
      db.recipe_ingredients.filter((ri) => ri.recipe_id === id),
    );
    return delay({ recipe: { ...recipe }, ingredients });
  },

  async create(
    header: RecipeHeaderInput,
    lines: RecipeLineInput[],
    actorId: string,
  ): Promise<Recipe> {
    return delay(
      mutate((db) => {
        if (
          db.recipes.some(
            (r) => r.recipe_name.toLowerCase() === header.recipe_name.toLowerCase(),
          )
        ) {
          throw new Error("A recipe with this name already exists");
        }
        const recipe: Recipe = {
          id: uid(),
          recipe_name: header.recipe_name,
          category: header.category,
          brand: header.brand,
          description: header.description ?? null,
          image_url: null,
          preparation_time: header.preparation_time ?? null,
          serving_size: header.serving_size,
          status: "draft",
          total_cost: 0,
          cost_per_portion: 0,
          selling_price: header.selling_price ?? null,
          wastage_pct: header.wastage_pct ?? 0,
          is_prep: header.is_prep ?? false,
          yield_quantity: header.yield_quantity ?? defaultYield(lines),
          yield_unit: header.yield_unit ?? "Gram",
          created_by: actorId,
          approved_by: null,
          approved_at: null,
          rejection_note: null,
          version_no: 1,
          created_at: nowISO(),
          updated_at: nowISO(),
          updated_by: actorId,
        };
        db.recipes.push(recipe);
        writeLines(db, recipe.id, lines);
        recomputeAndPropagate(db, [recipe.id], actorId, "Recipe created");
        snapshotVersion(db, recipe, actorId, "Initial version");
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: recipe.id,
          action: "create",
          new_values: { name: recipe.recipe_name },
          performed_by: actorId,
          notes: `Created "${recipe.recipe_name}"`,
        });
        return recipe;
      }),
    );
  },

  async update(
    id: string,
    header: RecipeHeaderInput,
    lines: RecipeLineInput[],
    actorId: string,
  ): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        if (
          db.recipes.some(
            (r) =>
              r.id !== id &&
              r.recipe_name.toLowerCase() === header.recipe_name.toLowerCase(),
          )
        ) {
          throw new Error("A recipe with this name already exists");
        }

        recipe.recipe_name = header.recipe_name;
        recipe.category = header.category;
        recipe.brand = header.brand;
        recipe.selling_price = header.selling_price ?? null;
        recipe.wastage_pct = header.wastage_pct ?? 0;
        recipe.description = header.description ?? null;
        recipe.preparation_time = header.preparation_time ?? null;
        recipe.serving_size = header.serving_size;
        if (header.is_prep !== undefined) recipe.is_prep = header.is_prep;
        recipe.yield_quantity = header.yield_quantity ?? defaultYield(lines);
        recipe.yield_unit = header.yield_unit ?? recipe.yield_unit ?? "Gram";
        recipe.version_no += 1;
        recipe.updated_by = actorId;

        // Editing an approved recipe reverts it to Draft (PRD §3.6 regression).
        const wasApproved = recipe.status === "approved";
        if (wasApproved) {
          recipe.status = "draft";
          recipe.approved_by = null;
          recipe.approved_at = null;
        }

        writeLines(db, recipe.id, lines);
        recomputeAndPropagate(db, [recipe.id], actorId, "Recipe edited");
        snapshotVersion(db, recipe, actorId, `Version ${recipe.version_no}`);
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: recipe.id,
          action: "update",
          performed_by: actorId,
          notes: wasApproved
            ? `Edited "${recipe.recipe_name}" (reverted to Draft)`
            : `Edited "${recipe.recipe_name}"`,
        });
        return recipe;
      }),
    );
  },

  async duplicate(id: string, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const src = db.recipes.find((r) => r.id === id);
        if (!src) throw new Error("Recipe not found");
        let name = `${src.recipe_name} - Copy`;
        let n = 2;
        while (db.recipes.some((r) => r.recipe_name.toLowerCase() === name.toLowerCase())) {
          name = `${src.recipe_name} - Copy ${n++}`;
        }
        const copy: Recipe = {
          ...src,
          id: uid(),
          recipe_name: name,
          status: "draft",
          approved_by: null,
          approved_at: null,
          rejection_note: null,
          version_no: 1,
          created_by: actorId,
          created_at: nowISO(),
          updated_at: nowISO(),
          updated_by: actorId,
        };
        db.recipes.push(copy);
        const srcLines = db.recipe_ingredients.filter((ri) => ri.recipe_id === id);
        writeLines(
          db,
          copy.id,
          srcLines
            .sort((a, b) => a.sort_order - b.sort_order)
            .map((l) => ({
              ingredient_id: l.ingredient_id,
              component_type: l.component_type,
              quantity_used: l.quantity_used,
              unit_used: l.unit_used,
            })),
        );
        recomputeAndPropagate(db, [copy.id], actorId, "Recipe duplicated");
        snapshotVersion(db, copy, actorId, "Duplicated");
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: copy.id,
          action: "create",
          performed_by: actorId,
          notes: `Duplicated "${src.recipe_name}" → "${copy.recipe_name}"`,
        });
        return copy;
      }),
    );
  },

  async submit(id: string, note: string | null, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        recipe.status = "testing";
        recipe.rejection_note = null;
        recipe.updated_at = nowISO();
        recipe.updated_by = actorId;
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: id,
          action: "submit",
          performed_by: actorId,
          notes: note ? `Submitted for testing: ${note}` : `Submitted "${recipe.recipe_name}" for testing`,
        });
        return recipe;
      }),
    );
  },

  async approve(id: string, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        recipe.status = "approved";
        recipe.approved_by = actorId;
        recipe.approved_at = nowISO();
        recipe.rejection_note = null;
        recipe.updated_at = nowISO();
        recipe.updated_by = actorId;
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: id,
          action: "approve",
          performed_by: actorId,
          notes: `Approved "${recipe.recipe_name}"`,
        });
        return recipe;
      }),
    );
  },

  async reject(id: string, note: string, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        recipe.status = "draft";
        recipe.rejection_note = note;
        recipe.updated_at = nowISO();
        recipe.updated_by = actorId;
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: id,
          action: "reject",
          performed_by: actorId,
          notes: `Rejected "${recipe.recipe_name}": ${note}`,
        });
        return recipe;
      }),
    );
  },

  /** All cost-history rows across every recipe (for bulk Excel export). */
  async allCostHistory(): Promise<RecipeCostHistory[]> {
    return delay(
      [...getDb().recipe_cost_history].sort((a, b) =>
        b.changed_at.localeCompare(a.changed_at),
      ),
    );
  },

  /** All recipe ingredient rows joined with their material (bulk export). */
  async allIngredients(): Promise<RecipeIngredientWithMaterial[]> {
    const db = getDb();
    return delay(attachMaterials(db, db.recipe_ingredients));
  },

  async setImage(id: string, imageUrl: string | null, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        recipe.image_url = imageUrl;
        recipe.updated_at = nowISO();
        recipe.updated_by = actorId;
        return recipe;
      }),
    );
  },

  async setSellingPrice(id: string, price: number | null, actorId: string): Promise<Recipe> {
    return delay(
      mutate((db) => {
        const recipe = db.recipes.find((r) => r.id === id);
        if (!recipe) throw new Error("Recipe not found");
        recipe.selling_price = price;
        recipe.updated_at = nowISO();
        recipe.updated_by = actorId;
        recordAudit(db, {
          entity_type: "recipe",
          entity_id: id,
          action: "update",
          performed_by: actorId,
          notes: `Set menu price for "${recipe.recipe_name}" to ${price ?? "—"}`,
        });
        return recipe;
      }),
    );
  },

  async costHistory(id: string): Promise<RecipeCostHistory[]> {
    return delay(
      getDb()
        .recipe_cost_history.filter((h) => h.recipe_id === id)
        .sort((a, b) => b.changed_at.localeCompare(a.changed_at)),
    );
  },

  async versions(id: string): Promise<RecipeVersion[]> {
    return delay(
      getDb()
        .recipe_versions.filter((v) => v.recipe_id === id)
        .sort((a, b) => b.version_no - a.version_no),
    );
  },
};
