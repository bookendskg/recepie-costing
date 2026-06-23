// Active repository set. Currently the mock (localStorage) implementation.
// To switch to Supabase later: add src/lib/data/supabase/* implementing the
// same exports and re-export from here behind an env flag — no feature code
// imports the mock modules directly.

export { usersRepo, authenticate } from "./mock/users";
export type { CreateUserInput, UpdateUserInput } from "./mock/users";

export { materialsRepo } from "./mock/materials";
export type { MaterialInput } from "./mock/materials";

export { recipesRepo } from "./mock/recipes";
export type {
  RecipeHeaderInput,
  RecipeLineInput,
} from "./mock/recipes";

export { viewsRepo, settingsRepo, auditRepo } from "./mock/misc";
export type { AuditFilter } from "./mock/misc";

export { resetDb } from "./mock/db";
export * from "./types";
