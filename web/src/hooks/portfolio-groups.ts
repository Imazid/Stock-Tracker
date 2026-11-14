"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { browserSupabase } from "@/lib/supabase/client";

export const mainPortfolioId = "00000000-0000-0000-0000-000000000002";

type PortfolioGroup = { id: string; name: string; emoji: string };
type GroupChange = { action: "create" | "rename" | "delete"; id: string; name?: string };

export function usePortfolioGroups(userId?: string) {
  const client = useQueryClient();
  const key = ["portfolio-groups", userId];
  const groups = useQuery({
    queryKey: key,
    enabled: Boolean(userId),
    queryFn: async ({ signal }) => {
      const db = browserSupabase();
      if (!db || !userId) return [];
      const result = await db.from("portfolio_groups").select("id,name,emoji")
        .eq("user_id", userId).is("deleted_at", null).order("name").abortSignal(signal);
      if (result.error) throw new Error("Couldn’t load your portfolios.");
      const rows = result.data as PortfolioGroup[];
      const main = rows.find(row => row.id === mainPortfolioId) ?? { id: mainPortfolioId, name: "Main Portfolio", emoji: "💼" };
      return [main, ...rows.filter(row => row.id !== mainPortfolioId)];
    },
  });
  const change = useMutation({
    mutationFn: async (change: GroupChange) => {
      const db = browserSupabase();
      if (!db || !userId) throw new Error("Sign in to manage portfolios.");
      const result = await db.rpc("apply_portfolio_group_change", {
        p_user_id: userId, p_id: crypto.randomUUID(), p_group_id: change.id,
        p_action: change.action, p_name: change.name, p_emoji: "💼",
      });
      if (result.error) throw new Error(result.error.message);
    },
    onSettled: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: key }),
        client.invalidateQueries({ queryKey: ["portfolio", userId] }),
        client.invalidateQueries({ queryKey: ["portfolio-history", userId] }),
      ]);
    },
  });
  return { groups, change };
}
