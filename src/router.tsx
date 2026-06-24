import { createBrowserRouter, Navigate } from "react-router-dom";
import { AppLayout } from "@/layouts/AppLayout";
import { RequireAuth, RequireRole } from "@/features/auth/guards";
import { LoginPage } from "@/features/auth/LoginPage";
import { DashboardPage } from "@/features/dashboard/DashboardPage";
import { MaterialsPage } from "@/features/raw-materials/MaterialsPage";
import { RecipesPage } from "@/features/recipes/RecipesPage";
import { RecipeEditorPage } from "@/features/recipes/RecipeEditorPage";
import { RecipeDetailPage } from "@/features/recipes/RecipeDetailPage";
import { ApprovalsPage } from "@/features/approvals/ApprovalsPage";
import { ReportsPage } from "@/features/reports/ReportsPage";
import { UsersPage } from "@/features/users/UsersPage";
import { ViewerAccessPage } from "@/features/viewers/ViewerAccessPage";
import { AuditPage } from "@/features/audit/AuditPage";
import { SettingsPage } from "@/features/settings/SettingsPage";

export const router = createBrowserRouter([
  { path: "/login", element: <LoginPage /> },
  {
    path: "/",
    element: (
      <RequireAuth>
        <AppLayout />
      </RequireAuth>
    ),
    children: [
      { index: true, element: <Navigate to="/dashboard" replace /> },
      { path: "dashboard", element: <DashboardPage /> },
      {
        path: "materials",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef", "chef"]}>
            <MaterialsPage />
          </RequireRole>
        ),
      },
      { path: "recipes", element: <RecipesPage /> },
      {
        path: "prep",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef", "chef"]}>
            <RecipesPage prepMode />
          </RequireRole>
        ),
      },
      {
        path: "recipes/new",
        element: (
          <RequireRole roles={["admin", "editor"]}>
            <RecipeEditorPage />
          </RequireRole>
        ),
      },
      {
        path: "recipes/:id/edit",
        element: (
          <RequireRole roles={["admin", "editor"]}>
            <RecipeEditorPage />
          </RequireRole>
        ),
      },
      { path: "recipes/:id", element: <RecipeDetailPage /> },
      {
        path: "approvals",
        element: (
          <RequireRole roles={["admin"]}>
            <ApprovalsPage />
          </RequireRole>
        ),
      },
      {
        path: "reports",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <ReportsPage />
          </RequireRole>
        ),
      },
      {
        path: "viewer-access",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <ViewerAccessPage />
          </RequireRole>
        ),
      },
      {
        path: "users",
        element: (
          <RequireRole roles={["admin"]}>
            <UsersPage />
          </RequireRole>
        ),
      },
      {
        path: "audit",
        element: (
          <RequireRole roles={["admin"]}>
            <AuditPage />
          </RequireRole>
        ),
      },
      {
        path: "settings",
        element: (
          <RequireRole roles={["admin"]}>
            <SettingsPage />
          </RequireRole>
        ),
      },
    ],
  },
  { path: "*", element: <Navigate to="/dashboard" replace /> },
]);
