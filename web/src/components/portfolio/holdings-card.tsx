"use client";

import Image from "next/image";
import Link from "next/link";
import { Bitcoin } from "lucide-react";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { ChangeText } from "@/components/market/Change";
import { SourceLine, StatusChip } from "@/components/market/DataChips";
import { EmptyState } from "@/components/ui/EmptyState";
import { dateTime, money, percent, plainNumber, signedMoney } from "@/lib/format";
import type { InstrumentView } from "@/lib/market-types";
import { portfolioAssetLabels } from "@/lib/portfolio-exposure";
import { findHoldings, type HoldingClass, type HoldingComparisonRow, type HoldingSort, type holdingComparison } from "@/lib/portfolio-holdings";
import { venueYahooSuffix } from "@engine/market.ts";
import styles from "./holdings-card.module.css";

const assetClasses = { ...portfolioAssetLabels, unclassified: "Unclassified" };
const sortOptions: Record<HoldingSort, string> = {
  value: "Highest value (USD)",
  change: "Largest price gain (%)",
  drop: "Largest price drop (%)",
  gain: "Highest unrealised gain (USD)",
  loss: "Largest unrealised loss (USD)",
  symbol: "Ticker (A–Z)",
};

function AssetLogo({ instrument, symbol, enabled }: { instrument: InstrumentView | null; symbol: string; enabled: boolean }) {
  const [state, setState] = useState<"pending" | "loaded" | "error">("pending");
  const ticker = instrument && (instrument.venue === "crypto" ? `${instrument.symbol}USD`
    : instrument.symbol + (venueYahooSuffix(instrument.venue) ?? ""));
  const src = enabled && ticker && /^[A-Z0-9][A-Z0-9.\-&]{0,29}$/.test(ticker)
    ? `https://images.financialmodelingprep.com/symbol/${encodeURIComponent(ticker)}.png` : undefined;
  return <span className={styles.logo} aria-hidden="true">
    {symbol === "BTC" && instrument?.venue === "crypto" ? <Bitcoin size={19} /> : symbol.slice(0, 3)}
    {src && state !== "error" && <Image src={src} alt="" width={34} height={34} unoptimized referrerPolicy="no-referrer"
      className={state === "loaded" ? styles.logoImage : styles.logoPending}
      onLoad={() => setState("loaded")} onError={() => setState("error")} />}
  </span>;
}

function Figure({ label, children, detail }: { label: string; children: ReactNode; detail?: ReactNode }) {
  return <div className={styles.figure}>
    <dt>{label}</dt><dd>{children}</dd>
    {detail && <dd className={styles.detail}>{detail}</dd>}
  </div>;
}

function HoldingItem({ row, logosEnabled, quotePending }: { row: HoldingComparisonRow; logosEnabled: boolean; quotePending: boolean }) {
  const { holding, quote, symbol, name, venue, local, value, change, gain, weight, assetClass } = row;
  const { instrument, broker_account: account } = holding;
  const gainColor = gain === undefined || gain === 0 ? undefined : gain > 0 ? "text-up" : "text-down";
  return <li className={styles.row}>
    <div className={styles.asset}>
      <AssetLogo instrument={instrument} symbol={symbol} enabled={logosEnabled} />
      <div className={styles.identity}>
        {instrument
          ? <Link href={`/markets/${encodeURIComponent(instrument.id)}`} prefetch={false} className={styles.assetLink}>{symbol}<span className="sr-only"> {name}, {venue}</span></Link>
          : <strong>{symbol}</strong>}
        <p className={styles.name}>{name}</p>
        <p className={styles.detail}>{assetClasses[assetClass]}{venue && ` · ${venue}`}</p>
        {account && <p className={styles.detail}>{account.label}
          {account.tracking ? ` · As of ${dateTime(account.observed_at)}` : " · Kept manually"}</p>}
      </div>
    </div>
    <dl className={styles.figures}>
      <Figure label={quote?.stale ? "Last known price" : "Price"} detail={quote && change !== undefined && <ChangeText changePct={change} />}>
        {quote ? money(quote.last, quote.currency) : !instrument ? "Listing unavailable" : quotePending ? "Loading" : "Unavailable"}
      </Figure>
      <Figure label="Units">{plainNumber(holding.shares, 8)}</Figure>
      <Figure label="Position value" detail={quote && value !== undefined && quote.currency !== "USD" && money(value, "USD")}>
        {quote && local !== undefined ? money(local, quote.currency) : "—"}
      </Figure>
      <Figure label="Avg. cost (USD)">{holding.avg_cost > 0 ? money(holding.avg_cost, "USD") : "—"}</Figure>
      <Figure label="Unrealised (USD)"><span className={gainColor}>{signedMoney(gain, "USD")}</span></Figure>
      <Figure label="Weight">{percent(weight, { signed: false, decimals: 2 })}</Figure>
    </dl>
    {quote && <div className={styles.source}>
      <StatusChip status={quote.status} delayMinutes={quote.delayMinutes} /><SourceLine {...quote} />
    </div>}
  </li>;
}

