// Supabase-backed recipes repository (Phase 2). Mirrors the mock `recipesRepo`
// interface 1:1 so src/lib/data/index.ts can select between them by a ternary.
//
// Cost math is NEVER re-derived here: writes persist the recipe row + replace its
// recipe_ingredients rows, then delegate to recomputeRecipes() (the shared helper
// that reuses the SAME verified mock recompute graph) to compute + persist costs,
// line costs, and recipe_cost_history. Reads cast snake_case rows straight to the
// domain types; getWithIngredients joins raw_materials and sub-recipes like the mock.

import type {
  Recipe,
  RecipeCostHistory,
  RecipeIngredient,
  RecipeIngredientWithMaterial,
  RecipeVersion,
} from "../types";
import type { ImportSummary } from "../../import/importTypes";
import { nowISO, uid } from "../mock/db";
import {
  audit,
  fail,
  loadCostingDb,
  recomputeRecipes,
  sb,
} from "./helpers";
import type {
  ImportRecipeLine,
  RecipeHeaderInput,
  RecipeLineInput,
} from "../mock/recipes";

export type { ImportRecipeLine, RecipeHeaderInput, RecipeLineInput };

// ── internal helpers ───────────────────────────────────────────────────────

/** Default a prep's batch yield to the sum of its ingredient grams (mirrors mock). */
function defaultYield(lines: RecipeLineInput[]): number {
  const sum = lines.reduce((s, l) => s + (l.quantity_used || 0), 0);
  return sum > 0 ? sum : 1;
}

/** Build recipe_ingredients rows for a recipe from typed line inputs. */
function lineRows(recipeId: string, lines: RecipeLineInput[]): RecipeIngredient[] {
  return lines.map((line, idx) => ({
    id: uid(),
    recipe_id: recipeId,
    ingredient_id: line.ingredient_id,
    component_type: line.component_type ?? "material",
    quantity_used: line.quantity_used,
    unit_used: line.unit_used,
    calculated_cost: null,
    sort_order: idx,
    wastage_override_pct: line.wastage_override_pct ?? null,
    cut_type: line.cut_type ?? null,
  }));
}

/** Delete the recipe's existing lines, then insert the supplied set. */
async function replaceLines(recipeId: string, rows: RecipeIngredient[]): Promise<void> {
  const c = sb();
  const del = await c.from("recipe_ingredients").delete().eq("recipe_id", recipeId);
  if (del.error) fail("Save recipe ingredients", del.error.message);
  if (rows.length) {
    const ins = await c.from("recipe_ingredients").insert(rows);
    if (ins.error) fail("Save recipe ingredients", ins.error.message);
  }
}

/** Snapshot the current recipe + its lines into recipe_versions (mirrors mock). */
async function snapshotVersion(recipe: Recipe, actorId: string | null, notes: string): Promise<void> {
  const c = sb();
  const lines = await c.from("recipe_ingredients").select("*").eq("recipe_id", recipe.id);
  if (lines.error) fail("Snapshot recipe version", lines.error.message);
  const { error } = await c.from("recipe_versions").insert({
    id: uid(),
    recipe_id: recipe.id,
    version_no: recipe.version_no,
    snapshot: { recipe, lines: (lines.data ?? []) as RecipeIngredient[] },
    notes,
    created_by: actorId,
    created_at: nowISO(),
  });
  if (error) fail("Snapshot recipe version", error.message);
}

/** Re-read a recipe row after a recompute so the returned cost fields are fresh. */
async function reloadRecipe(id: string, context: string): Promise<Recipe> {
  const { data, error } = await sb().from("recipes").select("*").eq("id", id).single();
  if (error) fail(context, error.message);
  return data as Recipe;
}

/** Attach material / sub-recipe to lines using a single costing snapshot read. */
function attach(
  lines: RecipeIngredient[],
  mats: Map<string, RecipeIngredientWithMaterial["material"]>,
  recs: Map<string, Recipe>,
): RecipeIngredientWithMaterial[] {
  return lines
    .slice()
    .sort((a, b) => a.sort_order - b.sort_order)
    .map((l) => ({
      ...l,
      material: l.component_type === "recipe" ? null : mats.get(l.ingredient_id) ?? null,
      subRecipe: l.component_type === "recipe" ? recs.get(l.ingredient_id) ?? null : null,
    }));
}

