import { lazy } from "react";
import { createBrowserRouter, Navigate } from "react-router-dom";
import { AppLayout } from "@/layouts/AppLayout";
import { RequireAuth, RequireRole } from "@/features/auth/guards";
// Auth shell stays eager (small, first paint); everything else is code-split.
import { LoginPage } from "@/features/auth/LoginPage";
import { ForgotPasswordPage } from "@/features/auth/ForgotPasswordPage";
import { ResetPasswordPage } from "@/features/auth/ResetPasswordPage";
import { SignUpPage } from "@/features/auth/SignUpPage";

// Code-split app pages — each becomes its own chunk, kept out of the initial bundle.
const DashboardPage = lazy(() => import("@/features/dashboard/DashboardPage").then((m) => ({ default: m.DashboardPage })));
const MaterialsPage = lazy(() => import("@/features/raw-materials/MaterialsPage").then((m) => ({ default: m.MaterialsPage })));
const RecipesPage = lazy(() => import("@/features/recipes/RecipesPage").then((m) => ({ default: m.RecipesPage })));
const YieldPage = lazy(() => import("@/features/yield/YieldPage").then((m) => ({ default: m.YieldPage })));
const WastagePage = lazy(() => import("@/features/wastage/WastagePage").then((m) => ({ default: m.WastagePage })));
const RecipeEditorPage = lazy(() => import("@/features/recipes/RecipeEditorPage").then((m) => ({ default: m.RecipeEditorPage })));
const RecipeDetailPage = lazy(() => import("@/features/recipes/RecipeDetailPage").then((m) => ({ default: m.RecipeDetailPage })));
const ApprovalsPage = lazy(() => import("@/features/approvals/ApprovalsPage").then((m) => ({ default: m.ApprovalsPage })));
const ReportsPage = lazy(() => import("@/features/reports/ReportsPage").then((m) => ({ default: m.ReportsPage })));
const UsersPage = lazy(() => import("@/features/users/UsersPage").then((m) => ({ default: m.UsersPage })));
const ViewerAccessPage = lazy(() => import("@/features/viewers/ViewerAccessPage").then((m) => ({ default: m.ViewerAccessPage })));
const AuditPage = lazy(() => import("@/features/audit/AuditPage").then((m) => ({ default: m.AuditPage })));
const SettingsPage = lazy(() => import("@/features/settings/SettingsPage").then((m) => ({ default: m.SettingsPage })));
const ProfilePage = lazy(() => import("@/features/profile/ProfilePage").then((m) => ({ default: m.ProfilePage })));

export const router = createBrowserRouter([
  { path: "/login", element: <LoginPage /> },
  { path: "/signup", element: <SignUpPage /> },
  { path: "/forgot-password", element: <ForgotPasswordPage /> },
  { path: "/reset-password", element: <ResetPasswordPage /> },
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
      { path: "profile", element: <ProfilePage /> },
      {
        path: "materials",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <MaterialsPage />
          </RequireRole>
        ),
      },
      { path: "recipes", element: <RecipesPage /> },
      {
        path: "yield",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <YieldPage />
          </RequireRole>
        ),
      },
      {
        path: "wastage",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <WastagePage />
          </RequireRole>
        ),
      },
      {
        path: "prep",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <RecipesPage prepMode />
          </RequireRole>
        ),
      },
      {
        path: "recipes/new",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
            <RecipeEditorPage />
          </RequireRole>
        ),
      },
      {
        path: "recipes/:id/edit",
        element: (
          <RequireRole roles={["admin", "editor", "head_chef"]}>
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
