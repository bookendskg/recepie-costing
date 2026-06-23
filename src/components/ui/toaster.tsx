import { X } from "lucide-react";
import { cn } from "@/lib/utils";
import { useToastStore, type ToastVariant } from "./use-toast";

const variantStyles: Record<ToastVariant, string> = {
  default: "border bg-background text-foreground",
  success: "border-green-600 bg-green-600 text-white",
  destructive: "border-red-600 bg-red-600 text-white",
  warning: "border-amber-500 bg-amber-500 text-white",
};

export function Toaster() {
  const { toasts, dismiss } = useToastStore();
  return (
    <div className="fixed bottom-4 right-4 z-[100] flex w-full max-w-sm flex-col gap-2">
      {toasts.map((t) => (
        <div
          key={t.id}
          className={cn(
            "pointer-events-auto flex items-start gap-3 rounded-md p-4 shadow-lg",
            variantStyles[t.variant],
          )}
        >
          <div className="flex-1">
            <p className="text-sm font-semibold">{t.title}</p>
            {t.description && <p className="mt-1 text-sm opacity-90">{t.description}</p>}
          </div>
          <button onClick={() => dismiss(t.id)} className="opacity-70 hover:opacity-100">
            <X className="h-4 w-4" />
          </button>
        </div>
      ))}
    </div>
  );
}