// ── repository ─────────────────────────────────────────────────────────────

export const supabaseRecipesRepo = {
  async list(): Promise<Recipe[]> {
    const { data, error } = await sb().from("recipes").select("*");
    if (error) fail("Load recipes", error.message);
    return (data ?? []) as Recipe[];
  },

  async getById(id: string): Promise<Recipe | null> {
    const { data, error } = await sb().from("recipes").select("*").eq("id", id).maybeSingle();
    if (error) fail("Load recipe", error.message);
    return (data as Recipe | null) ?? null;
  },

  async getWithIngredients(
    id: string,
  ): Promise<{ recipe: Recipe; ingredients: RecipeIngredientWithMaterial[] } | null> {
    const c = sb();
    const recRes = await c.from("recipes").select("*").eq("id", id).maybeSingle();
    if (recRes.error) fail("Load recipe", recRes.error.message);
    if (!recRes.data) return null;
    const recipe = recRes.data as Recipe;

    const linesRes = await c.from("recipe_ingredients").select("*").eq("recipe_id", id);
    if (linesRes.error) fail("Load recipe ingredients", linesRes.error.message);
    const lines = (linesRes.data ?? []) as RecipeIngredient[];

    const matIds = lines.filter((l) => l.component_type !== "recipe").map((l) => l.ingredient_id);
    const subIds = lines.filter((l) => l.component_type === "recipe").map((l) => l.ingredient_id);

    const [matsRes, subsRes] = await Promise.all([
      matIds.length
        ? c.from("raw_materials").select("*").in("id", matIds)
        : Promise.resolve({ data: [], error: null }),
      subIds.length
        ? c.from("recipes").select("*").in("id", subIds)
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (matsRes.error) fail("Load recipe ingredients", matsRes.error.message);
    if (subsRes.error) fail("Load recipe ingredients", subsRes.error.message);

    const mats = new Map(
      ((matsRes.data ?? []) as RecipeIngredientWithMaterial["material"][])
        .filter((m): m is NonNullable<typeof m> => m != null)
        .map((m) => [m.id, m]),
    );
    const recs = new Map(((subsRes.data ?? []) as Recipe[]).map((r) => [r.id, r]));

    return { recipe, ingredients: attach(lines, mats, recs) };
  },

  async create(
    header: RecipeHeaderInput,
    lines: RecipeLineInput[],
    actorId: string,
  ): Promise<Recipe> {
    const c = sb();
    // Name-uniqueness check (mirrors the mock; the DB also enforces it).
    const existing = await c
      .from("recipes")
      .select("id,recipe_name")
      .ilike("recipe_name", header.recipe_name);
    if (existing.error) fail("Create recipe", existing.error.message);
    if (
      (existing.data ?? []).some(
        (r: { recipe_name: string }) =>
          r.recipe_name.toLowerCase() === header.recipe_name.toLowerCase(),
      )
    ) {
      fail("Create recipe", "A recipe with this name already exists");
    }

    const id = uid();
    const recipe: Recipe = {
      id,
      recipe_name: header.recipe_name,
      category: header.category,
      brand: header.brand,
      description: header.description ?? null,
      method: header.method ?? [],
      image_url: null,
      preparation_time: header.preparation_time ?? null,
      serving_size: header.serving_size,
      status: "draft",
      total_cost: 0,
      cost_per_portion: 0,
      selling_price: header.selling_price ?? null,
      packaging_cost: header.packaging_cost ?? 0,
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

    const insRecipe = await c.from("recipes").insert(recipe);
    if (insRecipe.error) fail("Create recipe", insRecipe.error.message);

    await replaceLines(id, lineRows(id, lines));
    await recomputeRecipes([id], actorId, "Recipe created");
    const saved = await reloadRecipe(id, "Create recipe");
    await snapshotVersion(saved, actorId, "Initial version");
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "create",
      new_values: { name: saved.recipe_name },
      performed_by: actorId,
      notes: `Created "${saved.recipe_name}"`,
    });
    return saved;
  },

  async update(
    id: string,
    header: RecipeHeaderInput,
    lines: RecipeLineInput[],
    actorId: string,
  ): Promise<Recipe> {
    const c = sb();
    const cur = await c.from("recipes").select("*").eq("id", id).maybeSingle();
    if (cur.error) fail("Update recipe", cur.error.message);
    if (!cur.data) fail("Update recipe", "Recipe not found");
    const recipe = cur.data as Recipe;

    const dupes = await c
      .from("recipes")
      .select("id,recipe_name")
      .ilike("recipe_name", header.recipe_name);
    if (dupes.error) fail("Update recipe", dupes.error.message);
    if (
      (dupes.data ?? []).some(
        (r: { id: string; recipe_name: string }) =>
          r.id !== id && r.recipe_name.toLowerCase() === header.recipe_name.toLowerCase(),
      )
    ) {
      fail("Update recipe", "A recipe with this name already exists");
    }

    // Editing an approved recipe reverts it to Draft (PRD §3.6 regression).
    const wasApproved = recipe.status === "approved";

    const patch: Record<string, unknown> = {
      recipe_name: header.recipe_name,
      category: header.category,
      brand: header.brand,
      selling_price: header.selling_price ?? null,
      packaging_cost: header.packaging_cost ?? 0,
      wastage_pct: header.wastage_pct ?? 0,
      description: header.description ?? null,
      method: header.method ?? [],
      preparation_time: header.preparation_time ?? null,
      serving_size: header.serving_size,
      yield_quantity: header.yield_quantity ?? defaultYield(lines),
      yield_unit: header.yield_unit ?? recipe.yield_unit ?? "Gram",
      version_no: recipe.version_no + 1,
      updated_by: actorId,
      updated_at: nowISO(),
    };
    if (header.is_prep !== undefined) patch.is_prep = header.is_prep;
    if (wasApproved) {
      patch.status = "draft";
      patch.approved_by = null;
      patch.approved_at = null;
    }

    const upd = await c.from("recipes").update(patch).eq("id", id);
    if (upd.error) fail("Update recipe", upd.error.message);

    await replaceLines(id, lineRows(id, lines));
    await recomputeRecipes([id], actorId, "Recipe edited");
    const saved = await reloadRecipe(id, "Update recipe");
    await snapshotVersion(saved, actorId, `Version ${saved.version_no}`);
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "update",
      performed_by: actorId,
      notes: wasApproved
        ? `Edited "${saved.recipe_name}" (reverted to Draft)`
        : `Edited "${saved.recipe_name}"`,
    });
    return saved;
  },

  /**
   * Bulk recipe import (§37). Rows are grouped by recipe name; rows carrying a
   * Size build a pizza master (15-inch) + an 11-inch variant, otherwise a single
   * recipe. Missing ingredients are created as UNPRICED materials. Costs recompute
   * from priced ingredients afterwards. Uses ONE in-memory costing snapshot for the
   * existence/material lookups, then writes to Supabase, then recomputes.
   */
  async importRecipes(
    mode: "add" | "update" | "upsert",
    rows: ImportRecipeLine[],
    actorId: string,
  ): Promise<ImportSummary> {
    const c = sb();
    const S: ImportSummary = { total: 0, imported: 0, updated: 0, skipped: 0, failed: 0, errors: [] };

    // Snapshot existing materials + recipes once for lookups.
    const db = await loadCostingDb();
    const matByName = new Map(db.raw_materials.map((m) => [m.ingredient_name.toLowerCase(), m]));
    const newMaterials: typeof db.raw_materials = [];

    const ensureMat = (name: string): string => {
      const key = name.toLowerCase();
      const found = matByName.get(key);
      if (found) return found.id;
      const m = {
        id: uid(),
        ingredient_name: name,
        category: "Other",
        supplier_name: null,
        notes: null,
        purchase_price: null,
        purchase_quantity: 1,
        purchase_unit: "Gram",
        base_unit: "Gram",
        cost_per_base_unit: null,
        last_price_update: null,
        status: "active" as const,
        created_by: actorId,
        created_at: nowISO(),
      };
      matByName.set(key, m);
      newMaterials.push(m);
      return m.id;
    };

    // Recipe rows to insert / update, plus their line rows (written after the loop).
    const recipeInserts: Recipe[] = [];
    const lineWrites: { recipeId: string; rows: RecipeIngredient[] }[] = [];
    const recipeUpdates: { id: string; patch: Record<string, unknown> }[] = [];
    const recomputeIds: string[] = [];

    const buildRows = (recipeId: string, ls: ImportRecipeLine[]): RecipeIngredient[] =>
      ls.map((l, idx) => ({
        id: uid(),
        recipe_id: recipeId,
        ingredient_id: ensureMat(l.ingredient_name),
        component_type: "material" as const,
        quantity_used: l.quantity,
        unit_used: l.unit,
        calculated_cost: null,
        sort_order: idx,
        wastage_override_pct: null,
        cut_type: null,
      }));

    const upsert = (
      name: string,
      category: string,
      sizeCode: "11_INCH" | "15_INCH" | null,
      parentId: string | null,
      ls: ImportRecipeLine[],
    ): { id: string | null; action: "added" | "updated" | "skipped" } => {
      const existing = db.recipes.find(
        (r) => r.recipe_name.toLowerCase() === name.toLowerCase() && (r.size_code ?? null) === sizeCode,
      );
      const selling = ls.find((l) => l.selling_price != null)?.selling_price ?? null;
      const pkg = ls.find((l) => l.packaging_cost != null)?.packaging_cost ?? null;
      if (existing) {
        if (mode === "add") return { id: existing.id, action: "skipped" };
        lineWrites.push({ recipeId: existing.id, rows: buildRows(existing.id, ls) });
        const patch: Record<string, unknown> = {
          category,
          updated_at: nowISO(),
          updated_by: actorId,
        };
        if (selling != null) patch.selling_price = selling;
        if (pkg != null) patch.packaging_cost = pkg;
        recipeUpdates.push({ id: existing.id, patch });
        recomputeIds.push(existing.id);
        return { id: existing.id, action: "updated" };
      }
      if (mode === "update") return { id: null, action: "skipped" };
      const id = uid();
      const recipe: Recipe = {
        id,
        recipe_name: name,
        category,
        brand: "capiche",
        description: null,
        method: [],
        parent_recipe_id: parentId,
        size_code: sizeCode,
        size_label: sizeCode === "11_INCH" ? "11-inch" : sizeCode === "15_INCH" ? "15-inch" : null,
        image_url: null,
        preparation_time: null,
        serving_size: 1,
        status: "draft",
        selling_price: selling,
        packaging_cost: pkg ?? 0,
        total_cost: 0,
        cost_per_portion: 0,
        wastage_pct: 5,
        is_prep: false,
        yield_quantity: 0,
        yield_unit: "Gram",
        created_by: actorId,
        approved_by: null,
        approved_at: null,
        rejection_note: null,
        version_no: 1,
        created_at: nowISO(),
        updated_at: nowISO(),
        updated_by: actorId,
      };
      recipeInserts.push(recipe);
      db.recipes.push(recipe); // visible to later groups (e.g. 11-inch parent lookup)
      lineWrites.push({ recipeId: id, rows: buildRows(id, ls) });
      recomputeIds.push(id);
      return { id, action: "added" };
    };

    const tally = (a: "added" | "updated" | "skipped") => {
      if (a === "added") S.imported++;
      else if (a === "updated") S.updated++;
      else S.skipped++;
    };

    const groups = new Map<string, ImportRecipeLine[]>();
    for (const l of rows) {
      const k = l.recipe_name.trim().toLowerCase();
      const arr = groups.get(k);
      if (arr) arr.push(l);
      else groups.set(k, [l]);
    }
    for (const glines of groups.values()) {
      try {
        const name = glines[0].recipe_name.trim();
        const category = glines[0].category || "Uncategorised";
        if (glines.some((l) => l.size)) {
          const fifteen = glines.filter((l) => l.size === "15_INCH");
          const eleven = glines.filter((l) => l.size === "11_INCH");
          let masterId: string | null = null;
          if (fifteen.length) {
            const r = upsert(name, category, "15_INCH", null, fifteen);
            masterId = r.id;
            tally(r.action);
          }
          if (eleven.length) {
            const mId =
              masterId ??
              db.recipes.find(
                (r) => r.recipe_name.toLowerCase() === name.toLowerCase() && !r.parent_recipe_id,
              )?.id ??
              null;
            const r = upsert(name, category, "11_INCH", mId, eleven);
            tally(r.action);
          }
        } else {
          tally(upsert(name, category, null, null, glines).action);
        }
      } catch (e) {
        S.failed++;
        S.errors.push({
          row: 0,
          message: `${glines[0]?.recipe_name}: ${e instanceof Error ? e.message : "failed"}`,
        });
      }
    }

    // Persist: new materials → new recipes → recipe patches → lines.
    if (newMaterials.length) {
      const ins = await c.from("raw_materials").insert(newMaterials);
      if (ins.error) fail("Import recipes", ins.error.message);
    }
    if (recipeInserts.length) {
      const ins = await c.from("recipes").insert(recipeInserts);
      if (ins.error) fail("Import recipes", ins.error.message);
    }
    for (const u of recipeUpdates) {
      const upd = await c.from("recipes").update(u.patch).eq("id", u.id);
      if (upd.error) fail("Import recipes", upd.error.message);
    }
    for (const w of lineWrites) {
      await replaceLines(w.recipeId, w.rows);
    }

    await recomputeRecipes([...new Set(recomputeIds)], actorId, "Recipe import");
    S.total = S.imported + S.updated + S.skipped + S.failed;
    await audit({
      entity_type: "recipe",
      entity_id: "import",
      action: "create",
      new_values: { added: S.imported, updated: S.updated },
      performed_by: actorId,
      notes: `Imported recipes — ${S.imported} added, ${S.updated} updated`,
    });
    return S;
  },

  async duplicate(id: string, actorId: string): Promise<Recipe> {
    const c = sb();
    const srcRes = await c.from("recipes").select("*").eq("id", id).maybeSingle();
    if (srcRes.error) fail("Duplicate recipe", srcRes.error.message);
    if (!srcRes.data) fail("Duplicate recipe", "Recipe not found");
    const src = srcRes.data as Recipe;

    // Find a unique "- Copy" name.
    const allRes = await c.from("recipes").select("recipe_name");
    if (allRes.error) fail("Duplicate recipe", allRes.error.message);
    const names = new Set(
      ((allRes.data ?? []) as { recipe_name: string }[]).map((r) => r.recipe_name.toLowerCase()),
    );
    let name = `${src.recipe_name} - Copy`;
    let n = 2;
    while (names.has(name.toLowerCase())) name = `${src.recipe_name} - Copy ${n++}`;

    const copyId = uid();
    const copy: Recipe = {
      ...src,
      id: copyId,
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
    const insRecipe = await c.from("recipes").insert(copy);
    if (insRecipe.error) fail("Duplicate recipe", insRecipe.error.message);

    const srcLinesRes = await c.from("recipe_ingredients").select("*").eq("recipe_id", id);
    if (srcLinesRes.error) fail("Duplicate recipe", srcLinesRes.error.message);
    const srcLines = ((srcLinesRes.data ?? []) as RecipeIngredient[]).sort(
      (a, b) => a.sort_order - b.sort_order,
    );
    await replaceLines(
      copyId,
      lineRows(
        copyId,
        srcLines.map((l) => ({
          ingredient_id: l.ingredient_id,
          component_type: l.component_type,
          quantity_used: l.quantity_used,
          unit_used: l.unit_used,
        })),
      ),
    );
    await recomputeRecipes([copyId], actorId, "Recipe duplicated");
    const saved = await reloadRecipe(copyId, "Duplicate recipe");
    await snapshotVersion(saved, actorId, "Duplicated");
    await audit({
      entity_type: "recipe",
      entity_id: copyId,
      action: "create",
      performed_by: actorId,
      notes: `Duplicated "${src.recipe_name}" → "${saved.recipe_name}"`,
    });
    return saved;
  },

  async submit(id: string, note: string | null, actorId: string): Promise<Recipe> {
    const c = sb();
    const cur = await c.from("recipes").select("recipe_name").eq("id", id).maybeSingle();
    if (cur.error) fail("Submit recipe", cur.error.message);
    if (!cur.data) fail("Submit recipe", "Recipe not found");
    const { data, error } = await c
      .from("recipes")
      .update({ status: "testing", rejection_note: null, updated_at: nowISO(), updated_by: actorId })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Submit recipe", error.message);
    const recipe = data as Recipe;
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "submit",
      performed_by: actorId,
      notes: note
        ? `Submitted for testing: ${note}`
        : `Submitted "${recipe.recipe_name}" for testing`,
    });
    return recipe;
  },

  async approve(id: string, actorId: string): Promise<Recipe> {
    const c = sb();
    const cur = await c.from("recipes").select("recipe_name").eq("id", id).maybeSingle();
    if (cur.error) fail("Approve recipe", cur.error.message);
    if (!cur.data) fail("Approve recipe", "Recipe not found");
    const { data, error } = await c
      .from("recipes")
      .update({
        status: "approved",
        approved_by: actorId,
        approved_at: nowISO(),
        rejection_note: null,
        updated_at: nowISO(),
        updated_by: actorId,
      })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Approve recipe", error.message);
    const recipe = data as Recipe;
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "approve",
      performed_by: actorId,
      notes: `Approved "${recipe.recipe_name}"`,
    });
    return recipe;
  },

  async reject(id: string, note: string, actorId: string): Promise<Recipe> {
    const c = sb();
    const cur = await c.from("recipes").select("recipe_name").eq("id", id).maybeSingle();
    if (cur.error) fail("Reject recipe", cur.error.message);
    if (!cur.data) fail("Reject recipe", "Recipe not found");
    const { data, error } = await c
      .from("recipes")
      .update({ status: "draft", rejection_note: note, updated_at: nowISO(), updated_by: actorId })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Reject recipe", error.message);
    const recipe = data as Recipe;
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "reject",
      performed_by: actorId,
      notes: `Rejected "${recipe.recipe_name}": ${note}`,
    });
    return recipe;
  },

  /** All cost-history rows across every recipe (for bulk Excel export). */
  async allCostHistory(): Promise<RecipeCostHistory[]> {
    const { data, error } = await sb()
      .from("recipe_cost_history")
      .select("*")
      .order("changed_at", { ascending: false });
    if (error) fail("Load cost history", error.message);
    return (data ?? []) as RecipeCostHistory[];
  },

  /** All recipe ingredient rows joined with their material (bulk export). */
  async allIngredients(): Promise<RecipeIngredientWithMaterial[]> {
    const c = sb();
    const [linesRes, matsRes, recsRes] = await Promise.all([
      c.from("recipe_ingredients").select("*"),
      c.from("raw_materials").select("*"),
      c.from("recipes").select("*"),
    ]);
    if (linesRes.error) fail("Load recipe ingredients", linesRes.error.message);
    if (matsRes.error) fail("Load recipe ingredients", matsRes.error.message);
    if (recsRes.error) fail("Load recipe ingredients", recsRes.error.message);
    const mats = new Map(
      ((matsRes.data ?? []) as RecipeIngredientWithMaterial["material"][])
        .filter((m): m is NonNullable<typeof m> => m != null)
        .map((m) => [m.id, m]),
    );
    const recs = new Map(((recsRes.data ?? []) as Recipe[]).map((r) => [r.id, r]));
    return attach((linesRes.data ?? []) as RecipeIngredient[], mats, recs);
  },

  async setImage(id: string, imageUrl: string | null, actorId: string): Promise<Recipe> {
    const { data, error } = await sb()
      .from("recipes")
      .update({ image_url: imageUrl, updated_at: nowISO(), updated_by: actorId })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Set recipe image", error.message);
    return data as Recipe;
  },

  async setSellingPrice(id: string, price: number | null, actorId: string): Promise<Recipe> {
    const { data, error } = await sb()
      .from("recipes")
      .update({ selling_price: price, updated_at: nowISO(), updated_by: actorId })
      .eq("id", id)
      .select("*")
      .single();
    if (error) fail("Set menu price", error.message);
    const recipe = data as Recipe;
    await audit({
      entity_type: "recipe",
      entity_id: id,
      action: "update",
      performed_by: actorId,
      notes: `Set menu price for "${recipe.recipe_name}" to ${price ?? "—"}`,
    });
    return recipe;
  },

  async costHistory(id: string): Promise<RecipeCostHistory[]> {
    const { data, error } = await sb()
      .from("recipe_cost_history")
      .select("*")
      .eq("recipe_id", id)
      .order("changed_at", { ascending: false });
    if (error) fail("Load cost history", error.message);
    return (data ?? []) as RecipeCostHistory[];
  },

  async versions(id: string): Promise<RecipeVersion[]> {
    const { data, error } = await sb()
      .from("recipe_versions")
      .select("*")
      .eq("recipe_id", id)
      .order("version_no", { ascending: false });
    if (error) fail("Load recipe versions", error.message);
    return (data ?? []) as RecipeVersion[];
  },
};
