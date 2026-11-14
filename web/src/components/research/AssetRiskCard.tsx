"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader } from "@/components/ui/Card";
import { Segmented } from "@/components/ui/Segmented";
import { StatusChip } from "@/components/market/DataChips";
import { ASSET_RISK_RANGES, type AssetRisk, type AssetRiskRange } from "@/lib/asset-risk";
import { ApiError, getJSON } from "@/lib/api";
import { dateTime, percent } from "@/lib/format";

const options = ASSET_RISK_RANGES.map((value) => ({ value, label: value }));

export function AssetRiskCard({ id }: { id: string }) {
  const [range, setRange] = useState<AssetRiskRange>("3M");
  const risk = useQuery({
    queryKey: ["asset-risk", id, range],
    queryFn: ({ signal }) => getJSON<AssetRisk>(`/api/markets/instruments/${encodeURIComponent(id)}/risk?range=${range}`, signal),
    staleTime: 60_000,
    retry: false,
  });
  const data = risk.data;
  const insufficient = risk.error instanceof ApiError && risk.error.code === "insufficient_history";

  return (
    <Card id="asset-risk" className="mt-5 scroll-mt-20">
      <CardHeader title="Historical price risk" subtitle="Based on completed daily closes in the history feed’s currency." />
      <div className="space-y-3 border-t border-border p-4">
        <Segmented label="Risk period" value={range} onChange={setRange} options={options} />
        {risk.isPending ? <p role="status" className="text-sm text-text-2">Loading daily price history…</p> : null}
        {risk.isError ? <div className="flex flex-wrap items-center gap-2">
          <p role="status" className="text-sm text-text-2">
            {insufficient ? "Too few completed daily closes for this period." : "Daily price history is unavailable."}
          </p>
          {!insufficient && <Button size="sm" onClick={() => void risk.refetch()}>Retry risk history</Button>}
        </div> : null}
        {data ? <>
          <dl className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-lg bg-surface-2 p-3">
              <dt className="text-xs text-text-2">Price change</dt>
              <dd className="tabular text-lg font-semibold">{percent(data.priceChangePct, { decimals: 2 })}</dd>
              <dd className="text-xs text-text-3">{data.from} to {data.through}</dd>
            </div>
            <div className="rounded-lg bg-surface-2 p-3">
              <dt className="text-xs text-text-2">Largest drawdown</dt>
              <dd className="tabular text-lg font-semibold">{percent(-data.maxDrawdownPct, { signed: false, decimals: 2 })}</dd>
              <dd className="text-xs text-text-3">
                {data.maxDrawdownPct > 0 ? `${data.drawdownPeakDate} to ${data.drawdownTroughDate}` : "No decline between closing prices"}
              </dd>
            </div>
            <div className="rounded-lg bg-surface-2 p-3">
              <dt className="text-xs text-text-2">Daily volatility · 20 sessions</dt>
              <dd className="tabular text-lg font-semibold">
                {data.dailyVolatilityPct === null ? "Unavailable" : percent(data.dailyVolatilityPct, { signed: false, decimals: 2 })}
              </dd>
              <dd className="text-xs text-text-3">
                {data.volatilityFrom ? `${data.volatilityFrom} to ${data.through}` : "Needs 21 consecutive completed closes"}
              </dd>
            </div>
          </dl>
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-text-2">
            <span>{data.source}</span><StatusChip status={data.status} />
            <span>{data.currency} · {data.adjustment}</span>
            <span>{data.sessions} closes · checked {dateTime(data.fetchedAt)}</span>
          </div>
          {data.missingSessions > 0 || data.missedRecentSessions > 0 || !data.calendarCovered ? (
            <p role="status" className="text-xs text-text-2">
              {data.missingSessions > 0 ? `${data.missingSessions} expected closes are absent within the displayed period. Drawdown uses observed closes. ` : ""}
              {data.missedRecentSessions > 0 ? `${data.missedRecentSessions} more recent completed sessions are missing. ` : ""}
              {!data.calendarCovered ? "Exchange holiday coverage is incomplete for these dates." : ""}
            </p>
          ) : null}
          <details className="text-xs text-text-2">
            <summary className="cursor-pointer text-primary-fg">How these figures are calculated</summary>
            <p className="mt-2">Price change compares the first and last closes. Drawdown measures the largest fall from an earlier closing peak. Daily volatility is the sample standard deviation of the last 20 consecutive daily percentage changes.</p>
          </details>
        </> : null}
      </div>
    </Card>
  );
}
