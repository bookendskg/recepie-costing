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
          assigned_brand: input.assigned_brand ?? null,
          assigned_outlet: input.assigned_outlet ?? null,
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

/**
 * Owner emails that are always granted Admin on sign-in/sign-up. This is the
 * bootstrap so the business owner gets in as Admin with their real email,
 * without needing an existing admin to elevate them. Lower-cased for matching.
 * Extend via VITE_OWNER_EMAILS (comma-separated) without editing code.
 */
const OWNER_EMAILS = new Set(
  [
    "reservation.bookends@gmail.com",
    "moin.bookends@gmail.com",
    ...(import.meta.env?.VITE_OWNER_EMAILS ?? "").split(","),
  ]
    .map((e: string) => e.trim().toLowerCase())
    .filter(Boolean),
);

/**
 * Map a Firebase-authenticated identity to the internal profile (Firebase
 * migration). Finds the profile by email — preserving the existing role of
 * seeded/known users — or creates a new one defaulting to Viewer (owner emails
 * become Admin). Stores the Firebase UID and stamps last_login. Roles always
 * live in this profile store, never in Firebase. Throws if the account is disabled.
 */
export async function linkFirebaseUser(
  firebaseUid: string,
  email: string,
  displayName?: string | null,
  emailVerified?: boolean,
): Promise<User> {
  return delay(
    mutate((db) => {
      const isOwner = OWNER_EMAILS.has(email.toLowerCase());
      let u = db.users.find((x) => x.email.toLowerCase() === email.toLowerCase());
      if (!u) {
        u = {
          id: uid(),
          name: displayName || email.split("@")[0],
          email,
          // new accounts are Viewer until an admin elevates them — owners are Admin
          role: isOwner ? "admin" : "viewer",
          status: "active",
          firebase_uid: firebaseUid,
          email_verified: emailVerified ?? false,
          last_role_update: isOwner ? nowISO() : null,
          created_at: nowISO(),
          updated_at: nowISO(),
          last_login: nowISO(),
        };
        db.users.push(u);
        recordAudit(db, {
          entity_type: "user",
          entity_id: u.id,
          action: "create",
          new_values: { name: u.name, email: u.email, role: u.role },
          performed_by: null,
          notes: `Firebase sign-up ${u.email} (${isOwner ? "owner → Admin" : "default Viewer"})`,
        });
      } else {
        u.firebase_uid = firebaseUid;
        if (emailVerified !== undefined) u.email_verified = emailVerified;
        // Ensure owners are always Admin, even if a prior sign-up made them Viewer.
        if (isOwner && u.role !== "admin") {
          u.role = "admin";
          u.last_role_update = nowISO();
          recordAudit(db, {
            entity_type: "user",
            entity_id: u.id,
            action: "update",
            new_values: { role: "admin" },
            performed_by: null,
            notes: `Owner ${u.email} elevated to Admin`,
          });
        }
        u.last_login = nowISO();
        u.updated_at = nowISO();
      }
      if (u.status === "inactive") {
        throw new Error("Your account is disabled. Please contact an administrator.");
      }
      return publicUser(u);
    }),
  );
}

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
