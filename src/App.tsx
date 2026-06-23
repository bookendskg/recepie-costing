import { useEffect } from "react";
import { RouterProvider } from "react-router-dom";
import { QueryClientProvider } from "@tanstack/react-query";
import { router } from "./router";
import { queryClient } from "./lib/queryClient";
import { Toaster } from "./components/ui/toaster";
import { applyTheme, useTheme } from "./lib/theme";

export default function App() {
  const dark = useTheme((s) => s.dark);
  useEffect(() => {
    applyTheme(dark);
  }, [dark]);

  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
      <Toaster />
    </QueryClientProvider>
  );
}
