"use client";

import { useId, useState } from "react";
import { SourceLine, StatusChip } from "@/components/market/DataChips";
import { Button, ButtonLink } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { mainPortfolioId, usePortfolioGroups } from "@/hooks/portfolio-groups";
import { usePortfolioGains, usePortfolioRates } from "@/hooks/portfolio-metrics";
import { useListingPositions } from "@/hooks/portfolio-positions";
import { dateTime, money, plainNumber, signedMoney } from "@/lib/format";
import type { InstrumentView, QuoteView } from "@/lib/market-types";
import { holdingValue, matchingHoldingQuote } from "@/lib/portfolio-exposure";
import { reconciledOpenCost, unrealisedGains } from "@/lib/portfolio-gains";
import { useSession } from "@/lib/session";

export function ListingPositions({ instrument, quote }: { instrument: InstrumentView; quote?: QuoteView }) {
  const session = useSession();
  if (session.status !== "signedIn") return null;
  return <AccountPositions key={`${session.user.id}:${instrument.id}`} userId={session.user.id} instrument={instrument} quote={quote} />;
}

function AccountPositions({ instrument, quote, userId }: { instrument: InstrumentView; quote?: QuoteView; userId: string }) {
  const heading = useId();
  const [limit, setLimit] = useState(8);
  const positions = useListingPositions(userId, instrument);
  const rows = positions.data ?? [];
  const gains = usePortfolioGains(rows.length ? userId : undefined);
  const { groups } = usePortfolioGroups(rows.length ? userId : undefined);
  const price = matchingHoldingQuote(instrument, quote);
  const rates = usePortfolioRates(Boolean(rows.length && price && !price.stale && price.currency !== "USD"));
  const unrealised = gains.data && unrealisedGains(rows, gains.data.open, () => price, rates.data);
  const names = new Map(groups.data?.map((group) => [group.id, group.name]));
  const units = instrument.venue === "crypto" ? `Units (${instrument.symbol})` : "Shares";

  return <Card className="mt-5">
    <section aria-labelledby={heading}>
      <div className="flex flex-wrap items-center justify-between gap-2 px-4 pb-3 pt-4">
        <h2 id={heading} className="text-sm font-semibold text-text">Your positions</h2>
        <ButtonLink href={rows.length ? "/portfolio#holdings" : "/#portfolio"} size="sm" variant="ghost">
          {rows.length ? "Open Portfolio" : "Manage holdings"}
        </ButtonLink>
      </div>
      {positions.isPending ? <p className="border-t border-border px-4 py-3 text-sm text-text-2" role="status">Loading your positions…</p>
        : positions.isError ? <div className="space-y-2 border-t border-border px-4 py-3">
          <p className="text-sm text-text-2" role="status">Couldn’t load your positions.</p>
          <Button size="sm" onClick={() => void positions.refetch()}>Retry positions</Button>
        </div>
        : rows.length === 0 ? <p className="border-t border-border px-4 py-3 text-sm text-text-2">You have no open positions in this listing.</p>
        : <>
          <ul className="divide-y divide-border border-t border-border">
            {rows.slice(0, limit).map((holding) => {
              const account = holding.broker_account;
              const name = names.get(holding.portfolio_group_id ?? mainPortfolioId);
              const cost = reconciledOpenCost(holding.shares, gains.data?.open[holding.id]);
              const gain = unrealised?.byHolding.get(holding.id);
              const value = price && holdingValue(holding.shares, price, "USD", rates.data).local;
              return <li key={holding.id} className="space-y-2 px-4 py-3">
                <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                  <h3 className="break-words text-sm font-medium text-text">{account?.label ?? "Manual holding"}</h3>
                  {name && <span className="break-words text-xs text-text-2">{name}</span>}
                  {account?.tracking && <p className="text-xs text-text-2">Broker position as of {dateTime(account.observed_at)}</p>}
                </div>
                <dl className="grid grid-cols-2 gap-x-3 gap-y-2 text-sm sm:grid-cols-4">
                  <Figure label={units} value={plainNumber(holding.shares, 18)} />
                  <Figure label="Market value" value={price && value !== undefined ? money(value, price.currency) : "Unavailable"} />
                  <Figure label="FIFO cost basis (USD)" value={cost !== undefined ? money(cost, "USD") : gains.isPending ? "Loading…" : "Unavailable"} />
                  <Figure label="Unrealised gain/loss (USD)" value={gain !== undefined ? signedMoney(gain, "USD") : "Unavailable"}
                    tone={gain ? (gain > 0 ? "text-up" : "text-down") : undefined} />
                </dl>
              </li>;
            })}
          </ul>
          <div className="space-y-2 border-t border-border px-4 py-3 text-xs text-text-2">
            {price && <div className="flex flex-wrap items-center gap-2"><StatusChip status={price.status} delayMinutes={price.delayMinutes} /><SourceLine {...price} /></div>}
            <p>FIFO basis uses reconciled acquisition records. Unrealised gain requires a usable price and matching cost basis.</p>
            {Boolean(unrealised?.fxDates.length) && <p>USD conversion uses the ECB reference rate from {unrealised!.fxDates.join(", ")}.</p>}
            {rows.length > limit && <Button size="sm" onClick={() => setLimit(limit + 8)}>Show more positions</Button>}
            {gains.isError && <Button size="sm" onClick={() => void gains.refetch()}>Retry cost basis</Button>}
          </div>
        </>}
    </section>
  </Card>;
}

function Figure({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return <div className="min-w-0">
    <dt className="text-xs text-text-2">{label}</dt>
    <dd className={`tabular break-words font-medium ${tone ?? "text-text"}`}>{value}</dd>
  </div>;
}
