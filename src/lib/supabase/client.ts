import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

/**
 * True only when BOTH Supabase env vars are present. When false the whole app
 * transparently falls back to the mock/localStorage auth + data layer, so the
 * build ships and runs fine before a Supabase project exists.
 */
export const isSupabaseConfigured = Boolean(url && anonKey);

/**
 * Phase 2 data backend (materials/recipes/yields/wastage) — OPT-IN and separate
 * from auth so enabling Supabase auth doesn't silently swap the whole data layer
 * onto the (newer) Supabase repos. Set VITE_DATA_BACKEND=supabase to turn it on.
 */
export const isSupabaseDataBackend =
  isSupabaseConfigured && import.meta.env.VITE_DATA_BACKEND === "supabase";

/**
 * The Supabase client, or `null` in mock mode. Feature code must NOT import this
 * directly — go through `src/lib/auth/session.ts` and `src/lib/supabase/profile.ts`
 * so the mock fallback stays centralized.
 */
export const supabase: SupabaseClient | null = isSupabaseConfigured
  ? createClient(url!, anonKey!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        // Required so the password-reset / email-verification redirect tokens
        // in the URL hash are consumed on load.
        detectSessionInUrl: true,
      },
    })
  : null;
