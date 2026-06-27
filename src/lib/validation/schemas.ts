// Zod schemas. Error messages copied verbatim from PRD §12 where specified.

import { z } from "zod";
import { BASE_UNITS, PURCHASE_UNITS, canConvert } from "../units";
import { toBaseQuantity } from "../yield";
import { WASTAGE_TYPES, DEPARTMENTS } from "../data/types";

export const loginSchema = z.object({
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
  password: z.string().min(8, "Password must be at least 8 characters"),
});
export type LoginValues = z.infer<typeof loginSchema>;

/** Secure password rule used for set/reset/change flows. */
export const passwordSchema = z
  .string()
  .min(8, "Password must be at least 8 characters")
  .regex(/[A-Za-z]/, "Include at least one letter")
  .regex(/[0-9]/, "Include at least one number");

export const forgotPasswordSchema = z.object({
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
});
export type ForgotPasswordValues = z.infer<typeof forgotPasswordSchema>;

export const signupSchema = z.object({
  name: z.string().min(1, "Name is required"),
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
  password: passwordSchema,
});
export type SignupValues = z.infer<typeof signupSchema>;

export const resetPasswordSchema = z
  .object({
    password: passwordSchema,
    confirm: z.string().min(1, "Confirm your password"),
  })
  .refine((v) => v.password === v.confirm, {
    message: "Passwords do not match",
    path: ["confirm"],
  });
export type ResetPasswordValues = z.infer<typeof resetPasswordSchema>;

export const changePasswordSchema = resetPasswordSchema;
export type ChangePasswordValues = ResetPasswordValues;

export const userSchema = z.object({
  name: z.string().min(1, "Name is required"),
  email: z.string().min(1, "Email is required").email("Enter a valid email"),
  role: z.enum(["admin", "editor", "head_chef", "chef", "viewer"]),
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
    notes: z.string().optional().or(z.literal("")),
    // Optional: an ingredient can be created with its price pending (null/empty).
    // When a price IS entered it must be > 0 with at most two decimals.
    purchase_price: z
      .number({ invalid_type_error: "Enter a valid price" })
      .finite("Enter a valid price")
      .gt(0, "Purchase price must be greater than 0")
      .refine((v) => Number(v.toFixed(2)) === v, "Use at most two decimal places")
      .nullish(),
    purchase_quantity: z
      .number({ invalid_type_error: "Purchase quantity must be greater than 0" })
      .finite("Enter a valid quantity")
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
  packaging_cost: z
    .number({ invalid_type_error: "Enter a valid amount" })
    .min(0, "Packaging cost cannot be negative")
    .refine((v) => Number(v.toFixed(2)) === v, "Use at most two decimal places"),
  wastage_pct: z
    .number({ invalid_type_error: "Enter a valid %" })
    .min(0, "Wastage cannot be negative")
    .max(100, "Wastage must be 100% or less"),
});
export type RecipeHeaderValues = z.infer<typeof recipeHeaderSchema>;

export const yieldSchema = z
  .object({
    ingredient_id: z.string().min(1, "Select an ingredient"),
    purchase_cost: z
      .number({ invalid_type_error: "Enter a valid cost" })
      .finite("Enter a valid cost")
      .gt(0, "Purchase cost must be greater than 0")
      .refine((v) => Number(v.toFixed(2)) === v, "Use at most two decimal places"),
    purchase_quantity: z
      .number({ invalid_type_error: "Enter a valid quantity" })
      .finite("Enter a valid quantity")
      .gt(0, "Purchase quantity must be greater than 0"),
    purchase_unit: z.enum(PURCHASE_UNITS),
    wastage_quantity: z
      .number({ invalid_type_error: "Enter a valid wastage" })
      .finite("Enter a valid wastage")
      .min(0, "Wastage cannot be negative"),
    effective_from: z.string().min(1, "Effective date is required"),
    notes: z.string().optional().or(z.literal("")),
  })
  .refine((v) => v.wastage_quantity < toBaseQuantity(v.purchase_quantity, v.purchase_unit), {
    message: "Wastage quantity cannot be greater than or equal to the raw quantity.",
    path: ["wastage_quantity"],
  });
export type YieldValues = z.infer<typeof yieldSchema>;

export const wastageSchema = z
  .object({
    wastage_date: z.string().min(1, "Date is required"),
    brand: z.enum(["capiche", "aiko"]),
    outlet_id: z.string().min(1, "Select an outlet"),
    wastage_type: z.enum(WASTAGE_TYPES),
    item_type: z.enum(["ingredient", "recipe"]),
    ingredient_id: z.string().nullable().optional(),
    recipe_id: z.string().nullable().optional(),
    quantity: z
      .number({ invalid_type_error: "Enter a valid quantity" })
      .finite("Enter a valid quantity")
      .gt(0, "Quantity must be greater than 0"),
    unit: z.string().min(1, "Unit is required"),
    unit_cost: z
      .number({ invalid_type_error: "Enter a valid cost" })
      .finite("Enter a valid cost")
      .min(0, "Cost cannot be negative")
      .refine((v) => Number(v.toFixed(2)) === v, "Use at most two decimal places"),
    reason: z.string().optional().or(z.literal("")),
    department: z.enum(DEPARTMENTS),
    shift: z.string().optional().or(z.literal("")),
    approved_by: z.string().optional().or(z.literal("")),
    notes: z.string().optional().or(z.literal("")),
  })
  .refine((v) => (v.item_type === "ingredient" ? !!v.ingredient_id : !!v.recipe_id), {
    message: "Select the wasted item",
    path: ["ingredient_id"],
  });
export type WastageValues = z.infer<typeof wastageSchema>;

export const recipeLineSchema = z.object({
  ingredient_id: z.string().min(1, "Select an ingredient"),
  quantity_used: z.number().gt(0, "Quantity must be greater than 0"),
  unit_used: z.string().min(1),
});
export type RecipeLineValues = z.infer<typeof recipeLineSchema>;
