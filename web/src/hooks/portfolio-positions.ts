"use client";

import { useQueries, useQuery } from "@tanstack/react-query";
import { mainPortfolioId } from "@/hooks/portfolio-groups";
import { getJSON } from "@/lib/api";
import { toView } from "@/lib/instrument-view";
import type { InstrumentView, QuoteResponse } from "@/lib/market-types";
import { portfolioInstrument } from "@/lib/portfolio-exposure";
import { browserSupabase } from "@/lib/supabase/client";
import type { PortfolioHolding } from "@/lib/portfolio-holdings";

type HoldingRow = Omit<PortfolioHolding, "instrument">;
const holdingFields = "id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,broker_account,updated_at";

function portfolioListing(row: HoldingRow) {
  const listing = portfolioInstrument({
    symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange,
  });
  return listing ? toView(listing) : null;
}

async function readPortfolio(userId: string, signal: AbortSignal, groupId?: string) {
  const db = browserSupabase();
  if (!db) throw new Error("Accounts are unavailable.");
  let query = db.from("portfolio_holdings").select(holdingFields)
    .eq("user_id", userId).is("deleted_at", null).gt("shares", 0);
  if (groupId === mainPortfolioId) query = query.is("portfolio_group_id", null);
  else if (groupId) query = query.eq("portfolio_group_id", groupId);
  const holdings = await query.order("asset_symbol").order("id").limit(201).abortSignal(signal);
  if (holdings.error) throw new Error("Couldn’t load your synced portfolio.");
  return {
    holdings: (holdings.data as HoldingRow[]).slice(0, 200).map((row) => ({ ...row, instrument: portfolioListing(row) })),
    truncated: holdings.data.length > 200,
  };
}

export function usePortfolioPositions(userId?: string, groupId?: string) {
  const portfolio = useQuery({
    queryKey: ["portfolio", userId, groupId],
    enabled: Boolean(userId),
    queryFn: ({ signal }) => readPortfolio(userId!, signal, groupId),
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


export function useListingPositions(userId: string, instrument: InstrumentView) {
  return useQuery({
    queryKey: ["portfolio", userId, "listing", instrument.id],
    queryFn: async ({ signal }) => {
      const db = browserSupabase();
      if (!db || !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(instrument.symbol)) throw new Error("Positions are unavailable.");
      const matching: (PortfolioHolding & { portfolio_group_id: string | null })[] = [];
      const pageSize = 200;
      let cursor: string | undefined;
      do {
        // Synced rows can have case, spacing and suffix differences. Resolve the
        // listing after the server-side ticker search, including its venue.
        let query = db.from("portfolio_holdings").select(`${holdingFields},portfolio_group_id`)
          .eq("user_id", userId).eq("asset_kind", instrument.venue === "crypto" ? "Crypto" : "Stock")
          .is("deleted_at", null).gt("shares", 0).ilike("asset_symbol", `%${instrument.symbol}%`)
          .order("id").limit(pageSize).abortSignal(signal);
        if (cursor) query = query.gt("id", cursor);
        const { data, error } = await query.overrideTypes<(HoldingRow & { portfolio_group_id: string | null })[], { merge: false }>();
        if (error) throw new Error("Couldn’t load your positions.");
        for (const row of data) {
          if (portfolioListing(row)?.id === instrument.id) matching.push({ ...row, instrument });
        }
        cursor = data.length === pageSize ? data[data.length - 1].id : undefined;
      } while (cursor);
      return matching;
    },
    staleTime: 30_000,
  });
}
