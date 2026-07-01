import type { Brand, Role, User, UserStatus } from "../types";
import { delay, getDb, mutate, nowISO, uid } from "./db";
import { recordAudit } from "./recompute";

export interface CreateUserInput {
  name: string;
  email: string;
  role: Role;
  status?: UserStatus;
  assigned_brand?: Brand | null;
  assigned_outlet?: string | null;
  password: string;
}

export interface UpdateUserInput {
  name?: string;
  email?: string;
  role?: Role;
  status?: UserStatus;
  assigned_brand?: Brand | null;
  assigned_outlet?: string | null;
  password?: string;
  phone?: string | null;
  avatar_url?: string | null;
  last_login?: string | null;
  accessible_brands?: Brand[];
  show_cost?: boolean;
  dashboard_access?: boolean;
  approved?: boolean;
}

/** Strip the mock-only password before handing a user to the UI. */
function publicUser(u: User): User {
  const { password: _pw, ...rest } = u;
  return rest;
}

export const usersRepo = {
  async list(): Promise<User[]> {
    return delay(getDb().users.map(publicUser));
  },

  async getById(id: string): Promise<User | null> {
    const u = getDb().users.find((x) => x.id === id);
    return delay(u ? publicUser(u) : null);
  },

  async create(input: CreateUserInput, actorId: string): Promise<User> {
    return delay(
      mutate((db) => {
        if (db.users.some((u) => u.email.toLowerCase() === input.email.toLowerCase())) {
          throw new Error("A user with this email already exists");
        }
        // Only a Super Admin may create another Super Admin (addendum §8/§3).
        if (input.role === "super_admin" && db.users.find((x) => x.id === actorId)?.role !== "super_admin") {
          throw new Error("Only a Super Admin can create a Super Admin");
        }
        const user: User = {
          id: uid(),
          name: input.name,
          email: input.email,
          role: input.role,
          status: input.status ?? "active",
          assigned_brand: input.assigned_brand ?? null,
          assigned_outlet: input.assigned_outlet ?? null,
          approved: true, // an admin is creating this account → pre-approved
          last_role_update: nowISO(),
          role_updated_by: actorId,
          password: input.password,
          created_at: nowISO(),
          updated_at: nowISO(),
        };
        db.users.push(user);
        recordAudit(db, {
          entity_type: "user",
          entity_id: user.id,
          action: "create",
          new_values: { name: user.name, email: user.email, role: user.role },
          performed_by: actorId,
          notes: `Created user ${user.email}`,
        });
        return publicUser(user);
      }),
    );
  },

  async update(id: string, patch: UpdateUserInput, actorId: string): Promise<User> {
    return delay(
      mutate((db) => {
        const u = db.users.find((x) => x.id === id);
        if (!u) throw new Error("User not found");
        const before = { name: u.name, email: u.email, role: u.role, status: u.status };
        const roleChanged = patch.role !== undefined && patch.role !== u.role;
        // §28 privilege-escalation safeguards.
        if (roleChanged && id === actorId) {
          throw new Error("You cannot change your own role");
        }
        const isActiveAdmin = (x: typeof u) => x.role === "admin" && x.status === "active" && x.approved !== false;
        const demotingAdmin = u.role === "admin" && roleChanged && patch.role !== "admin";
        const disablingAdmin = u.role === "admin" && patch.status === "inactive";
        if ((demotingAdmin || disablingAdmin) && db.users.filter(isActiveAdmin).length <= 1) {
          throw new Error("Cannot remove the last remaining Admin");
        }
        // Super Admin safeguards (addendum §8 + §4).
        const actor = db.users.find((x) => x.id === actorId);
        const actorIsSuper = actor?.role === "super_admin";
        const targetIsSuper = u.role === "super_admin";
        const assigningSuper = patch.role === "super_admin";
        // Only a Super Admin may assign the Super Admin role or edit a Super Admin user.
        if ((assigningSuper || (targetIsSuper && (roleChanged || patch.status !== undefined))) && !actorIsSuper) {
          throw new Error("Only a Super Admin can manage Super Admin users");
        }
        // The system must always retain at least one active Super Admin.
        const isActiveSuper = (x: typeof u) => x.role === "super_admin" && x.status === "active" && x.approved !== false;
        const demotingSuper = targetIsSuper && roleChanged && patch.role !== "super_admin";
        const disablingSuper = targetIsSuper && patch.status === "inactive";
        if ((demotingSuper || disablingSuper) && db.users.filter(isActiveSuper).length <= 1) {
          throw new Error("This action cannot be completed because the system must retain at least one active Super Admin.");
        }
        if (patch.name !== undefined) u.name = patch.name;
        if (patch.email !== undefined) u.email = patch.email;
        if (patch.role !== undefined) u.role = patch.role;
        if (patch.status !== undefined) u.status = patch.status;
        if (patch.assigned_brand !== undefined) u.assigned_brand = patch.assigned_brand;
        if (patch.assigned_outlet !== undefined) u.assigned_outlet = patch.assigned_outlet;
        if (patch.password) u.password = patch.password;
        if (patch.phone !== undefined) u.phone = patch.phone;
        if (patch.avatar_url !== undefined) u.avatar_url = patch.avatar_url;
        if (patch.last_login !== undefined) u.last_login = patch.last_login;
        if (patch.accessible_brands !== undefined) u.accessible_brands = patch.accessible_brands;
        if (patch.show_cost !== undefined) u.show_cost = patch.show_cost;
        if (patch.dashboard_access !== undefined) u.dashboard_access = patch.dashboard_access;
        if (patch.approved !== undefined) u.approved = patch.approved;
        if (roleChanged) {
          u.last_role_update = nowISO();
          u.role_updated_by = actorId;
        }
        u.updated_at = nowISO();
        recordAudit(db, {
          entity_type: "user",
          entity_id: u.id,
          action: "update",
          old_values: before,
          new_values: { name: u.name, email: u.email, role: u.role, status: u.status },
          performed_by: actorId,
          notes: roleChanged ? `Role changed ${before.role} → ${u.role}` : undefined,
        });
        return publicUser(u);
      }),
    );
  },
};

/** Mock auth — validates credentials and account status (PRD Module 1). */
export async function authenticate(email: string, password: string): Promise<User> {
  const db = getDb();
  const u = db.users.find((x) => x.email.toLowerCase() === email.toLowerCase());
  if (!u || u.password !== password) {
    throw new Error("Invalid email or password");
  }
  if (u.status === "inactive") {
    throw new Error("Your account has been deactivated. Contact admin.");
  }
  return delay(publicUser(u));
}
