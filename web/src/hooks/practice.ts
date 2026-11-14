"use client";

import { useQuery } from "@tanstack/react-query";
import type { TradingState } from "@engine/state.ts";
import { useSession } from "@/lib/session";

export class PracticeError extends Error {
  constructor(message: string, readonly code?: string) { super(message); }
}

export async function practiceCall<T>(action: string, fields: Record<string, unknown> = {}, key?: string, owner?: string): Promise<T> {
  const response = await fetch("/api/practice", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(key ? { "Idempotency-Key": key } : {}), ...(owner ? { "X-Stock-Tracker-Account": owner } : {}) },
    body: JSON.stringify({ action, ...fields }),
  });
  const reply = await response.json();
  if (!response.ok || reply.ok !== true) throw new PracticeError(reply.error?.message ?? "Practice trading is unavailable.", reply.error?.code);
  return reply.data as T;
}

export function usePractice() {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const query = useQuery({
    queryKey: ["practice", userId],
    enabled: Boolean(userId),
    queryFn: async () => (await practiceCall<{ state: TradingState }>("state")).state,
    refetchInterval: 30_000,
  });
  return { session, query };
}