export function HoldingsCard({ comparison, pendingQuotes, truncated, logosEnabled, overview = false, gainsUnavailable = false, ratesUnavailable = false }: {
  comparison: ReturnType<typeof holdingComparison>;
  pendingQuotes: ReadonlySet<string>;
  truncated: boolean;
  logosEnabled: boolean;
  overview?: boolean;
  gainsUnavailable?: boolean;
  ratesUnavailable?: boolean;
}) {
  const heading = useId();
  const section = useRef<HTMLElement>(null);
  const [search, setSearch] = useState("");
  const [assetClass, setAssetClass] = useState<HoldingClass | "all">("all");
  const [sort, setSort] = useState<HoldingSort>("value");
  const pageSize = overview ? 5 : 12;
  const [limit, setLimit] = useState(pageSize);
  const matches = findHoldings(comparison.rows, search, assetClass, sort);
  const filtered = search.trim() || assetClass !== "all";
  const displayed = matches.slice(0, limit);

  useEffect(() => {
    if (!overview && window.location.hash === "#holdings") section.current?.scrollIntoView();
  }, [overview]);

  function resetFilters() {
    setSearch("");
    setAssetClass("all");
    setLimit(pageSize);
  }

  return <section id="holdings" ref={section} className={styles.holdings} aria-labelledby={heading} data-workspace={overview ? "" : undefined}>
    <header className={styles.heading}>
      <h2 id={heading}>Holdings</h2>
      {overview && comparison.rows.length > 0 && <Link href="/portfolio#holdings">Open in Portfolio</Link>}
    </header>
    {comparison.rows.length === 0 ? <EmptyState title="Your portfolio has no open holdings" body="Add a holding on the web or sync from the iPhone app."
      actions={<Link href="/#portfolio" className={styles.assetLink}>Manage holdings</Link>} /> : <>
      <div className={styles.controls}>
        <label>Search holdings
          <input type="search" value={search} placeholder="Ticker, name or account" onChange={(event) => { setSearch(event.target.value); setLimit(pageSize); }} />
        </label>
        <label>Asset type
          <select value={assetClass} onChange={(event) => { setAssetClass(event.target.value as HoldingClass | "all"); setLimit(pageSize); }}>
            <option value="all">All assets</option>
            {Object.entries(assetClasses).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
          </select>
        </label>
        <label>Sort holdings
          <select value={sort} onChange={(event) => { setSort(event.target.value as HoldingSort); setLimit(pageSize); }}>
            {Object.entries(sortOptions).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
          </select>
        </label>
      </div>
      <div className={styles.coverage}>
        <p role="status">Showing {displayed.length} of {matches.length} {filtered ? "matching " : ""}holdings.
          {pendingQuotes.size > 0 && " Checking prices…"}</p>
        <p>Weight uses all {comparison.valued} of {comparison.rows.length} holdings valued in USD with usable quotes and rates.
          {comparison.fxDates.length > 0 && ` ECB FX ${comparison.fxDates.join(", ")}.`}</p>
        <p>Unrealised gains use reconciled FIFO lots. Price change uses the provider’s reference price.</p>
        {truncated && <p>Comparison covers the first 200 open holdings by ticker.</p>}
        {gainsUnavailable && <p>FIFO gains are temporarily unavailable.</p>}
        {ratesUnavailable && <p>Some positions need exchange rates for USD comparisons.</p>}
      </div>
      {displayed.length ? <ul className={styles.rows}>
        {displayed.map((row) => <HoldingItem key={row.holding.id} row={row} logosEnabled={logosEnabled}
          quotePending={Boolean(row.holding.instrument && pendingQuotes.has(row.holding.instrument.id))} />)}
      </ul> : <EmptyState title="No holdings match" actions={<button className={styles.button} type="button" onClick={resetFilters}>Clear filters</button>} />}
      {matches.length > limit && <footer className={styles.footer}>
        <button className={styles.button} type="button" onClick={() => setLimit(limit + pageSize)}>Show more holdings</button>
      </footer>}
    </>}
  </section>;
}
