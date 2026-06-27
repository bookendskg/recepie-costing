// Active repository set. Currently the mock (localStorage) implementation.
// To switch to Supabase later: add src/lib/data/supabase/* implementing the
// same exports and re-export from here behind an env flag — no feature code
// imports the mock modules directly.

export { usersRepo, authenticate, linkFirebaseUser } from "./mock/users";
export type { CreateUserInput, UpdateUserInput } from "./mock/users";

export { materialsRepo } from "./mock/materials";
export type { MaterialInput } from "./mock/materials";

export { yieldsRepo } from "./mock/yields";
export type { YieldInput } from "./mock/yields";

export { wastageRepo, applicableUnitCost } from "./mock/wastage";
export type { WastageInput } from "./mock/wastage";

export { recipesRepo } from "./mock/recipes";
export type {
  RecipeHeaderInput,
  RecipeLineInput,
  ImportRecipeLine,
} from "./mock/recipes";

export { viewsRepo, settingsRepo, auditRepo } from "./mock/misc";
export type { AuditFilter } from "./mock/misc";

export { resetDb } from "./mock/db";
export * from "./types";
