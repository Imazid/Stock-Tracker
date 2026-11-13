"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { ArrowRight, CheckCircle2, CircleDashed, ListChecks } from "lucide-react";
import { InstrumentRow } from "@/components/market/InstrumentRow";
import { ChangeText } from "@/components/market/Change";
import { StatusChip } from "@/components/market/DataChips";
import { Badge } from "@/components/ui/Badge";
import { ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { useQuote } from "@/hooks/market";
import { useWatchlist } from "@/hooks/watchlist";
import { getJSON } from "@/lib/api";
import { ago, money } from "@/lib/format";
import { useSession } from "@/lib/session";

// ETFs and majors as market proxies — labelled as such, never passed off as index levels.
const PULSE = [
  { id: "us:SPY", label: "S&P 500 ETF" },
  { id: "us:QQQ", label: "Nasdaq-100 ETF" },
  { id: "asx:BHP", label: "BHP (ASX)" },
  { id: "asx:CBA", label: "CBA (ASX)" },
  { id: "crypto:BTC", label: "Bitcoin" },
  { id: "crypto:ETH", label: "Ethereum" },
];

function PulseCard({ id, label }: { id: string; label: string }) {
  const { data, isLoading, isError } = useQuote(id);
  const q = data?.quote;
  return (
    <Link href={`/markets/${encodeURIComponent(id)}`} className="block rounded-xl border border-border bg-surface p-3.5 transition-colors hover:border-border-strong">
      <div className="flex items-center justify-between gap-2">
        <span className="truncate text-xs font-medium text-text-2">{label}</span>
        {q ? <StatusChip status={q.status} delayMinutes={q.delayMinutes} /> : null}
      </div>
      {isLoading ? <div className="mt-2 space-y-1.5"><div className="skeleton h-5 w-24" /><div className="skeleton h-3.5 w-16" /></div>
        : isError || !q ? <p className="mt-2 text-sm text-text-3">No live price</p> : (
          <>
            <p className="tabular mt-1.5 text-lg font-semibold text-text">{money(q.last, q.currency)}</p>
            <div className="flex items-center justify-between gap-2 text-xs">
              <ChangeText changePct={q.changePct} />
              <span className="text-text-3">{q.stale ? <Badge tone="warn">Stale</Badge> : ago(q.observedAt)}</span>
            </div>
          </>
        )}
    </Link>
  );
}

interface Status { accounts: boolean; alpacaData: boolean; coingeckoKey: boolean; assistant: boolean; liveTrading: boolean }

function SetupCard() {
  const { data } = useQuery({ queryKey: ["status"], queryFn: () => getJSON<Status>("/api/status"), staleTime: 300_000 });
  const rows: { ok: boolean | undefined; label: string; detail: string }[] = [
    { ok: data?.accounts, label: "Accounts & watchlists", detail: data?.accounts ? "Supabase is configured." : "Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY." },
    { ok: true, label: "Market data", detail: data?.alpacaData ? "Yahoo, CoinGecko and Alpaca (IEX) data." : "Yahoo and CoinGecko. Add ALPACA_DATA_KEY_ID / ALPACA_DATA_SECRET for real-time IEX quotes." },
    { ok: data?.coingeckoKey, label: "CoinGecko key", detail: data?.coingeckoKey ? "Demo key set." : "Optional: without COINGECKO_API_KEY crypto prices throttle after a few calls a minute." },
    { ok: false, label: "Live trading", detail: "Off in this build. Orders can only go to a provider's paper environment, after approval and risk checks." },
  ];
  return (
    <Card>
      <CardHeader title="Setup" subtitle="What this deployment can do right now" />
      <ul className="divide-y divide-border border-t border-border">
        {rows.map((r) => (
          <li key={r.label} className="flex gap-3 px-4 py-3">
            {r.ok ? <CheckCircle2 aria-label="Ready" className="mt-0.5 h-4 w-4 shrink-0 text-up" /> : <CircleDashed aria-label="Not set up" className="mt-0.5 h-4 w-4 shrink-0 text-text-3" />}
            <div className="min-w-0"><p className="text-[13px] font-medium text-text">{r.label}</p><p className="text-xs text-text-3">{r.detail}</p></div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function WatchlistCard() {
  const session = useSession();
  const list = useWatchlist();
  let body;
  if (session.status === "unconfigured") body = <EmptyState title="Accounts aren't configured" body="Watchlists are saved to your account, which this deployment doesn't have set up." />;
  else if (session.status === "loading" || (session.status === "signedIn" && list.isLoading)) body = <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <div key={i} className="skeleton h-10" />)}</div>;
  else if (session.status === "signedOut") body = <EmptyState icon={<ListChecks className="h-5 w-5" />} title="Sign in to see your watchlist" body="It's the same list as the Stock Tracker iPhone app." actions={<ButtonLink href="/login" variant="primary" size="sm">Sign in</ButtonLink>} />;
  else if (list.isError) body = <EmptyState tone="down" title="Couldn't load your watchlist" body={(list.error as Error).message} />;
  else if (!list.data || list.data.length === 0) body = <EmptyState icon={<ListChecks className="h-5 w-5" />} title="Your watchlist is empty" body="Add stocks, ETFs and crypto from Markets." actions={<ButtonLink href="/markets" size="sm">Browse markets</ButtonLink>} />;
  else body = <ul className="divide-y divide-border border-t border-border">{list.data.slice(0, 8).map((w) => <InstrumentRow key={w.rowId} instrument={w.instrument} />)}</ul>;
  return (
    <Card>
      <CardHeader title="Watchlist" actions={<Link href="/watchlists" className="inline-flex items-center gap-1 text-xs text-text-2 hover:text-text">Open <ArrowRight aria-hidden className="h-3 w-3" /></Link>} />
      {body}
    </Card>
  );
}

export function OverviewView() {
  return (
    <div className="mx-auto max-w-6xl">
      <PageHeader title="Overview" description="Markets at a glance, your watchlist, and what this deployment has switched on." />
      <section aria-label="Market pulse" className="mb-5">
        <div className="mb-2 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-text">Market pulse</h2>
          <span className="text-xs text-text-3">ETFs and blue chips as proxies, not index levels</span>
        </div>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">{PULSE.map((p) => <PulseCard key={p.id} {...p} />)}</div>
      </section>
      <div className="grid gap-5 lg:grid-cols-[1fr_360px]">
        <WatchlistCard />
        <SetupCard />
      </div>
    </div>
  );
}
