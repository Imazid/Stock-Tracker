"use client";

// The watchlist lives in Supabase `watchlist_assets` — the same table the iPhone app syncs —
// protected by row-level security (a user only ever sees their own rows). Removal is a soft
// delete (`deleted_at`), matching the app's sync model, so a phone that's offline doesn't
// resurrect a removed symbol.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { type Instrument, makeInstrument, parseYahooSymbol, venueShortName, yahooSymbol } from "@engine/market.ts";
import { toView } from "@/lib/instrument-view";
import type { InstrumentView } from "@/lib/market-types";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

interface Row {
  id: string;
  symbol: string;
  name: string;
  kind: "Stock" | "Crypto";
  exchange: string | null;
  updated_at: string;
}

export interface WatchItem {
  rowId: string;
  instrument: InstrumentView;
  addedAt: string;
}

export function rowToInstrument(row: Pick<Row, "symbol" | "name" | "kind" | "exchange">): Instrument {
  const symbol = row.symbol.toUpperCase();
  if (row.kind === "Crypto") return makeInstrument(symbol, "crypto", "crypto", row.name);
  if ((row.exchange ?? "").toUpperCase() === "ASX" || symbol.endsWith(".AX")) return makeInstrument(symbol.replace(/\.AX$/, ""), "equity", "asx", row.name);
  const parsed = parseYahooSymbol(symbol);
  if (parsed) return makeInstrument(parsed.symbol, "equity", parsed.venue, row.name);
  return makeInstrument(symbol, "equity", "us", row.name);
}

/** The row shape the iPhone app reads back: bare US/ASX tickers, Yahoo-suffixed elsewhere. */
export function instrumentToRow(instrument: InstrumentView): Pick<Row, "symbol" | "name" | "kind" | "exchange"> {
  if (instrument.venue === "crypto") return { symbol: instrument.symbol, name: instrument.name, kind: "Crypto", exchange: null };
  if (instrument.venue === "us") return { symbol: instrument.symbol, name: instrument.name, kind: "Stock", exchange: "US" };
  if (instrument.venue === "asx") return { symbol: instrument.symbol, name: instrument.name, kind: "Stock", exchange: "ASX" };
  const inst = makeInstrument(instrument.symbol, instrument.assetClass, instrument.venue, instrument.name);
  return { symbol: yahooSymbol(inst), name: instrument.name, kind: "Stock", exchange: venueShortName(instrument.venue) };
}

export function useWatchlist() {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  return useQuery({
    queryKey: ["watchlist", userId],
    enabled: Boolean(userId),
    queryFn: async (): Promise<WatchItem[]> => {
      const supabase = browserSupabase();
      if (!supabase) return [];
      const { data, error } = await supabase.from("watchlist_assets").select("id,symbol,name,kind,exchange,updated_at").is("deleted_at", null).order("updated_at", { ascending: true });
      if (error) throw new Error(error.message);
      return (data as Row[]).map((row) => ({ rowId: row.id, instrument: toView(rowToInstrument(row)), addedAt: row.updated_at }));
    },
  });
}

export function useWatchlistMutations() {
  const client = useQueryClient();
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const invalidate = () => client.invalidateQueries({ queryKey: ["watchlist", userId] });
  const add = useMutation({
    mutationFn: async (instrument: InstrumentView) => {
      const supabase = browserSupabase();
      if (!supabase || !userId) throw new Error("Sign in to save a watchlist.");
      const { error } = await supabase.from("watchlist_assets").upsert({ user_id: userId, ...instrumentToRow(instrument), deleted_at: null }, { onConflict: "user_id,symbol" });
      if (error) throw new Error(error.message);
    },
    onSettled: invalidate,
  });
  const remove = useMutation({
    mutationFn: async (rowId: string) => {
      const supabase = browserSupabase();
      if (!supabase || !userId) throw new Error("Sign in to change your watchlist.");
      const { error } = await supabase.from("watchlist_assets").update({ deleted_at: new Date().toISOString() }).eq("id", rowId);
      if (error) throw new Error(error.message);
    },
    onSettled: invalidate,
  });
  return { add, remove };
}
