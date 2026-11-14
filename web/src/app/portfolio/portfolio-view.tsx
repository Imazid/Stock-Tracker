"use client";

import Link from "next/link";
import { useQueries, useQuery } from "@tanstack/react-query";
import { Wallet } from "lucide-react";
import { SourceLine, StatusChip } from "@/components/market/DataChips";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageHeader } from "@/components/ui/PageHeader";
import { getJSON } from "@/lib/api";
import { money, plainNumber } from "@/lib/format";
import { toView } from "@/lib/instrument-view";
import type { QuoteResponse } from "@/lib/market-types";
import type { HoldingBrokerAccount } from "@/lib/portfolio-transfers";
import { portfolioMovement } from "@/lib/portfolio-movement";
import { portfolioInstrument } from "@/lib/portfolio-exposure";
import { BrokerCash } from "./broker-cash";
import { ExposureCard } from "./exposure-card";
import { MovementCard } from "./movement-card";
import { LotReport } from "./lot-report";
import { IncomeLedger } from "./income-ledger";
import { PerformanceLedger } from "./performance-ledger";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";

interface HoldingRow {
  id: string;
  asset_symbol: string;
  asset_name: string;
  asset_kind: "Stock" | "Crypto";
  asset_exchange: string | null;
  broker_account: HoldingBrokerAccount | null;
  shares: number;
  avg_cost: number;
}

interface Snapshot {
  snapshot_date: string;
  total_value: number;
}

async function readPortfolio(userId: string) {
  const db = browserSupabase();
  if (!db) throw new Error("Accounts are unavailable.");
  const [holdings, snapshots] = await Promise.all([
    db.from("portfolio_holdings").select("id,asset_symbol,asset_name,asset_kind,asset_exchange,shares,avg_cost,broker_account")
      .eq("user_id", userId).is("deleted_at", null).gt("shares", 0).order("asset_symbol").order("id").limit(201),
    db.from("portfolio_snapshots").select("snapshot_date,total_value").eq("user_id", userId)
      .order("snapshot_date", { ascending: false }).limit(30),
  ]);
  if (holdings.error || snapshots.error) throw new Error("Couldn’t load your synced portfolio.");
  return {
    holdings: (holdings.data as HoldingRow[]).slice(0, 200).map((row) => {
      const listing = portfolioInstrument({
        symbol: row.asset_symbol, name: row.asset_name, kind: row.asset_kind, exchange: row.asset_exchange,
      });
      return { ...row, instrument: listing ? toView(listing) : null };
    }),
    truncated: holdings.data.length > 200,
    snapshots: snapshots.data as Snapshot[],
  };
}

