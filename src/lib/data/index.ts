// Active repository set. Selection rules:
//  • USERS  → Supabase whenever Supabase is configured (auth + users live together).
//  • DATA (materials/recipes/yields/wastage) → Supabase ONLY when the opt-in
//    VITE_DATA_BACKEND=supabase flag is set (Phase 2). Otherwise the mock layer,
//    so enabling Supabase auth never silently swaps the data layer. Mock is also
//    the local-dev fallback. No feature code imports the mock/supabase modules.

import { isSupabaseConfigured, isSupabaseDataBackend } from "@/lib/supabase/client";
import { usersRepo as mockUsersRepo } from "./mock/users";
import { supabaseUsersRepo } from "./supabase/users";
import { materialsRepo as mockMaterialsRepo } from "./mock/materials";
import { supabaseMaterialsRepo } from "./supabase/materials";
import { yieldsRepo as mockYieldsRepo } from "./mock/yields";
import { supabaseYieldsRepo } from "./supabase/yields";
import { wastageRepo as mockWastageRepo } from "./mock/wastage";
import { supabaseWastageRepo } from "./supabase/wastage";
import { recipesRepo as mockRecipesRepo } from "./mock/recipes";
import { supabaseRecipesRepo } from "./supabase/recipes";

export { authenticate } from "./mock/users";
export { applicableUnitCost } from "./mock/wastage";
export type { CreateUserInput, UpdateUserInput } from "./mock/users";
export type { MaterialInput } from "./mock/materials";
export type { YieldInput, ImportYieldRow } from "./mock/yields";
export type { WastageInput } from "./mock/wastage";
export type { RecipeHeaderInput, RecipeLineInput, ImportRecipeLine } from "./mock/recipes";

export const usersRepo = isSupabaseConfigured ? supabaseUsersRepo : mockUsersRepo;
export const materialsRepo = isSupabaseDataBackend ? supabaseMaterialsRepo : mockMaterialsRepo;
export const yieldsRepo = isSupabaseDataBackend ? supabaseYieldsRepo : mockYieldsRepo;
export const wastageRepo = isSupabaseDataBackend ? supabaseWastageRepo : mockWastageRepo;
export const recipesRepo = isSupabaseDataBackend ? supabaseRecipesRepo : mockRecipesRepo;

export { viewsRepo, settingsRepo, auditRepo } from "./mock/misc";
export type { AuditFilter } from "./mock/misc";

export { resetDb } from "./mock/db";
export * from "./types";
