import { useQuery } from "@tanstack/react-query";
import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { getJSON } from "@/lib/api";
import { dateTime, money, signedMoney } from "@/lib/format";
import type { InstrumentView, QuoteView } from "@/lib/market-types";
import type { PortfolioReferenceRates } from "@/lib/portfolio-exposure";
import { unrealisedGains, type PortfolioGains } from "@/lib/portfolio-gains";

export function GainsCard({ userId, holdings, quoteFor, loading, truncated }: {
  userId: string;
  holdings: readonly { id: string; asset_symbol: string; shares: number; instrument: InstrumentView | null; broker_account?: { label: string } | null }[];
  quoteFor: (id: string) => QuoteView | undefined;
  loading: boolean;
  truncated: boolean;
}) {
  const ledger = useQuery({
    queryKey: ["portfolio-gains", userId],
    queryFn: async ({ signal }) => {
      const report = await getJSON<PortfolioGains>("/api/portfolio/gains", signal);
      if (report.owner !== userId) throw new Error("The account changed while loading gains.");
      return report;
    },
    staleTime: 30_000,
  });
  const needsRates = holdings.some(({ instrument }) => instrument && instrument.currency !== "USD");
  const rates = useQuery({
    queryKey: ["portfolio-reference-rates"],
    queryFn: ({ signal }) => getJSON<PortfolioReferenceRates>("/api/portfolio/reference-rates", signal),
    enabled: needsRates,
    staleTime: 15 * 60_000,
    refetchInterval: 30 * 60_000,
  });
  const report = ledger.data;
  const current = report && unrealisedGains(holdings, report.open, quoteFor, rates.data);
  const waiting = loading || (needsRates && rates.isPending);
  const covered = current?.byHolding.size ?? 0;

  return <Card>
    <CardHeader title="Gains and trading fees" subtitle="USD estimates from synced trades, using first in, first out (FIFO)."
      actions={report && <Button size="sm" disabled={ledger.isFetching} onClick={() => void ledger.refetch()}>Refresh gains</Button>} />
    <div className="space-y-3 border-t border-border p-4">
      {ledger.isPending ? <div className="skeleton h-16" role="status" aria-label="Loading gains" />
        : ledger.isError ? <EmptyState title="Couldn’t load gains" actions={<Button size="sm" onClick={() => void ledger.refetch()}>Retry</Button>} />
        : report && current && <>
          {!report.tradeRecords && !holdings.length ? <EmptyState title="No holdings or trade records yet" /> : <>
            <dl className="grid gap-4 tabular sm:grid-cols-3">
              <div>
                <dt className="text-xs text-text-2">Realised gain or loss</dt>
                <dd className="text-lg font-semibold">{report.realisedUsd === null ? "Unavailable" : signedMoney(report.realisedUsd, "USD")}</dd>
                <dd className="text-xs text-text-3">{report.sales ? `${report.matchedSales} of ${report.sales} sales fully matched.` : "No recorded sales."}
                  {report.partialSales > 0 && ` ${report.partialSales} partially matched.`}</dd>
              </div>
              <div>
                <dt className="text-xs text-text-2">Unrealised gain or loss</dt>
                <dd className="text-lg font-semibold">{current.total === null ? "Unavailable" : signedMoney(current.total, "USD")}</dd>
                <dd className="text-xs text-text-3" role="status">
                  {covered} of {holdings.length} {truncated ? "displayed " : ""}holdings covered.
                  {waiting && " Checking prices and rates…"}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-text-2">Recorded trading fees</dt>
                <dd className="text-lg font-semibold">{report.feesUsd === null ? "Unavailable" : money(report.feesUsd, "USD")}</dd>
                <dd className="text-xs text-text-3">Fees from {report.feeRecords} of {report.tradeRecords} synced trade records.</dd>
              </div>
            </dl>
            <p className="text-xs text-text-2">Realised gains use matched sale quantities after purchase and sale fees. Unrealised gains use open lots with a known cost, matching quantities and usable prices. Purchase fees are included in open lot costs. Use tax-lot records and statements for tax reporting.</p>
            {(current.basisMissing > 0 || current.pricesMissing > 0 || current.fxMissing > 0) && <p className="text-xs text-text-2">
              {current.basisMissing > 0 && `${current.basisMissing} holdings need a reconciled acquisition cost or quantity. `}
              {current.pricesMissing > 0 && !waiting && `${current.pricesMissing} holdings have unavailable prices. `}
              {current.fxMissing > 0 && !waiting && `${current.fxMissing} holdings need exchange rates.`}
            </p>}
            {report.pendingTransfers > 0 && <p className="text-xs text-text-2">Transfers in transit or needing review · {report.pendingTransfers}</p>}
            {report.archivedLots > 0 && <p className="text-xs text-text-2">Archived holdings with remaining lots · {report.archivedLots}</p>}
            {truncated && <p className="text-xs text-text-2">Unrealised gains cover the first 200 holdings shown in Portfolio.</p>}
            {needsRates && rates.isError && <Button size="sm" onClick={() => void rates.refetch()}>Retry exchange rates</Button>}
            <p className="text-xs text-text-3">Ledger checked {dateTime(report.asOf)}.
              {current.oldestQuote && ` Oldest included quote ${dateTime(current.oldestQuote)}.`}
              {current.fxDates.length > 0 && ` ECB reference rates observed ${current.fxDates.join(", ")}.`}
            </p>
            {holdings.length > 0 && <details className="border-t border-border pt-3 text-sm">
              <summary className="cursor-pointer text-primary-fg">Unrealised gain or loss by holding</summary>
              <ul className="divide-y divide-border pt-1">
                {holdings.map(({ id, asset_symbol, instrument, broker_account }) => {
                  const gain = current.byHolding.get(id);
                  const label = instrument ? `${instrument.symbol} · ${instrument.venueShort}` : asset_symbol;
                  return <li key={id} className="flex flex-wrap items-baseline justify-between gap-x-3 py-2">
                    <span className="min-w-0 break-words">
                      {instrument ? <Link href={`/markets/${encodeURIComponent(instrument.id)}`} className="hover:underline">{label}</Link> : label}
                      {broker_account && <span className="ml-2 text-xs text-text-3">{broker_account.label}</span>}
                    </span>
                    <span className="tabular">{gain === undefined ? "Unavailable" : signedMoney(gain, "USD")}</span>
                  </li>;
                })}
              </ul>
            </details>}
          </>}
        </>}
    </div>
  </Card>;
}
