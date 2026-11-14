"use client";

import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { manualPortfolioQuery, manualValuationIsStale } from "@/app/private-markets/manual-portfolio";
import { privateMarkets, dateLabel, dayInSydney } from "@/app/private-markets/private-data";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Notice } from "@/components/ui/Notice";
import { usePortfolioRates } from "@/hooks/portfolio-metrics";
import { dateTime, money, percent } from "@/lib/format";
import type { QuoteResponse } from "@/lib/market-types";
import { portfolioExposure, type ExposureCurrency } from "@/lib/portfolio-exposure";
import type { PortfolioHolding } from "@/lib/portfolio-holdings";
import { unifiedAllocation, type PrivateAllocationBucket } from "@/lib/unified-allocation";

export function AllocationCard({ owner, holdings, quoteFor, loading, truncated }: {
  owner: string;
  holdings: readonly PortfolioHolding[];
  quoteFor: (id: string) => QuoteResponse | undefined;
  loading: boolean;
  truncated: boolean;
}) {
  const [currency, setCurrency] = useState<ExposureCurrency>("AUD");
  const privatePositions = useQuery({
    queryKey: ["private-markets", owner, "allocation"], gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ buckets: PrivateAllocationBucket[] }>("allocation", { owner, signal }),
  });
  const manual = useQuery(manualPortfolioQuery(owner));
  const manualBuckets: PrivateAllocationBucket[] = (manual.error ? [] : manual.data?.snapshot?.holdings ?? [])
    .filter((holding) => !holding.exitedOn).map(({ currency, assetClass, valuation }) => ({
      asset_class: assetClass, currency, position_count: 1, valued_count: valuation ? 1 : 0,
      carrying_value: valuation?.value ?? null,
      stale_count: valuation && manualValuationIsStale(valuation.date, manual.dataUpdatedAt) ? 1 : 0,
      oldest_valuation: valuation ? dayInSydney(Date.parse(valuation.date)) : null,
    }));
  const buckets = [...(privatePositions.data?.buckets ?? []), ...manualBuckets];
  const needsRates = holdings.some(({ instrument }) => instrument && instrument.currency !== currency) ||
    buckets.some((bucket) => bucket.currency !== currency && bucket.carrying_value !== null && Number(bucket.carrying_value) !== 0);
  const rates = usePortfolioRates(needsRates);
  const listed = portfolioExposure(holdings, quoteFor, currency, needsRates ? rates.data : undefined);
  const allocation = unifiedAllocation(listed, buckets, currency, needsRates ? rates.data : undefined);
  const partial = truncated || listed.priced < holdings.length || allocation.valued < allocation.positions || privatePositions.isError || manual.isError;
  const waiting = loading || privatePositions.isPending || manual.isPending || (needsRates && rates.isPending);
  const covered = listed.priced + allocation.valued;

  return <Card id="unified-allocation">
    <CardHeader title="Unified allocation" subtitle="Synced listed holdings, provider records and published self-reported positions." />
    <div className="space-y-3 border-t border-border p-4">
      {privatePositions.error && <Notice tone="down">
        Private valuations are temporarily unavailable. <Button size="sm" onClick={() => void privatePositions.refetch()}>Retry valuations</Button>
      </Notice>}
      {manual.error && <Notice tone="down">
        Self-reported valuations are temporarily unavailable. <Button size="sm" onClick={() => void manual.refetch()}>Retry snapshot</Button>
      </Notice>}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <dl>
          <dt className="text-xs text-text-3">{partial || waiting ? "Covered holdings value" : "Included holdings value"}</dt>
          <dd className="tabular text-xl font-semibold">{covered > 0 ? money(allocation.total, currency) : "—"}</dd>
        </dl>
        <div role="group" aria-label="Allocation currency" className="flex gap-1">
          {(["AUD", "USD"] as const).map((code) => (
            <Button key={code} size="sm" variant="secondary" aria-pressed={currency === code}
              className="aria-pressed:border-primary aria-pressed:bg-primary-soft aria-pressed:text-primary-fg"
              onClick={() => setCurrency(code)}>{code}</Button>
          ))}
        </div>
      </div>
      <p role="status" className="text-xs text-text-2">
        {listed.priced} of {holdings.length} {truncated ? "displayed " : ""}listed positions valued.
        {privatePositions.data && ` ${allocation.valued} of ${allocation.positions} private positions valued.`}
        {waiting && " Checking quotes, valuations and exchange rates…"}
        {truncated && " Listed coverage is limited to the first 200 synced holdings."}
      </p>
      {(allocation.missingMarks > 0 || listed.missingRates + allocation.missingRates > 0 || allocation.stale > 0) &&
        <ul className="list-disc space-y-0.5 pl-4 text-xs text-text-2">
          {allocation.missingMarks > 0 && <li>Missing usable valuations for {allocation.missingMarks} private positions.</li>}
          {listed.missingRates + allocation.missingRates > 0 && <li>Missing exchange rates for {listed.missingRates + allocation.missingRates} positions.</li>}
          {allocation.stale > 0 && <li>Includes {allocation.stale} private {allocation.stale === 1 ? "valuation" : "valuations"} older than 90 days.</li>}
        </ul>}
      {needsRates && rates.isError && <Button size="sm" onClick={() => void rates.refetch()}>Retry rates</Button>}
      {covered === 0 ? <EmptyState title={waiting ? "Loading allocation" : "No holdings with a usable value"} /> :
        <ul aria-label="Unified allocation categories" className="space-y-2.5 border-t border-border pt-3">
          {allocation.rows.map((row) => (
            <li key={row.id} className="space-y-1">
              <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-baseline gap-x-2 text-sm">
                <span className="break-words">{row.label}</span>
                <span className="tabular text-text-2">{money(row.value, currency)}</span>
                <span className="text-right tabular font-medium">{allocation.total > 0 ? percent(row.weight, { signed: false, decimals: 1 }) : "—"}</span>
              </div>
              <div aria-hidden className="h-1.5 overflow-hidden rounded-full bg-surface-3">
                <div className={row.privateAsset ? "h-full rounded-full bg-up" : "h-full rounded-full bg-primary"} style={{ width: `${row.weight}%` }} />
              </div>
            </li>
          ))}
        </ul>}
      <div className="space-y-2 border-t border-border pt-3">
        <p className="text-xs text-text-3">
          Private carrying values use dated provider statements or published self-reported marks. Self-reported values reflect the latest iPhone snapshot. Cash is excluded.
          {listed.oldestQuote && ` Oldest included listing quote ${dateTime(listed.oldestQuote)}.`}
          {allocation.oldestValuation && ` Oldest included private valuation ${dateLabel(allocation.oldestValuation)}.`}
          {allocation.fxDates.length > 0 && ` ECB reference rates observed ${allocation.fxDates.join(", ")}.`}
        </p>
        {allocation.positions > 0 && <ButtonLink href="/private-markets?view=portfolio" size="sm">Review private valuations</ButtonLink>}
      </div>
    </div>
  </Card>;
}
