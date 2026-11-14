"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { browserSupabase } from "@/lib/supabase/client";

type OrdersQuery = "activity" | "intents" | "intent";

export function useOrderUpdates(userId: string | undefined, query: OrdersQuery, intentId?: string) {
  const cache = useQueryClient();
  useEffect(() => {
    const db = browserSupabase();
    if (!db || !userId) return;

    let timer: ReturnType<typeof setTimeout> | undefined;
    let active = true;
    const refresh = () => {
      if (!active || timer !== undefined) return;
      timer = setTimeout(() => {
        timer = undefined;
        const queryKey = intentId ? [query, userId, intentId] : [query, userId];
        void cache.invalidateQueries({ queryKey, exact: true });
      }, 200);
    };
    const filter = { schema: "public", table: "broker_order_updates", filter: `user_id=eq.${userId}` };
    const channel = db.channel(`broker-orders:${query}:${userId}:${intentId ?? "list"}:${crypto.randomUUID()}`)
      .on("postgres_changes", { ...filter, event: "INSERT" }, refresh)
      .on("postgres_changes", { ...filter, event: "UPDATE" }, refresh)
      .subscribe((status) => {
        if (status === "SUBSCRIBED") refresh();
      });

    return () => {
      active = false;
      clearTimeout(timer);
      void db.removeChannel(channel);
    };
  }, [cache, userId, query, intentId]);
}
