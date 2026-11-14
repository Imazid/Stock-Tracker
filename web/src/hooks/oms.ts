"use client";

import { useQuery } from "@tanstack/react-query";
import type { ConnectionView } from "@oms/api.ts";
import type { InstrumentView } from "@/lib/market-types";
import { Connections, OmsError } from "@/lib/oms-client";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

export function useConnections() {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  return useQuery({
    queryKey: ["connections", userId],
    queryFn: () => Connections.list(userId),
    enabled: Boolean(userId),
    retry: false,
    staleTime: 30_000,
  });
}

/** The asset class a provider uses for this listing, or undefined when no provider carries it. */
export function providerAssetClass(instrument: Pick<InstrumentView, "venue" | "assetClass">): "us_equity" | "crypto" | undefined {
  if (instrument.venue === "crypto") return "crypto";
  if (instrument.venue === "us") return "us_equity";
  return undefined;
}

/** Connections that can actually send an order for this instrument right now. */
export function tradableConnections(connections: ConnectionView[], instrument: Pick<InstrumentView, "venue" | "assetClass">): ConnectionView[] {
  const cls = providerAssetClass(instrument);
  if (!cls) return [];
  return connections.filter((c) => c.status === "active" && c.permissions.includes("trade") && c.capabilities.executionAvailable
    && c.environment !== "live" && c.capabilities.orders.some((o) => o.assetClass === cls));
}

/**
 * Whether Buy/Sell should appear for an instrument: only when order routing is deployed and a
 * connected account can trade this asset class in a non-live environment. Otherwise the
 * buttons are absent, not dead.
 */
export function useOrderPath(instrument: Pick<InstrumentView, "venue" | "assetClass"> | undefined) {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const connections = useConnections();
  const gate = useQuery({
    queryKey: ["provider-paper-gate", userId],
    enabled: Boolean(userId && instrument && providerAssetClass(instrument)),
    retry: false,
    staleTime: 30_000,
    queryFn: async () => {
      const supabase = browserSupabase()!;
      const { data, error } = await supabase.from("platform_gates").select("enabled,reason").eq("id", "provider_paper_execution").maybeSingle();
      if (error) throw error;
      return data;
    },
  });
  const deployed = !(connections.error instanceof OmsError && connections.error.code === "not_deployed");
  const usable = instrument && connections.data ? tradableConnections(connections.data.connections, instrument) : [];
  return {
    available: deployed && gate.data?.enabled === true && usable.length > 0,
    connections: usable,
    loading: connections.isLoading || gate.isLoading,
    unavailable: gate.isError ? "Paper trading availability could not be checked." :
      gate.data?.enabled === false ? "Alpaca paper execution is disabled on this deployment." : undefined,
  };
}
