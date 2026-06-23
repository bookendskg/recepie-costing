import { create } from "zustand";
import { persist } from "zustand/middleware";

interface ThemeState {
  dark: boolean;
  toggle: () => void;
}

export const useTheme = create<ThemeState>()(
  persist(
    (set) => ({
      dark: false,
      toggle: () => set((s) => ({ dark: !s.dark })),
    }),
    { name: "rcms.theme" },
  ),
);

/** Apply the persisted theme class to <html>. Call once at startup + on change. */
export function applyTheme(dark: boolean) {
  document.documentElement.classList.toggle("dark", dark);
}
