import { useSession } from "@/lib/auth/session";

/** The current user's id, used as the actor on every mutation. */
export function useActorId(): string {
  const user = useSession((s) => s.user);
  return user?.id ?? "system";
}
