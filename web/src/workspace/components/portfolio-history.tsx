"use client";

import Link from "next/link";
import { useState } from "react";
import { usePortfolioHistory } from "@/hooks/portfolio-history";
import { money, percent, signedMoney } from "@/lib/format";
import { historyRanges, snapshotHistory, statementHistory, type HistoryKind, type HistoryRange } from "@/lib/portfolio-history";
import Chart from "./chart";

const day = (time: number) => new Date(time).toISOString().slice(0, 10);
const kinds = [{ id: "values", label: "Saved values" }, { id: "returns", label: "Investment return" }] as const;

export function PortfolioHistory({ userId, portfolioLink = false }: { userId: string; portfolioLink?: boolean }) {
  const [kind, setKind] = useState<HistoryKind>("values");
  const [range, setRange] = useState<HistoryRange>("1M");
  const query = usePortfolioHistory(userId, kind);
  const today = Date.parse(day(query.dataUpdatedAt));
  const snapshots = query.data?.kind === "values" ? snapshotHistory(query.data.rows, today, range) : [];
  const returns = query.data?.kind === "returns" ? statementHistory(query.data.rows, today, range) : undefined;
  const points = returns?.investment ?? snapshots;
  const first = points[0], last = points.at(-1);

  return <section className="panel price-panel portfolio-history" aria-label="Portfolio performance">
    <div className="panel-heading portfolio-history-heading">
      <h2>Portfolio performance</h2>
      {portfolioLink && <Link className="button secondary small" href="/portfolio">Open Portfolio</Link>}
    </div>
    <div className="portfolio-history-controls">
      <div className="segmented" role="group" aria-label="History type">
        {kinds.map(({ id, label }) => <button key={id} type="button" aria-pressed={kind === id} onClick={() => setKind(id)}>{label}</button>)}
      </div>
      <div className="segmented" role="group" aria-label="Portfolio history range">
        {(Object.keys(historyRanges) as HistoryRange[]).map((value) => <button key={value} type="button" aria-pressed={range === value}
          onClick={() => setRange(value)}>{value === "ALL" ? "All" : value}</button>)}
      </div>
    </div>
    {query.isPending ? <p className="portfolio-history-state" role="status">Loading portfolio history…</p>
      : query.isError ? <div className="portfolio-history-state">
        <p role="status">Couldn’t load portfolio history.</p><button type="button" className="button secondary small" onClick={() => void query.refetch()}>Retry</button>
      </div>
      : !last ? <div className="portfolio-history-state">
        <p role="status">{kind === "values" ? "No saved valuations in this range." : "No complete statement periods in this range."}</p>
        {range !== "ALL" && <button type="button" className="button secondary small" onClick={() => setRange("ALL")}>Show all history</button>}
        {kind === "returns" && <Link className="button secondary small" href="/portfolio#portfolio-returns">Manage statement periods</Link>}
      </div> : <>
        <div className="portfolio-history-summary" aria-live="polite">
          <dl>
            <div><dt>{returns ? "Investment change" : "Latest saved holdings value"}</dt>
              <dd>{returns ? signedMoney(last.value, "USD") : money(last.value, "USD")}</dd></div>
            {returns ? <>
              <div><dt>Net external transfers</dt><dd>{signedMoney(returns.transfers.at(-1)?.value, "USD")}</dd></div>
              <div><dt>Time-weighted return</dt><dd>{returns.timeWeighted === null ? "Unavailable" : percent(returns.timeWeighted)}</dd></div>
            </> : points.length > 1 && <div><dt>Change in saved value</dt><dd>{signedMoney(last.value - first.value, "USD")}</dd></div>}
          </dl>
          <p><time dateTime={day(first.time)}>{day(first.time)}</time>{first.time !== last.time && <> to <time dateTime={day(last.time)}>{day(last.time)}</time></>}
            {returns && <> · {returns.periods} {returns.periods === 1 ? "period" : "linked periods"}</>}</p>
        </div>
        <Chart key={kind} points={points} history={returns
          ? { label: "Statement return chart", valueLabel: "Investment change" }
          : { label: "Saved holdings value chart", valueLabel: "Holdings value" }}
          comparison={returns && { label: "Net external transfers", points: returns.transfers }} />
        <HistoryTable key={`${kind}:${range}`} points={points} transfers={returns?.transfers} />
      </>}
    <footer className="portfolio-history-footer">
      {kind === "values"
        ? "Daily iPhone holdings snapshots in USD. Values reflect the holdings saved on each date."
        : "USD totals use the latest continuous chain of complete saved periods in the range. The solid line shows investment change. The dashed line shows net external transfers."}
      {kind === "values" && range === "1D" && " This view shows up to two daily snapshots."}
    </footer>
  </section>;
}

function HistoryTable({ points, transfers }: { points: readonly { time: number; value: number }[]; transfers?: readonly { value: number }[] }) {
  const [limit, setLimit] = useState(30);
  const offset = Math.max(0, points.length - limit);
  return <details className="portfolio-history-table">
    <summary>View chart data</summary>
    <table>
      <thead><tr><th scope="col">Date</th><th scope="col">{transfers ? "Investment change" : "Holdings value"}</th>
        {transfers && <th scope="col">Net external transfers</th>}</tr></thead>
      <tbody>{points.slice(offset).map((point, index) => {
        const date = day(point.time);
        return <tr key={date}><th scope="row"><time dateTime={date}>{date}</time></th><td>{money(point.value, "USD")}</td>
          {transfers && <td>{money(transfers[offset + index].value, "USD")}</td>}</tr>;
      }).reverse()}</tbody>
    </table>
    {points.length > limit && <button type="button" className="button secondary small" onClick={() => setLimit(limit + 30)}>Show older values</button>}
  </details>;
}
