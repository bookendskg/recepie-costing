import { test, expect } from "@playwright/test";

// PRD §16.3 — per-role login + role-specific landing.
const ROLES = [
  { name: "Admin", email: "rahul@brand.com", nav: "Users" },
  { name: "Editor", email: "priya@brand.com", nav: "Raw Materials" },
  { name: "Viewer", email: "amit@brand.com", nav: "Recipes" },
];

test.describe("Authentication & role routing", () => {
  for (const role of ROLES) {
    test(`${role.name} can log in and sees role nav`, async ({ page }) => {
      await page.goto("/login");
      await page.getByRole("button", { name: role.name, exact: true }).click();
      await page.getByRole("button", { name: "Sign In" }).click();
      await expect(page).toHaveURL(/\/dashboard/);
      await expect(page.getByRole("link", { name: role.nav })).toBeVisible();
    });
  }

  test("invalid credentials show an error", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("Email").fill("nobody@brand.com");
    await page.getByLabel("Password").fill("wrongpassword");
    await page.getByRole("button", { name: "Sign In" }).click();
    await expect(page.getByText("Invalid email or password")).toBeVisible();
  });
});
