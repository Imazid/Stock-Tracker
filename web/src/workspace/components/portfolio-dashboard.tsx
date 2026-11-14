"use client";

import Link from "next/link";
import { useState, type ReactNode } from "react";
import { HoldingsCard } from "@/components/portfolio/holdings-card";
import { usePortfolioBrokerage } from "@/hooks/portfolio-brokerage";
import { usePortfolioGains, usePortfolioRates } from "@/hooks/portfolio-metrics";
import { usePortfolioPositions } from "@/hooks/portfolio-positions";
import { dateTime, money, percent, signedMoney } from "@/lib/format";
import { portfolioAccountValue } from "@/lib/portfolio-account-value";
import { portfolioExposure, type ExposureCurrency } from "@/lib/portfolio-exposure";
import { unrealisedGains } from "@/lib/portfolio-gains";
import { holdingComparison } from "@/lib/portfolio-holdings";
import { portfolioMovement } from "@/lib/portfolio-movement";
import { PortfolioHistory } from "./portfolio-history";

function Metric({ title, value, detail }: { title: string; value: ReactNode; detail: ReactNode }) {
  return <div className="dashboard-metric"><dt>{title}</dt><dd><span>{value}</span><small>{detail}</small></dd></div>;
}

const balanceText = (amount: string | null | undefined, currency: string) => amount == null ? "Unavailable" : money(Number(amount), currency);

