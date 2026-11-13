"use client";

import { MarketCalendar } from "@engine/calendar.ts";
import Link from "next/link";
import { ArrowLeft, Check, Plus, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { ChangeText } from "@/components/market/Change";
import { MarketChip, SourceLine, StatusChip } from "@/components/market/DataChips";
import { type ChartType, DEFAULT_INDICATORS, type IndicatorSet, PriceChart } from "@/components/market/PriceChart";
import { Badge } from "@/components/ui/Badge";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { Segmented } from "@/components/ui/Segmented";
import { useCandles, useInstrument, useQuote } from "@/hooks/market";
import { useOrderPath } from "@/hooks/oms";
import { useWatchlist, useWatchlistMutations } from "@/hooks/watchlist";
import { ApiError } from "@/lib/api";
import { cn } from "@/lib/cn";
import { compact, dateTime, money } from "@/lib/format";
import { CHART_RANGES, type ChartRange } from "@/lib/market-types";
import { pushRecent } from "@/lib/recent";
import { useSession } from "@/lib/session";

const INDICATOR_LABELS: { key: keyof IndicatorSet; label: string }[] = [
  { key: "volume", label: "Volume" }, { key: "sma20", label: "SMA 20" }, { key: "sma50", label: "SMA 50" }, { key: "ema20", label: "EMA 20" },
  { key: "bollinger", label: "Bollinger 20,2" }, { key: "rsi", label: "RSI 14" }, { key: "macd", label: "MACD 12,26,9" },
];

const SCOPE_LABEL = { consolidated: "Consolidated volume", single_venue: "One venue's volume only", aggregate: "Aggregate across exchanges", unknown: "Volume coverage unknown" } as const;

function WatchButton({ instrument }: { instrument: NonNullable<ReturnType<typeof useInstrument>["data"]>["instrument"] }) {
  const session = useSession();
  const list = useWatchlist();
  const { add, remove } = useWatchlistMutations();
  if (session.status !== "signedIn") return null;
  const row = list.data?.find((w) => w.instrument.id === instrument.id);
  const busy = add.isPending || remove.isPending || list.isLoading;
  return (
    <Button size="sm" variant={row ? "secondary" : "primary"} disabled={busy} aria-pressed={Boolean(row)}
      onClick={() => (row ? remove.mutate(row.rowId) : add.mutate(instrument))}>
      {row ? <><Check className="h-3.5 w-3.5" />On watchlist</> : <><Plus className="h-3.5 w-3.5" />Watch</>}
    </Button>
  );
}

function Stat({ label, value, hint, wide }: { label: string; value: string; hint?: string; wide?: boolean }) {
  return (
    <div className={cn("min-w-0", wide && "col-span-2")}>
      <dt className="text-[11px] text-text-3">{label}</dt>
      <dd className="tabular truncate text-sm font-medium text-text" title={hint}>{value}</dd>
    </div>
  );
}

export function InstrumentView({ id }: { id: string }) {
  const [range, setRange] = useState<ChartRange>("1D");
  const [type, setType] = useState<ChartType>("candles");
  const [indicators, setIndicators] = useState<IndicatorSet>(DEFAULT_INDICATORS);
  const info = useInstrument(id);
  const quote = useQuote(id, { refetchMs: 20_000 });
  const candles = useCandles(id, range);
  const orderPath = useOrderPath(info.data?.instrument);

  const instrument = info.data?.instrument ?? quote.data?.instrument;
  useEffect(() => {
    if (instrument) pushRecent({ id: instrument.id, symbol: instrument.symbol, name: instrument.name, venueShort: instrument.venueShort, assetClass: instrument.assetClass });
  }, [instrument]);

  const timeZone = useMemo(() => (instrument ? MarketCalendar.timeZone(instrument.venue) : undefined), [instrument]);
  const q = quote.data?.quote;
  const market = quote.data?.market ?? info.data?.market;
  const series = candles.data?.candles ?? [];

  if (info.isError) {
    const err = info.error;
    return (
      <div className="mx-auto max-w-3xl">
        <EmptyState tone="down" title={err instanceof ApiError && err.code === "invalid" ? "That isn't a valid instrument" : "Couldn't load this instrument"} body={(err as Error).message}
          actions={<ButtonLink href="/markets">Back to Markets</ButtonLink>} />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl">
      <Link href="/markets" className="mb-3 inline-flex items-center gap-1 text-xs text-text-2 hover:text-text"><ArrowLeft aria-hidden className="h-3.5 w-3.5" />Markets</Link>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          {instrument ? (
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold tracking-tight text-text">{instrument.symbol}</h1>
              <Badge>{instrument.venueShort}</Badge>
              {instrument.pair ? <Badge tone="primary">{instrument.pair}</Badge> : null}
              <span className="truncate text-sm text-text-2">{instrument.name}</span>
            </div>
          ) : <div className="skeleton h-7 w-48" />}
          <div className="mt-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
            {quote.isLoading ? <div className="skeleton h-8 w-40" /> : q ? (
              <>
                <span className="tabular text-3xl font-semibold tracking-tight text-text">{money(q.last, q.currency)}</span>
                <ChangeText change={q.change} changePct={q.changePct} currency={q.currency} className="text-sm font-medium" />
              </>
            ) : <span className="text-sm text-text-3">No live price right now</span>}
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            {q ? <StatusChip status={q.status} delayMinutes={q.delayMinutes} /> : null}
            {market ? <MarketChip market={market} /> : null}
          </div>
          {q ? <div className="mt-1.5"><SourceLine source={q.source} currency={q.currency} observedAt={q.observedAt} stale={q.stale} staleReason={q.staleReason} /></div> : null}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {instrument ? <WatchButton instrument={instrument} /> : null}
          {instrument && orderPath.available ? (
            <>
              <ButtonLink href={`/orders/new?instrument=${encodeURIComponent(instrument.id)}&side=buy`} variant="buy" size="sm">Buy</ButtonLink>
              <ButtonLink href={`/orders/new?instrument=${encodeURIComponent(instrument.id)}&side=sell`} variant="sell" size="sm">Sell</ButtonLink>
            </>
          ) : null}
        </div>
      </div>

      {quote.isError ? (
        <Notice tone="warn" className="mb-4" title="Price unavailable">
          {(quote.error as Error).message}
          {quote.error instanceof ApiError && Array.isArray(quote.error.details?.reasons) ? <ul className="mt-1 list-disc pl-4 text-xs">{(quote.error.details!.reasons as string[]).map((r) => <li key={r}>{r}</li>)}</ul> : null}
        </Notice>
      ) : null}
      {q?.stale ? <Notice tone="warn" className="mb-4" title="This price is stale">{q.staleReason}. It&apos;s shown for reference, not as the current price.</Notice> : null}

      <div className="grid gap-5 lg:grid-cols-[1fr_280px]">
        <Card className="min-w-0">
          <div className="flex flex-wrap items-center justify-between gap-2 px-4 pt-4">
            <Segmented label="Range" value={range} onChange={setRange} options={CHART_RANGES.map((r) => ({ value: r, label: r }))} />
            <div className="flex items-center gap-2">
              <Segmented label="Chart type" value={type} onChange={setType} options={[{ value: "candles", label: "Candles" }, { value: "line", label: "Line" }, { value: "area", label: "Area" }]} />
              <Button size="sm" variant="ghost" aria-label="Refresh chart" onClick={() => candles.refetch()} disabled={candles.isFetching}>
                <RefreshCw className={cn("h-3.5 w-3.5", candles.isFetching && "animate-spin")} />
              </Button>
            </div>
          </div>
          <div className="flex flex-wrap gap-1.5 px-4 pt-3" role="group" aria-label="Indicators">
            {INDICATOR_LABELS.map(({ key, label }) => (
              <button key={key} type="button" aria-pressed={indicators[key]} onClick={() => setIndicators((s) => ({ ...s, [key]: !s[key] }))}
                className={cn("rounded-md border px-2 py-1 text-[11px] font-medium transition-colors",
                  indicators[key] ? "border-primary/50 bg-primary-soft text-text" : "border-border text-text-2 hover:text-text")}>{label}</button>
            ))}
          </div>
          <div className="px-2 pb-2 pt-3">
            {candles.isLoading ? <div className="skeleton mx-2 h-[420px]" />
              : candles.isError ? (
                <EmptyState tone="down" title="Chart unavailable" body={(candles.error as Error).message}
                  actions={<Button size="sm" onClick={() => candles.refetch()}>Try again</Button>} />
              ) : series.length === 0 ? <EmptyState title="No bars for this range" />
                : (
                  <PriceChart candles={series} type={type} indicators={indicators} timeZone={timeZone} intraday={candles.data!.intraday}
                    baseline={range === "1D" && instrument?.venue !== "crypto" ? q?.previousClose : undefined}
                    ariaLabel={`${instrument?.symbol ?? ""} ${range} price chart`} />
                )}
          </div>
          {candles.data ? (
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-t border-border px-4 py-2.5 text-[11px] text-text-3">
              <span>{candles.data.source}</span>
              <span>{candles.data.interval} bars</span>
              <span>{candles.data.currency}</span>
              <span>{candles.data.adjustment}</span>
              <span>{SCOPE_LABEL[candles.data.volumeScope]}</span>
              {candles.data.observedAt ? <span>Last bar {dateTime(candles.data.observedAt)}</span> : null}
              <span>Times in {timeZone === "UTC" ? "UTC" : `exchange time (${timeZone})`}</span>
              {candles.data.notes.map((n) => <span key={n} className="text-warn">{n}</span>)}
            </div>
          ) : null}
        </Card>

        <div className="flex flex-col gap-5">
          <Card>
            <CardHeader title="Key numbers" subtitle={q ? `From ${q.source}` : undefined} />
            {q ? (
              <dl className="grid grid-cols-2 gap-x-4 gap-y-3 border-t border-border px-4 py-3">
                <Stat label={instrument?.venue === "crypto" ? "24h ago" : "Previous close"} value={money(q.previousClose, q.currency)} />
                <Stat label="Volume" value={compact(q.volume)} hint={SCOPE_LABEL[q.volumeScope]} />
                <Stat wide label="Day range" value={q.dayLow !== undefined && q.dayHigh !== undefined ? `${money(q.dayLow, q.currency)} – ${money(q.dayHigh, q.currency)}` : "—"} />
                <Stat label="Bid" value={money(q.bid, q.currency)} />
                <Stat label="Ask" value={money(q.ask, q.currency)} />
                <Stat wide label="Observed" value={dateTime(q.observedAt)} />
              </dl>
            ) : <div className="space-y-2 border-t border-border p-4">{[0, 1, 2].map((i) => <div key={i} className="skeleton h-8" />)}</div>}
            {q && q.notes.length > 0 ? <ul className="space-y-1 border-t border-border px-4 py-3 text-[11px] text-text-3">{q.notes.map((n) => <li key={n}>{n}</li>)}</ul> : null}
          </Card>
          <Card>
            <CardHeader title="Data sources" subtitle="Tried in this order" />
            {info.data ? (
              <div className="space-y-2 border-t border-border px-4 py-3 text-xs text-text-2">
                <p><span className="text-text-3">Quotes:</span> {info.data.sources.quotes.join(" → ")}</p>
                <p><span className="text-text-3">Charts:</span> {info.data.sources.candles.join(" → ")}</p>
                <p className="text-text-3">Prices are never filled in or estimated. If every source fails, you see that instead.</p>
              </div>
            ) : <div className="skeleton m-4 h-16" />}
          </Card>
          {instrument && !orderPath.available ? (
            <p className="px-1 text-[11px] leading-relaxed text-text-3">
              No Buy/Sell here: {orderPath.loading ? "checking order routing…" : "there's no connected account that can trade this in a practice environment. See Connections."}
            </p>
          ) : null}
        </div>
      </div>
    </div>
  );
}
