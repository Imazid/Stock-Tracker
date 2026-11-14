import { browserSupabase } from "@/lib/supabase/client";

export const backend = browserSupabase() ?? null;

export async function service<T>(
  endpoint: "market" | "trading" | "research" | "brokerage",
  body: Record<string, unknown>,
  idempotencyKey?: string,
  expectedUserId?: string,
): Promise<T> {
  const session = await backend?.auth.getSession();
  if (expectedUserId && session?.data.session?.user.id !== expectedUserId) throw new Error("The account changed while loading data.");
  const token = session?.data.session?.access_token;
  if (!token) throw new Error("Sign in to continue.");
  const response = await fetch(`/api/workspace-service/${endpoint}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body: JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok || result?.ok === false) {
    throw new Error(result?.error?.message ?? result?.message ?? "The service is temporarily unavailable.");
  }
  return (result?.ok === true && "data" in result ? result.data : result) as T;
}
