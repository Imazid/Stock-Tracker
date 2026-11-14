import { useState } from "react";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { getJSON } from "@/lib/api";
import { dateTime, money, percent } from "@/lib/format";
import type { InstrumentView, QuoteResponse } from "@/lib/market-types";
import { portfolioExposure, type ExposureCurrency, type PortfolioReferenceRates } from "@/lib/portfolio-exposure";

const breakdowns = {
  assets: "Asset type", countries: "Listing country", currencies: "Quote currency", listings: "Largest positions",
} as const;

type Breakdown = keyof typeof breakdowns;
const breakdownKeys = Object.keys(breakdowns) as Breakdown[];

export function ExposureCard({ holdings, quoteFor, loading, truncated }: {
  holdings: readonly { shares: number; instrument: InstrumentView | null }[];
  quoteFor: (id: string) => QuoteResponse | undefined;
  loading: boolean;
  truncated: boolean;
}) {
  const [base, setBase] = useState<ExposureCurrency>("AUD");
  const [breakdown, setBreakdown] = useState<Breakdown>("assets");
  const needsRates = holdings.some(({ instrument }) => instrument !== null && instrument.currency !== base);
  const rates = useQuery({
    queryKey: ["portfolio-reference-rates"],
    queryFn: ({ signal }) => getJSON<PortfolioReferenceRates>("/api/portfolio/reference-rates", signal),
    enabled: needsRates,
    staleTime: 15 * 60_000,
    refetchInterval: 30 * 60_000,
  });
  const exposure = portfolioExposure(holdings, quoteFor, base, rates.data);
  const partial = truncated || exposure.priced < holdings.length;
  const waiting = loading || (needsRates && rates.isPending);
  const visible = breakdown === "listings" ? exposure.listings.slice(0, 5) : exposure[breakdown];
  const largest = exposure.listings[0];
  const topThree = exposure.listings.slice(0, 3).reduce((sum, item) => sum + item.weight, 0);

  return <Card>
    <CardHeader title="Portfolio exposure" subtitle="Weights use open holdings with usable quotes and exchange rates. Cash balances are excluded." />
    <div className="space-y-3 border-t border-border px-4 py-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <dl>
          <dt className="text-xs text-text-3">{partial ? "Covered holdings value" : "Open holdings value"}</dt>
          <dd className="tabular text-xl font-semibold">{exposure.priced ? money(exposure.total, base) : "—"}</dd>
        </dl>
        <div role="group" aria-label="Reporting currency" className="flex gap-1">
          {(["AUD", "USD"] as const).map((currency) => (
            <Button key={currency} size="sm" variant={currency === base ? "primary" : "secondary"}
              aria-pressed={currency === base} onClick={() => setBase(currency)}>{currency}</Button>
          ))}
        </div>
      </div>
      <p role="status" className="text-xs text-text-2">
        {exposure.priced} of {holdings.length} {truncated ? "displayed " : ""}holdings valued.
        {waiting ? " Checking prices and rates…" : ""}
        {exposure.missingRates > 0 && !waiting ? ` Missing rates for ${exposure.missingRates} holdings.` : ""}
        {truncated ? " Coverage is limited to the first 200 holdings." : ""}
      </p>
      {needsRates && rates.isError && <Button size="sm" onClick={() => void rates.refetch()}>Retry exchange rates</Button>}
      {exposure.priced === 0 ? <EmptyState title={waiting ? "Loading exposure" : "Exposure is unavailable"} /> : <>
        <dl className="flex flex-wrap gap-x-8 gap-y-2 border-t border-border pt-3 text-sm">
          <div>
            <dt className="text-xs text-text-3">Largest listing</dt>
            <dd><Link href={`/markets/${encodeURIComponent(largest.id)}`} className="hover:underline">{largest.label}</Link>
              {" · "}<span className="tabular">{percent(largest.weight, { signed: false, decimals: 1 })}</span></dd>
          </div>
          {exposure.listings.length >= 3 && <div>
            <dt className="text-xs text-text-3">Top three listings</dt>
            <dd className="tabular">{percent(topThree, { signed: false, decimals: 1 })}</dd>
          </div>}
        </dl>
        <div role="group" aria-label="Exposure breakdown" className="flex flex-wrap gap-1.5">
          {breakdownKeys.map((key) => (
            <Button key={key} size="sm" variant={key === breakdown ? "primary" : "secondary"}
              aria-pressed={key === breakdown} onClick={() => setBreakdown(key)}>{breakdowns[key]}</Button>
          ))}
        </div>
        <ul aria-label={breakdowns[breakdown]} className="space-y-3">
          {visible.map((item) => (
            <li key={item.id} className="space-y-1.5">
              <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-baseline gap-x-3 text-sm">
                {breakdown === "listings"
                  ? <Link href={`/markets/${encodeURIComponent(item.id)}`} className="break-words hover:underline">{item.label}</Link>
                  : <span className="break-words">{item.label}</span>}
                <span className="tabular text-text-2">{money(item.value, base)}</span>
                <span className="min-w-12 text-right tabular font-medium">{percent(item.weight, { signed: false, decimals: 1 })}</span>
              </div>
              <div aria-hidden className="h-1.5 overflow-hidden rounded-full bg-surface-3">
                <div className="h-full rounded-full bg-primary" style={{ width: `${item.weight}%` }} />
              </div>
            </li>
          ))}
        </ul>
        <p className="text-xs text-text-3">
          Oldest included quote {dateTime(exposure.oldestQuote)}.
          {exposure.fxDates.length > 0 && <> ECB reference rates observed {exposure.fxDates.join(", ")}.</>}
          {breakdown === "assets" && " ETF classifications use the market catalog."}
          {breakdown === "countries" && " Countries reflect the listing venue."}
          {breakdown === "currencies" && " Crypto is priced in USD."}
        </p>
      </>}
    </div>
  </Card>;
}
