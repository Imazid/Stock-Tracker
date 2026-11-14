import { useState } from "react";
import Link from "next/link";
import { useQueries, useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { getJSON } from "@/lib/api";
import { dateTime, money, percent } from "@/lib/format";
import { ISSUER_LOOKUP_LIMIT, type IssuerClassificationResponse } from "@/lib/issuer-classification";
import type { InstrumentView, QuoteResponse } from "@/lib/market-types";
import { portfolioExposure, type ExposureCurrency, type PortfolioReferenceRates } from "@/lib/portfolio-exposure";

const breakdowns = {
  assets: "Asset type", sectors: "SIC sector", countries: "Listing country", incorporations: "Issuer incorporation",
  currencies: "Quote currency", listings: "Largest positions",
} as const;

type Breakdown = keyof typeof breakdowns;
const breakdownKeys = Object.keys(breakdowns) as Breakdown[];
const selectedButton = "aria-pressed:border-primary aria-pressed:bg-primary-soft aria-pressed:text-primary-fg";

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
  const issuerDimension = breakdown === "sectors" || breakdown === "incorporations" ? breakdown : undefined;
  const issuerIds = [...new Set(holdings.flatMap(({ instrument }) => {
    if (!instrument || instrument.venue === "crypto") return [];
    const data = quoteFor(instrument.id);
    return data?.instrument.id === instrument.id && data.instrument.assetClass === "equity" && !data.quote.stale
      ? [instrument.id] : [];
  }))].sort();
  const issuerQueries = useQueries({
    queries: Array.from({ length: Math.ceil(issuerIds.length / ISSUER_LOOKUP_LIMIT) }, (_, index) => {
      const ids = issuerIds.slice(index * ISSUER_LOOKUP_LIMIT, (index + 1) * ISSUER_LOOKUP_LIMIT);
      const params = new URLSearchParams(ids.map((id) => ["id", id]));
      return {
        queryKey: ["portfolio-issuer-classifications", ids],
        queryFn: ({ signal }: { signal: AbortSignal }) =>
          getJSON<IssuerClassificationResponse>(`/api/portfolio/issuer-classifications?${params}`, signal),
        enabled: Boolean(issuerDimension) && !loading,
        staleTime: 5 * 60_000,
        retry: 1,
      };
    }),
  });
  const issuers = Object.assign({}, ...issuerQueries.map((query) => query.data?.issuers));
  const failedLookups = issuerQueries.filter((query) => query.isError || query.data?.limited);
  const exposure = portfolioExposure(holdings, quoteFor, base, rates.data, issuers);
  const partial = truncated || exposure.priced < holdings.length;
  const waiting = loading || (needsRates && rates.isPending);
  const visible = breakdown === "listings" ? exposure.listings.slice(0, 5) : exposure[breakdown];
  const largest = exposure.listings[0];
  const topThree = exposure.listings.slice(0, 3).reduce((sum, item) => sum + item.weight, 0);
  const issuerSources = exposure.issuerSources.filter(([, { classification }]) =>
    issuerDimension === "sectors" ? classification.sector : classification.country);

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
            <Button key={currency} size="sm" variant="secondary" className={selectedButton}
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
            <Button key={key} size="sm" variant="secondary" className={selectedButton}
              aria-pressed={key === breakdown} onClick={() => setBreakdown(key)}>{breakdowns[key]}</Button>
          ))}
        </div>
        {issuerDimension && <>
          <p role="status" className="text-xs text-text-2">
            {percent(exposure.classifiedWeight[issuerDimension], { signed: false, decimals: 1 })} of valued holdings classified.
            {issuerQueries.some((query) => query.isFetching) ? " Checking issuer filings…" : ""}
            {failedLookups.length > 0 ? " Some issuer lookups are temporarily unavailable." : ""}
          </p>
          {failedLookups.length > 0 && <Button size="sm" onClick={() => {
            for (const query of failedLookups) void query.refetch();
          }}>Retry issuer lookups</Button>}
        </>}
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
          {breakdown === "sectors" && " Sectors group SEC Standard Industrial Classification codes by SIC division."}
          {breakdown === "incorporations" && " Countries reflect the issuer’s legal incorporation. Revenue by country can differ."}
          {issuerDimension && " ETFs and crypto have their own rows."}
        </p>
        {issuerDimension && issuerSources.length > 0 && <details className="border-t border-border pt-3 text-sm">
          <summary className="cursor-pointer text-primary-fg">Issuer filing sources</summary>
          <ul className="mt-2 space-y-2">
            {issuerSources.map(([id, { listing, classification }]) => (
              <li key={id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5">
                <span>
                  <a href={classification.evidence.url} target="_blank" rel="noreferrer" className="text-primary-fg underline">
                    {classification.issuer} · {listing}
                  </a>
                  <span className="text-xs text-text-2">
                    {" · "}{issuerDimension === "sectors"
                      ? `${classification.sector} (SIC ${classification.sic})` : classification.country}
                  </span>
                </span>
                <span className="text-xs text-text-3">
                  {classification.evidence.filedOn
                    ? `SEC filing ${classification.evidence.filedOn}`
                    : `SEC record retrieved ${dateTime(classification.evidence.retrievedAt)}`}
                </span>
              </li>
            ))}
          </ul>
        </details>}
      </>}
    </div>
  </Card>;
}
