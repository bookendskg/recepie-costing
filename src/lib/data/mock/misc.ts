import type {
  AuditEntityType,
  AuditLog,
  SystemSetting,
  UserRecipeView,
  ViewType,
} from "../types";
import { delay, getDb, mutate, nowISO, uid } from "./db";
import { recordAudit } from "./recompute";

// --- Viewer access (user_recipe_views) ------------------------------------
export const viewsRepo = {
  async listForUser(userId: string): Promise<UserRecipeView[]> {
    return delay(getDb().user_recipe_views.filter((v) => v.user_id === userId));
  },

  async listForRecipe(recipeId: string): Promise<UserRecipeView[]> {
    return delay(getDb().user_recipe_views.filter((v) => v.recipe_id === recipeId));
  },

  async setAccess(
    userId: string,
    recipeId: string,
    viewType: ViewType,
    actorId: string,
  ): Promise<UserRecipeView> {
    return delay(
      mutate((db) => {
        let row = db.user_recipe_views.find(
          (v) => v.user_id === userId && v.recipe_id === recipeId,
        );
        if (row) {
          row.view_type = viewType;
          row.assigned_by = actorId;
          row.assigned_at = nowISO();
        } else {
          row = {
            id: uid(),
            user_id: userId,
            recipe_id: recipeId,
            view_type: viewType,
            assigned_by: actorId,
            assigned_at: nowISO(),
          };
          db.user_recipe_views.push(row);
        }
        return row;
      }),
    );
  },

  async remove(userId: string, recipeId: string): Promise<void> {
    return delay(
      mutate((db) => {
        db.user_recipe_views = db.user_recipe_views.filter(
          (v) => !(v.user_id === userId && v.recipe_id === recipeId),
        );
      }),
    );
  },
};

// --- System settings -------------------------------------------------------
export const settingsRepo = {
  async getAll(): Promise<SystemSetting[]> {
    return delay([...getDb().system_settings]);
  },

  async get(key: string): Promise<string | null> {
    return delay(getDb().system_settings.find((s) => s.key === key)?.value ?? null);
  },

  async foodCostPct(): Promise<number> {
    const v = getDb().system_settings.find((s) => s.key === "food_cost_pct")?.value;
    return delay(v ? Number(v) : 30);
  },

  async set(key: string, value: string, actorId: string): Promise<void> {
    return delay(
      mutate((db) => {
        const row = db.system_settings.find((s) => s.key === key);
        if (row) {
          row.value = value;
          row.updated_by = actorId;
          row.updated_at = nowISO();
        } else {
          db.system_settings.push({
            id: uid(),
            key,
            value,
            updated_by: actorId,
            updated_at: nowISO(),
          });
        }
      }),
    );
  },
};

// --- Audit log -------------------------------------------------------------
export interface AuditFilter {
  entityType?: AuditEntityType | "all";
  userId?: string | "all";
  from?: string;
  to?: string;
}

export const auditRepo = {
  async list(filter: AuditFilter = {}): Promise<AuditLog[]> {
    let rows = [...getDb().audit_logs];
    if (filter.entityType && filter.entityType !== "all") {
      rows = rows.filter((r) => r.entity_type === filter.entityType);
    }
    if (filter.userId && filter.userId !== "all") {
      rows = rows.filter((r) => r.performed_by === filter.userId);
    }
    if (filter.from) rows = rows.filter((r) => r.performed_at >= filter.from!);
    if (filter.to) rows = rows.filter((r) => r.performed_at <= filter.to! + "T23:59:59.999Z");
    rows.sort((a, b) => b.performed_at.localeCompare(a.performed_at));
    return delay(rows);
  },

  /** Direct audit writer for events not covered by a specific repo. */
  async record(entry: {
    entity_type: AuditEntityType;
    entity_id: string;
    action: AuditLog["action"];
    performed_by: string | null;
    notes?: string;
  }): Promise<void> {
    return delay(mutate((db) => void recordAudit(db, entry)));
  },
};
