// Zod schemas. Error messages copied verbatim from PRD §12 where specified.

import { z } from "zod";
import { BASE_UNITS, PURCHASE_UNITS, canConvert } from "../units";

export const loginSchema = z.object({
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
  password: z.string().min(8, "Password must be at least 8 characters"),
});
export type LoginValues = z.infer<typeof loginSchema>;

export const userSchema = z.object({
  name: z.string().min(1, "Name is required"),
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
  role: z.enum(["admin", "editor", "viewer"]),
  status: z.enum(["active", "inactive"]),
  password: z
    .string()
    .min(8, "Password must be at least 8 characters")
    .optional()
    .or(z.literal("")),
});
export type UserValues = z.infer<typeof userSchema>;

export const materialSchema = z
  .object({
    ingredient_name: z.string().min(1, "Ingredient name is required"),
    category: z.string().min(1, "Category is required"),
    supplier_name: z.string().optional().or(z.literal("")),
    purchase_price: z
      .number({ invalid_type_error: "Purchase price must be greater than 0" })
      .gt(0, "Purchase price must be greater than 0"),
    purchase_quantity: z
      .number({ invalid_type_error: "Purchase quantity must be greater than 0" })
      .gt(0, "Purchase quantity must be greater than 0"),
    purchase_unit: z.enum(PURCHASE_UNITS),
    base_unit: z.enum(BASE_UNITS),
  })
  .refine((v) => canConvert(v.purchase_unit, v.base_unit), {
    message: "Cannot convert this purchase unit to the chosen base unit",
    path: ["base_unit"],
  });
export type MaterialValues = z.infer<typeof materialSchema>;

export const recipeHeaderSchema = z.object({
  recipe_name: z.string().min(1, "Recipe name is required"),
  category: z.string().min(1, "Category is required"),
  brand: z.enum(["capiche", "aiko"], { required_error: "Brand is required" }),
  description: z.string().optional().or(z.literal("")),
  preparation_time: z
    .number({ invalid_type_error: "Enter a valid time" })
    .positive("Preparation time must be greater than 0")
    .optional()
    .nullable(),
  serving_size: z
    .number({ invalid_type_error: "Serving size must be at least 1" })
    .int()
    .min(1, "Serving size must be at least 1"),
  selling_price: z
    .number({ invalid_type_error: "Enter a valid price" })
    .positive("Menu price must be greater than 0")
    .optional()
    .nullable(),
  wastage_pct: z
    .number({ invalid_type_error: "Enter a valid %" })
    .min(0, "Wastage cannot be negative")
    .max(100, "Wastage must be 100% or less"),
});
export type RecipeHeaderValues = z.infer<typeof recipeHeaderSchema>;

export const recipeLineSchema = z.object({
  ingredient_id: z.string().min(1, "Select an ingredient"),
  quantity_used: z.number().gt(0, "Quantity must be greater than 0"),
  unit_used: z.string().min(1),
});
export type RecipeLineValues = z.infer<typeof recipeLineSchema>;