export function PortfolioView() {
  const session = useSession();
  const userId = session.status === "signedIn" ? session.user.id : undefined;
  const portfolio = useQuery({
    queryKey: ["portfolio", userId],
    enabled: Boolean(userId),
    queryFn: () => readPortfolio(userId!),
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
  const snapshots = portfolio.data?.snapshots ?? [];
  const movement = portfolioMovement(pricedListings, (id) => quotes.get(id)?.data?.quote);

  return (
    <div className="mx-auto max-w-5xl space-y-5">
      <PageHeader title="Portfolio" description="Holdings and saved valuations synced from Stock Tracker on iPhone."
        actions={userId && <a className="text-sm text-primary-fg underline" href="/api/portfolio/transactions">Export transactions CSV</a>} />
      {session.status === "unconfigured" ? (
        <Card><EmptyState title="Accounts are unavailable" /></Card>
      ) : session.status === "signedOut" ? (
        <Card><EmptyState icon={<Wallet aria-hidden />} title="Sign in to view your portfolio"
          actions={<ButtonLink href="/login?next=/portfolio" variant="primary">Sign in</ButtonLink>} /></Card>
      ) : session.status === "loading" || portfolio.isPending ? (
        <div className="skeleton h-28" role="status" aria-label="Loading portfolio" />
      ) : portfolio.isError ? (
        <Card><EmptyState title="Couldn’t load your portfolio" tone="down"
          actions={<Button onClick={() => void portfolio.refetch()}>Retry</Button>} /></Card>
      ) : (
        <>
          {holdings.length > 0 && <MovementCard movement={movement} holdingCount={holdings.length} loading={prices.some((price) => price.isPending)} />}
          {holdings.length > 0 && <ExposureCard key={userId} holdings={holdings} quoteFor={(id) => quotes.get(id)?.data}
            loading={prices.some((price) => price.isPending)} truncated={portfolio.data?.truncated ?? false} />}
          {userId && <>
            <BrokerCash key={userId + "-cash"} userId={userId} />
            <PerformanceLedger key={userId} userId={userId} />
            <IncomeLedger key={userId + "-income"} userId={userId} />
            <LotReport key={userId + "-lots"} userId={userId} />
          </>}
          <Card>
            <CardHeader title="Holdings" subtitle="Position values use the trading currency. Average costs are recorded in USD." />
            {portfolio.data?.truncated && <p role="status" className="px-4 pb-3 text-xs text-warn">Showing the first 200 holdings.</p>}
            {holdings.length ? (
              <ul className="divide-y divide-border border-t border-border">
                {holdings.map((holding) => {
                  const instrument = holding.instrument;
                  const price = instrument ? quotes.get(instrument.id) : undefined;
                  const quote = price?.data?.quote;
                  const value = quote && quote.instrumentId === instrument?.id && quote.last > 0 ? quote.last * holding.shares : undefined;
                  return (
                    <li key={holding.id} className="grid gap-2 px-4 py-3 sm:grid-cols-[1fr_1fr_auto] sm:items-start">
                      <div className="min-w-0">
                        {instrument ? <Link href={`/markets/${encodeURIComponent(instrument.id)}`} className="font-semibold text-text hover:underline">
                          {instrument.symbol} <span className="text-xs font-normal text-text-3">{instrument.venueShort}</span>
                        </Link> : <p className="font-semibold">{holding.asset_symbol} <span className="text-xs font-normal text-text-3">{holding.asset_exchange}</span></p>}
                        <p className="truncate text-xs text-text-2">{holding.asset_name}</p>
                        {holding.broker_account && <p className="break-words text-xs text-text-3">
                          {holding.broker_account.label}
                          {holding.broker_account.tracking ? ` · As of ${new Date(holding.broker_account.observed_at).toLocaleDateString()}` : " · Kept manually"}
                        </p>}
                      </div>
                      <div className="tabular text-sm">
                        <p>{plainNumber(holding.shares, 8)} {holding.asset_kind === "Crypto" ? holding.asset_symbol : "shares"}</p>
                        <p className="text-xs text-text-3">Average cost {holding.avg_cost > 0 ? money(holding.avg_cost, "USD") : "unavailable"}</p>
                      </div>
                      <div className="min-w-0 sm:text-right">
                        {quote && value !== undefined ? (
                          <>
                            <div className="flex flex-wrap items-center gap-2 sm:justify-end">
                              <p className="tabular font-semibold">{money(value, quote.currency)}</p>
                              <StatusChip status={quote.status} delayMinutes={quote.delayMinutes} />
                            </div>
                            <div className="mt-1 flex sm:justify-end"><SourceLine {...quote} /></div>
                          </>
                        ) : <p className="text-sm text-text-3">{!instrument ? "Listing unavailable" : price?.isPending ? "Loading quote" : "Quote unavailable"}</p>}
                      </div>
                    </li>
                  );
                })}
              </ul>
            ) : <EmptyState title="Your portfolio has no open holdings" body="Add or sync holdings in the iPhone app using this account." />}
          </Card>
          <Card>
            <CardHeader title="Saved portfolio values" subtitle="The 30 most recent daily valuations recorded by the iPhone app, in USD." />
            {snapshots.length ? (
              <ul className="divide-y divide-border border-t border-border">
                {snapshots.map((snapshot) => (
                  <li key={snapshot.snapshot_date} className="flex items-center justify-between gap-4 px-4 py-2.5 text-sm">
                    <time dateTime={snapshot.snapshot_date}>{snapshot.snapshot_date}</time>
                    <span className="tabular">{money(snapshot.total_value, "USD")}</span>
                  </li>
                ))}
              </ul>
            ) : <EmptyState title="No saved valuations yet" />}
          </Card>
        </>
      )}
    </div>
  );
}
