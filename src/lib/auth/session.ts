import { create } from "zustand";
import { persist } from "zustand/middleware";
import type { User } from "../data/types";
import { authenticate } from "../data";

interface SessionState {
  user: User | null;
  loading: boolean;
  error: string | null;
  login: (email: string, password: string) => Promise<User>;
  logout: () => void;
  setUser: (user: User | null) => void;
}

export const useSession = create<SessionState>()(
  persist(
    (set) => ({
      user: null,
      loading: false,
      error: null,
      async login(email, password) {
        set({ loading: true, error: null });
        try {
          const user = await authenticate(email, password);
          set({ user, loading: false });
          return user;
        } catch (e) {
          const message = e instanceof Error ? e.message : "Login failed";
          set({ error: message, loading: false });
          throw e;
        }
      },
      logout() {
        set({ user: null, error: null });
      },
      setUser(user) {
        set({ user });
      },
    }),
    {
      name: "rcms.session",
      partialize: (s) => ({ user: s.user }),
    },
  ),
);
