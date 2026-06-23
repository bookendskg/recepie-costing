import type {
  Recipe,
  RecipeCostHistory,
  RecipeIngredient,
  RecipeIngredientWithMaterial,
  RecipeVersion,
} from "../types";
import { delay, getDb, type MockDb, mutate, nowISO, uid } from "./db";
import { findMaterial, recomputeRecipe, recordAudit } from "./recompute";

export interface RecipeHeaderInput {
  recipe_name: string;
  category: string;
  description?: string | null;
  preparation_time?: number | null;
  serving_size: number;
}

export interface RecipeLineInput {
  ingredient_id: string;
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
    .map((l) => ({ ...l, material: findMaterial(db, l.ingredient_id) ?? null }));
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
      quantity_used: line.quantity_used,
      unit_used: line.unit_used,
      calculated_cost: null,
      sort_order: idx,
    });
  });
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
          description: header.description ?? null,
          preparation_time: header.preparation_time ?? null,
          serving_size: header.serving_size,
          status: "draft",
          total_cost: 0,
          cost_per_portion: 0,
          created_by: actorId,
          approved_by: null,
          approved_at: null,
          rejection_note: null,
          version_no: 1,
          created_at: nowISO(),
          updated_at: nowISO(),
        };
        db.recipes.push(recipe);
        writeLines(db, recipe.id, lines);
        recomputeRecipe(db, recipe.id, actorId, "Recipe created");
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
        recipe.description = header.description ?? null;
        recipe.preparation_time = header.preparation_time ?? null;
        recipe.serving_size = header.serving_size;
        recipe.version_no += 1;

        // Editing an approved recipe reverts it to Draft (PRD §3.6 regression).
        const wasApproved = recipe.status === "approved";
        if (wasApproved) {
          recipe.status = "draft";
          recipe.approved_by = null;
          recipe.approved_at = null;
        }

        writeLines(db, recipe.id, lines);
        recomputeRecipe(db, recipe.id, actorId, "Recipe edited");
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
              quantity_used: l.quantity_used,
              unit_used: l.unit_used,
            })),
        );
        recomputeRecipe(db, copy.id, actorId, "Recipe duplicated");
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