export function PortfolioDashboard({ userId, brokerageEnabled, pendingApprovals, openAgents, aiEnabled, logosEnabled, openConnections }: {
  userId: string; brokerageEnabled: boolean; pendingApprovals?: number; openAgents: () => void; aiEnabled: boolean; logosEnabled: boolean; openConnections: () => void;
}) {
  const [base, setBase] = useState<ExposureCurrency>("USD");
  const [showAccounts, setShowAccounts] = useState(false);
  const { portfolio, holdings, pricedListings, quotes, pendingQuotes, loadingPrices } = usePortfolioPositions(userId);
  const gains = usePortfolioGains(userId);
  const brokerage = usePortfolioBrokerage(userId, brokerageEnabled && showAccounts);
  const accounts = brokerage.data?.accounts ?? [];
  const rates = usePortfolioRates(holdings.some(({ instrument }) => instrument && (instrument.currency !== "USD" || base !== "USD")) ||
    accounts.some(({ netValue }) => netValue && netValue.currency !== base));
  const quoteFor = (id: string) => quotes.get(id)?.data;
  const exposure = portfolioExposure(holdings, quoteFor, base, rates.data);
  const movement = portfolioMovement(pricedListings, (id) => quoteFor(id)?.quote);
  const realised = gains.data?.realisedUsd;
  const unrealised = gains.data && unrealisedGains(holdings, gains.data.open, (id) => quoteFor(id)?.quote, rates.data);
  const comparison = holdingComparison(holdings, quoteFor, rates.data, unrealised?.byHolding);
  const reported = portfolioAccountValue(accounts, base, rates.data);
  const coverage = `${exposure.priced} of ${holdings.length} ${portfolio.data?.truncated ? "displayed " : ""}holdings valued`;
  const biggest = movement.contributions[0];

  return <div className="portfolio-dashboard">
    <section className="panel dashboard-summary" aria-label="Portfolio balances and gains">
      <div className="panel-heading"><h2>Portfolio balances and gains</h2>
        <div className="segmented" role="group" aria-label="Valuation currency">
          {(["USD", "AUD"] as const).map(currency => <button key={currency} type="button" aria-pressed={currency === base} onClick={() => setBase(currency)}>{currency}</button>)}
        </div>
      </div>
      {portfolio.isError && <p className="dashboard-status" role="status">Couldn’t load holdings. <button className="button secondary small" onClick={() => void portfolio.refetch()}>Retry holdings</button></p>}
      <dl className="dashboard-metrics">
        <Metric title="Open holdings value" value={exposure.priced ? money(exposure.total, base) : "—"}
          detail={portfolio.isPending || loadingPrices ? "Checking holdings and prices…" : coverage} />
        <Metric title="Realised gain or loss" value={realised == null ? "—" : signedMoney(realised, "USD")}
          detail={gains.isPending ? "Checking trades…" : gains.data ? `${gains.data.matchedSales} of ${gains.data.sales} sales fully matched${gains.data.partialSales ? ` · ${gains.data.partialSales} partly matched` : ""}` : "Ledger unavailable"} />
        <Metric title="Unrealised gain or loss" value={unrealised?.total == null ? "—" : signedMoney(unrealised.total, "USD")}
          detail={gains.isPending || portfolio.isPending || loadingPrices ? "Checking lots and prices…" : `${unrealised?.byHolding.size ?? 0} of ${holdings.length} ${portfolio.data?.truncated ? "displayed " : ""}holdings covered`} />
      </dl>
      {gains.isError && <p className="dashboard-status"><button className="button secondary small" onClick={() => void gains.refetch()}>Retry gains</button></p>}
      {exposure.assets.length > 0 && <div className="dashboard-allocation">
        <h3>Allocation of valued holdings</h3>
        <ul>{exposure.assets.map(item => <li key={item.id}><span>{item.label}</span><strong>{percent(item.weight, { signed: false, decimals: 1 })}</strong></li>)}</ul>
        <p>Oldest quote {dateTime(exposure.oldestQuote)}{exposure.fxDates.length > 0 && ` · ECB FX ${exposure.fxDates.join(", ")}`}</p>
      </div>}
      {rates.isError && <p className="dashboard-status"><button className="button secondary small" onClick={() => void rates.refetch()}>Retry exchange rates</button></p>}
      {portfolio.data?.truncated && <p className="dashboard-status">Open holdings metrics cover the first 200 displayed holdings.</p>}
      <div className="dashboard-brokerage">
        <div className="dashboard-heading-row">
          <h3>Linked brokerage accounts</h3>
          {brokerageEnabled && <div className="dashboard-actions brokerage-actions">
            <button className="button secondary small" type="button" onClick={openConnections}>Manage connections</button>
            <button className="button secondary small" type="button" aria-expanded={showAccounts} aria-controls="dashboard-brokerage"
              onClick={() => setShowAccounts(!showAccounts)}>{showAccounts ? "Hide brokerage balances" : "Show brokerage balances"}</button>
          </div>}
        </div>
        {!brokerageEnabled && <p>Brokerage access is unavailable in this deployment.</p>}
        <div id="dashboard-brokerage" hidden={!showAccounts}>
          {brokerage.isFetching && <p role="status">Checking brokerage balances…</p>}
          {brokerage.isError && <p role="status">Couldn’t refresh brokerage balances. <button className="button secondary small" onClick={() => void brokerage.refetch()}>Retry balances</button></p>}
          {brokerage.data && <>
            {accounts.length ? <>
              <dl className="dashboard-metrics dashboard-net"><Metric title="Linked brokerage net value" value={reported.total == null ? "—" : money(reported.total, base)}
                detail={`${reported.covered} of ${reported.accounts} non-paper accounts covered`} /></dl>
              <p>Uses broker-reported net values, which include cash. {reported.oldestSync && `Oldest included balance sync ${dateTime(reported.oldestSync)}.`}
                {reported.fxDates.length > 0 && ` ECB FX ${reported.fxDates.join(", ")}.`}</p>
              <ul className="dashboard-accounts">{accounts.map(account => <li key={account.id}>
                <strong>{account.label}{account.paper && " · Paper"}</strong>
                <p>{account.status === "available" ? "Connected" : account.status === "disconnected" ? "Disconnected" : "Unavailable"}
                  {account.syncedAt ? ` · Balance sync ${dateTime(account.syncedAt)}` : " · Balance sync time unavailable"}</p>
                {account.netValue && <p>Reported net value {balanceText(account.netValue.amount, account.netValue.currency)}</p>}
                {account.balances.length ? <dl>{account.balances.map(balance => <div key={balance.currency}>
                  <dt>{balance.currency}</dt><dd>Cash {balanceText(balance.amount, balance.currency)} · Buying power {balanceText(balance.buyingPower, balance.currency)}</dd>
                </div>)}</dl> : <p>Cash and buying power unavailable.</p>}
                {account.incomplete && <p>Some balances are unavailable.</p>}
              </li>)}</ul>
            </> : <p>No linked investment accounts with open status.</p>}
            <button className="button secondary small" type="button" disabled={brokerage.isFetching} onClick={() => void brokerage.refetch()}>Refresh balances</button>
          </>}
        </div>
      </div>
    </section>
    <PortfolioHistory userId={userId} portfolioLink />
    <section className="panel dashboard-intelligence" aria-label="Your Portfolio Intelligence">
      <div className="panel-heading"><h2>Your Portfolio Intelligence</h2>
        {aiEnabled && <Link className="button secondary small" href="/ai">Ask AI</Link>}
      </div>
      <div className="dashboard-intelligence-body">
        <h3>Price movement on current holdings</h3>
        {movement.totals.length ? <dl className="dashboard-moves">{movement.totals.map(([currency, value]) => <div key={currency}><dt>{currency}</dt><dd>{signedMoney(value, currency)}</dd></div>)}</dl>
          : <p>{portfolio.isPending || loadingPrices ? "Checking position prices…" : "Price movement unavailable."}</p>}
        <p>{movement.covered} of {holdings.length} {portfolio.data?.truncated ? "displayed " : ""}holdings covered. Uses previous closes for shares and provider reference prices for crypto.</p>
        {biggest && <p>Largest contribution <Link href={`/markets/${encodeURIComponent(biggest.id)}`}>{biggest.id.slice(biggest.id.indexOf(":") + 1)}</Link> {signedMoney(biggest.value, biggest.currency)} · {biggest.quote.source} · {dateTime(biggest.quote.observedAt)}</p>}
        {exposure.listings[0] && <p>Largest holding by listing <Link href={`/markets/${encodeURIComponent(exposure.listings[0].id)}`}>{exposure.listings[0].label}</Link> · {percent(exposure.listings[0].weight, { signed: false, decimals: 1 })} of valued holdings.</p>}
        {pendingApprovals !== undefined && pendingApprovals > 0 && <button type="button" className="button secondary small" onClick={openAgents}>Review {pendingApprovals} pending {pendingApprovals === 1 ? "proposal" : "proposals"}</button>}
      </div>
    </section>
    {portfolio.isSuccess && <HoldingsCard comparison={comparison} pendingQuotes={pendingQuotes}
      truncated={portfolio.data.truncated} logosEnabled={logosEnabled} gainsUnavailable={gains.isError} ratesUnavailable={rates.isError} overview />}
  </div>;
}
