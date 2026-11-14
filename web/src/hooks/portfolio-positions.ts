"use client";

import { useQueries, useQuery } from "@tanstack/react-query";
import { getJSON } from "@/lib/api";
import { toView } from "@/lib/instrument-view";
import type { QuoteResponse } from "@/lib/market-types";
import { portfolioInstrument } from "@/lib/portfolio-exposure";
import { browserSupabase } from "@/lib/supabase/client";
import type { PortfolioHolding } from "@/lib/portfolio-holdings";

type HoldingRow = Omit<PortfolioHolding, "instrument">;

async function readPortfolio(userId: string, signal: AbortSignal) {
  const db = browserSupabase();
  if (!db) throw new Error("Accounts are unavailable.");
  const holdings = await db.from("portfolio_holdings").select("id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,broker_account")
    .eq("user_id", userId).is("deleted_at", null).gt("shares", 0).order("asset_symbol").order("id").limit(201).abortSignal(signal);
  if (holdings.error) throw new Error("Couldn’t load your synced portfolio.");
  return {
    holdings: (holdings.data as HoldingRow[]).slice(0, 200).map((row) => {
      const listing = portfolioInstrument({
        symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange,
      });
      return { ...row, instrument: listing ? toView(listing) : null };
    }),
    truncated: holdings.data.length > 200,
  };
}

export function usePortfolioPositions(userId?: string) {
  const portfolio = useQuery({
    queryKey: ["portfolio", userId],
    enabled: Boolean(userId),
    queryFn: ({ signal }) => readPortfolio(userId!, signal),
    staleTime: 30_000,
  });
  const holdings = portfolio.data?.holdings ?? [];
  const pricedListings = holdings.flatMap((holding) => holding.instrument ? [{ ...holding, instrument: holding.instrument }] : []);
  const ids = [...new Set(pricedListings.map((holding) => holding.instrument.id))];
  const prices = useQueries({
    queries: ids.map((id) => ({
      queryKey: ["quote", id],
      queryFn: ({ signal }: { signal: AbortSignal }) =>
        getJSON<QuoteResponse>(`/api/markets/instruments/${encodeURIComponent(id)}/quote`, signal),
      staleTime: 10_000,
      refetchInterval: 60_000,
    })),
  });
  const quotes = new Map(ids.map((id, index) => [id, prices[index]]));
  const pendingQuotes = new Set(ids.filter((_, index) => prices[index].isPending));
  return { portfolio, holdings, pricedListings, quotes, pendingQuotes, loadingPrices: pendingQuotes.size > 0 };
}
