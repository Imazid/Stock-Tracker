"use client";

// The watchlist lives in Supabase `watchlist_assets` — the same table the iPhone app syncs —
// protected by row-level security (a user only ever sees their own rows). Removal is a soft
// delete (`deleted_at`), matching the app's sync model, so a phone that's offline doesn't
// resurrect a removed symbol.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { makeInstrument, venueShortName, yahooSymbol } from "@engine/market.ts";
import { rowToInstrument, toView } from "@/lib/instrument-view";
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
      if (!supabase || !userId) return [];
      const { data, error } = await supabase.from("watchlist_assets").select("id,symbol,name,kind,exchange,updated_at").eq("user_id", userId).is("deleted_at", null).order("updated_at", { ascending: true });
      if (error) throw new Error(error.message);
      return (data as Row[]).map((row) => ({ rowId: row.id, instrument: toView(rowToInstrument(row)), addedAt: row.updated_at }));
    },
  });
}

export function useWatchlistMutations() {
  const client = useQueryClient();
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const invalidate = () => Promise.all([
    client.invalidateQueries({ queryKey: ["watchlist", userId] }),
    client.invalidateQueries({ queryKey: accountWatchlistsKey(userId) }),
  ]);
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
      const { error } = await supabase.from("watchlist_assets").update({ deleted_at: new Date().toISOString() }).eq("id", rowId).eq("user_id", userId);
      if (error) throw new Error(error.message);
    },
    onSettled: invalidate,
  });
  return { add, remove };
}

export const defaultWatchlistId = "00000000-0000-0000-0000-000000000001";

interface AccountWatchItem extends WatchItem {
  key: string;
  savedAt?: string;
}

interface AccountWatchlist {
  id: string;
  name: string;
  assets: AccountWatchItem[];
}

type AccountWatchlistRow = {
  id: string;
  name: string;
  assets: (Omit<Row, "updated_at"> & { listing_id: string; added_at: string; saved_at?: string | null })[];
};

type WatchlistChange =
  | { action: "create" | "rename"; groupId: string; name: string }
  | { action: "delete"; groupId: string }
  | { action: "add"; groupId: string; instrument: InstrumentView }
  | { action: "remove"; groupId: string; key: string };

const accountWatchlistsKey = (userId: string | undefined) => ["accountWatchlists", userId];

export function useAccountWatchlists(userId: string | undefined) {
  return useQuery({
    queryKey: accountWatchlistsKey(userId),
    enabled: Boolean(userId),
    queryFn: async (): Promise<AccountWatchlist[]> => {
      const supabase = browserSupabase();
      if (!supabase) throw new Error("Accounts aren't configured.");
      const { data, error } = await supabase.rpc("get_watchlists", { p_user_id: userId });
      if (error) throw new Error(error.message);
      return (data as AccountWatchlistRow[]).map((list) => ({
        id: list.id,
        name: list.name,
        assets: list.assets.map((row) => ({
          key: row.listing_id,
          rowId: row.id,
          instrument: toView(rowToInstrument(row)),
          addedAt: row.added_at,
          savedAt: row.saved_at ?? undefined,
        })),
      }));
    },
  });
}

export function useAccountWatchlistChange(userId: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (change: WatchlistChange) => {
      const supabase = browserSupabase();
      if (!supabase) throw new Error("Accounts aren't configured.");
      const { error } = await supabase.rpc("apply_watchlist_change", {
        p_user_id: userId,
        p_id: crypto.randomUUID(),
        p_group_id: change.groupId,
        p_action: change.action,
        p_name: "name" in change ? change.name : undefined,
        p_assets: change.action === "add" ? [{ listing_id: change.instrument.id, ...instrumentToRow(change.instrument) }] : [],
        p_keys: change.action === "remove" ? [change.key] : [],
      });
      if (error) throw new Error(error.message);
    },
    onSettled: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: accountWatchlistsKey(userId) }),
        client.invalidateQueries({ queryKey: ["watchlist", userId] }),
      ]);
    },
  });
}
