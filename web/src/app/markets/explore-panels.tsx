"use client";

import { useQuery } from "@tanstack/react-query";
import { ArrowUpRight, Bookmark } from "lucide-react";
import Link from "next/link";
import { useState } from "react";
import { catalogInstruments } from "@engine/catalog.ts";
import { instrumentID } from "@engine/market.ts";
import type { MarketExplore, MarketMover } from "../../../../supabase/functions/market-workspace/explore.ts";
import { ChangePill } from "@/components/market/Change";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Segmented } from "@/components/ui/Segmented";
import { useAccountWatchlists } from "@/hooks/watchlist";
import { getJSON } from "@/lib/api";
import { dateTime, money } from "@/lib/format";
import { toView } from "@/lib/instrument-view";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

const supported = new Map(catalogInstruments.map(instrument => [instrumentID(instrument), instrument]));

function MoverRow({ row }: { row: MarketMover }) {
  const item = toView(row.instrument);
  return (
    <li>
      <Link href={`/markets/${encodeURIComponent(item.id)}`} className="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-surface-2">
        <span className="min-w-0">
          <span className="block truncate text-sm font-semibold">{item.symbol}</span>
          <span className="block truncate text-xs text-text-3">{item.name}</span>
        </span>
        <span className="flex shrink-0 items-center gap-2 tabular text-sm sm:gap-3">
          {money(row.price, item.currency)}
          <ChangePill changePct={row.changePct} />
        </span>
      </Link>
    </li>
  );
}

export function MarketRankings() {
  const [market, setMarket] = useState<"us" | "asx">("us");
  const [side, setSide] = useState<"gainers" | "losers">("gainers");
  const query = useQuery({
    queryKey: ["market-explore"],
    queryFn: ({ signal }) => getJSON<MarketExplore>("/api/markets/explore", signal),
    staleTime: 60_000,
    refetchInterval: 120_000,
    retry: false,
  });
  const movers = query.data?.[market];
  const trending = query.data?.trending;
  const refresh = <Button size="sm" onClick={() => query.refetch()} disabled={query.isFetching}>Try again</Button>;

  return (
    <div className="grid grid-cols-1 items-start gap-5 lg:grid-cols-2">
      <Card className="min-w-0">
        <CardHeader title="Biggest movers" className="flex-wrap" actions={
          <Segmented label="Movers market" value={market} onChange={setMarket} options={[{ value: "us", label: "US" }, { value: "asx", label: "ASX" }]} />
        } />
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 pb-3">
          <Segmented label="Direction" value={side} onChange={setSide} options={[{ value: "gainers", label: "Gainers" }, { value: "losers", label: "Losers" }]} />
          {movers ? <span className="text-xs text-text-3">{movers.scope}</span> : null}
        </div>
        {query.isPending ? <div className="skeleton m-4 h-32" />
          : !movers ? <EmptyState title="Movers unavailable" body="There isn’t enough recent data for this ranking." actions={refresh} />
          : movers[side].length ? <ul className="divide-y divide-border border-t border-border">{movers[side].map(row => <MoverRow key={toView(row.instrument).id} row={row} />)}</ul>
          : <EmptyState title={side === "gainers" ? "No gainers in this group" : "No losers in this group"} />}
        {movers ? <p className="border-t border-border px-4 py-3 text-xs text-text-3">{movers.source} · <time dateTime={movers.observedAt}>{dateTime(movers.observedAt)}</time></p> : null}
      </Card>
      <Card className="min-w-0">
        <CardHeader title="Trending crypto" subtitle="Supported coins trending in CoinGecko searches over 24 hours" />
        {query.isPending ? <div className="skeleton m-4 h-32" />
          : !trending ? <EmptyState title="Crypto trends unavailable" actions={refresh} />
          : trending.instruments.length ? <ul className="divide-y divide-border border-t border-border">{trending.instruments.map(instrument => <InstrumentRow key={toView(instrument).id} instrument={toView(instrument)} spark={false} />)}</ul>
          : <EmptyState title="No supported coins in the current ranking" />}
        {trending ? <p className="border-t border-border px-4 py-3 text-xs text-text-3">CoinGecko · checked <time dateTime={trending.checkedAt}>{dateTime(trending.checkedAt)}</time></p> : null}
      </Card>
    </div>
  );
}

export function ExploreWatchlists() {
  const session = useSession();
  const id = session.status === "signedIn" ? session.user.id : undefined;
  const lists = useAccountWatchlists(id);
  const watched = useQuery({
    queryKey: ["most-watched", id],
    enabled: Boolean(id),
    staleTime: 5 * 60_000,
    retry: false,
    queryFn: async () => {
      const client = browserSupabase();
      if (!client || !id) return [];
      const { data, error } = await client.rpc("most_watched_listings", { p_user_id: id });
      if (error) return [];
      return (data as string[]).flatMap((key) => {
        const instrument = supported.get(key);
        return instrument ? [toView(instrument)] : [];
      }).slice(0, 5);
    },
  });
  if (!id || (!lists.data?.length && !watched.data?.length)) return null;
  const saved = (lists.data ?? []).flatMap((list) => list.assets.flatMap((item) => item.savedAt ? [{ item, time: Date.parse(item.savedAt) }] : []));
  saved.sort((a, b) => b.time - a.time);
  const seen = new Set<string>();
  const recent = saved.filter(({ item }) => {
    if (seen.has(item.instrument.id)) return false;
    seen.add(item.instrument.id);
    return true;
  }).slice(0, 4);
  return (
    <div className="grid grid-cols-1 items-start gap-5 lg:grid-cols-2">
      {lists.data?.length ? <Card>
        <CardHeader title="Your watchlists" />
        <ul className="divide-y divide-border border-t border-border">
          {lists.data.map(list => <li key={list.id}>
            <Link href={`/watchlists?list=${list.id}`} className="flex items-center gap-3 px-4 py-2.5 hover:bg-surface-2">
              <Bookmark aria-hidden className="h-4 w-4 shrink-0 text-text-3" />
              <span className="min-w-0 flex-1 break-words text-sm font-medium">{list.name}</span>
              <Badge>{list.assets.length}</Badge><ArrowUpRight aria-hidden className="h-3.5 w-3.5 shrink-0 text-text-3" />
            </Link>
          </li>)}
        </ul>
      </Card> : null}
      {recent.length ? <Card>
        <CardHeader title="Recently added" subtitle="From your watchlists" />
        <ul className="divide-y divide-border border-t border-border">
          {recent.map(({ item }) => <InstrumentRow key={item.instrument.id} instrument={item.instrument} spark={false} />)}
        </ul>
      </Card> : null}
      {watched.data?.length ? <Card>
        <CardHeader title="Most watched" subtitle="Ranked by distinct Stock Tracker accounts" />
        <ul className="divide-y divide-border border-t border-border">
          {watched.data.map(item => <InstrumentRow key={item.id} instrument={item} spark={false} />)}
        </ul>
      </Card> : null}
    </div>
  );
}
