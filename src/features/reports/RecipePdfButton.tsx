import { FileDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { Recipe, RecipeIngredientWithMaterial } from "@/lib/data/types";
import type { ViewVisibility } from "@/lib/auth/permissions";
import { generateRecipePdf } from "./pdf";
import { toast } from "@/components/ui/use-toast";

export function RecipePdfButton({
  recipe,
  ingredients,
  foodCostPct,
  visibility,
}: {
  recipe: Recipe;
  ingredients: RecipeIngredientWithMaterial[];
  foodCostPct: number;
  visibility?: ViewVisibility;
}) {
  return (
    <Button
      variant="outline"
      onClick={async () => {
        try {
          await generateRecipePdf(recipe, ingredients, foodCostPct, visibility);
        } catch (e) {
          toast.error(e instanceof Error ? e.message : "PDF export failed");
        }
      }}
    >
      <FileDown className="h-4 w-4" /> Export PDF
    </Button>
  );
}
