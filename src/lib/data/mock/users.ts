import type { Role, User, UserStatus } from "../types";
import { delay, getDb, mutate, nowISO, uid } from "./db";
import { recordAudit } from "./recompute";

export interface CreateUserInput {
  name: string;
  email: string;
  role: Role;
  status?: UserStatus;
  password: string;
}

export interface UpdateUserInput {
  name?: string;
  email?: string;
  role?: Role;
  status?: UserStatus;
  password?: string;
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
        const user: User = {
          id: uid(),
          name: input.name,
          email: input.email,
          role: input.role,
          status: input.status ?? "active",
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
        if (patch.name !== undefined) u.name = patch.name;
        if (patch.email !== undefined) u.email = patch.email;
        if (patch.role !== undefined) u.role = patch.role;
        if (patch.status !== undefined) u.status = patch.status;
        if (patch.password) u.password = patch.password;
        u.updated_at = nowISO();
        recordAudit(db, {
          entity_type: "user",
          entity_id: u.id,
          action: "update",
          old_values: before,
          new_values: { name: u.name, email: u.email, role: u.role, status: u.status },
          performed_by: actorId,
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
