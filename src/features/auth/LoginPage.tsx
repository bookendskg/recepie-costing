import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { ChefHat, Eye, EyeOff, Loader2 } from "lucide-react";
import { useSession } from "@/lib/auth/session";
import { isSupabaseConfigured } from "@/lib/supabase/client";
import { loginSchema, type LoginValues } from "@/lib/validation/schemas";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

const DEMO = [
  { role: "Admin", email: "rahul@brand.com" },
  { role: "Editor", email: "priya@brand.com" },
  { role: "Viewer", email: "amit@brand.com" },
];

export function LoginPage() {
  const login = useSession((s) => s.login);
  const navigate = useNavigate();
  const [serverError, setServerError] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);

  const {
    register,
    handleSubmit,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<LoginValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "", password: "" },
  });

  const onSubmit = async (values: LoginValues) => {
    setServerError(null);
    try {
      await login(values.email, values.password);
      navigate("/dashboard", { replace: true });
    } catch (e) {
      setServerError(e instanceof Error ? e.message : "Login failed");
    }
  };

  const fillDemo = (email: string) => {
    setValue("email", email);
    setValue("password", "password123");
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 p-4">
      <Card className="w-full max-w-sm">
        <CardHeader className="items-center text-center">
          <div className="mb-2 flex h-12 w-12 items-center justify-center rounded-full bg-accent/10">
            <ChefHat className="h-7 w-7 text-accent" />
          </div>
          <CardTitle>Recipe Costing Management</CardTitle>
          <CardDescription>Sign in to your account</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="email">Email</Label>
              <Input id="email" type="email" autoComplete="username" {...register("email")} />
              {errors.email && (
                <p className="text-xs text-destructive">{errors.email.message}</p>
              )}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="password">Password</Label>
              <div className="relative">
                <Input
                  id="password"
                  type={showPassword ? "text" : "password"}
                  autoComplete="current-password"
                  className="pr-10"
                  {...register("password")}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((s) => !s)}
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                  aria-label={showPassword ? "Hide password" : "Show password"}
                  tabIndex={-1}
                >
                  {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {errors.password && (
                <p className="text-xs text-destructive">{errors.password.message}</p>
              )}
            </div>
            {serverError && (
              <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
                {serverError}
              </div>
            )}
            <Button type="submit" variant="accent" className="w-full" disabled={isSubmitting}>
              {isSubmitting && <Loader2 className="h-4 w-4 animate-spin" />}
              Sign In
            </Button>
            <Link
              to="/forgot-password"
              className="block w-full text-center text-xs text-muted-foreground hover:underline"
            >
              Forgot Password?
            </Link>
          </form>

          {/* Supabase mode: offer account creation (mock mode uses demo accounts). */}
          {isSupabaseConfigured && (
            <p className="mt-4 text-center text-sm text-muted-foreground">
              Don't have an account?{" "}
              <Link to="/signup" className="font-medium text-accent hover:underline">
                Create one
              </Link>
            </p>
          )}

          {/* Demo accounts are only useful against the mock layer. */}
          {!isSupabaseConfigured && (
            <div className="mt-6 border-t pt-4">
              <p className="mb-2 text-center text-xs text-muted-foreground">
                Demo accounts (password: password123)
              </p>
              <div className="flex flex-wrap justify-center gap-2">
                {DEMO.map((d) => (
                  <Button
                    key={d.email}
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => fillDemo(d.email)}
                  >
                    {d.role}
                  </Button>
                ))}
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
