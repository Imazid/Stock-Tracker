import Link from "next/link";
import { dateTime, money, percent } from "@/lib/format";
import type { PortfolioRiskSummary } from "@/server/portfolio/risk";

const weight = (value: number) => percent(value, { signed: false, decimals: 1 });

export function PortfolioRiskAnswer({ risk }: { risk: PortfolioRiskSummary }) {
  const incomplete = risk.holdingsTruncated || risk.holdingsValued < risk.holdingsChecked;
  const title = "Risk in your current holdings";
  return <section aria-label={title} className="space-y-3 rounded-lg border border-border bg-surface-2 p-3 text-[13px]">
    <h3 className="font-semibold">{title}</h3>
    <p className="text-text-2">
      {risk.holdingsValued} of {risk.holdingsChecked} checked holdings valued across your synced portfolios.
      {incomplete ? " Coverage is partial." : ""}
      {risk.holdingsTruncated ? " The review checks up to 200 holdings." : ""}
      {risk.unquotedListings > 0 ? ` ${risk.unquotedListings} listings were beyond the quote limit.` : ""}
      {risk.unresolvedHoldings > 0 ? ` ${risk.unresolvedHoldings} holdings could not be matched to a listing.` : ""}
      {risk.missingRates > 0 ? ` Exchange rates were unavailable for ${risk.missingRates} holdings.` : ""}
    </p>
    {!risk.top.length ? <p className="text-text-2">
      {risk.holdingsChecked ? "No usable holding values are available yet." : "Add or sync holdings to see portfolio risks."}
    </p> : <>
      <dl className="grid grid-cols-2 gap-2">
        <div><dt className="text-text-2">Covered value</dt><dd className="tabular font-medium">{money(risk.total, risk.currency)}</dd></div>
        <div><dt className="text-text-2">{risk.top.length === 1 ? "Largest listing weight" : `Top ${Math.min(3, risk.top.length)} listings`}</dt>
          <dd className="tabular font-medium">{weight(risk.topThreeWeight)}</dd></div>
      </dl>
      <div className="border-t border-border pt-2">
        <h4 className="mb-1 font-medium">Largest listing weights</h4>
        <ul className="space-y-2">
          {risk.top.map((row) => <li key={row.id}>
            <div className="flex justify-between gap-2">
              <Link href={`/markets/${encodeURIComponent(row.id)}`} className="break-all text-primary-fg underline">{row.symbol} · {row.venue}</Link>
              <span className="shrink-0 tabular">{weight(row.weight)}</span>
            </div>
            <p className="text-xs text-text-2">{row.source} · {row.status.replace("_", " ")} · {dateTime(row.observedAt)}</p>
          </li>)}
        </ul>
      </div>
      <div className="border-t border-border pt-2">
        <h4 className="mb-1 font-medium">Quote currency</h4>
        <ul className="flex flex-wrap gap-x-4 gap-y-1">
          {risk.quoteCurrencies.map((row) => <li key={row.id} className="tabular">{row.label} {weight(row.weight)}</li>)}
        </ul>
        <p className="mt-1 text-xs text-text-2">Weights reflect the currencies used to price holdings. Issuer revenue and currency hedges can change actual FX sensitivity.</p>
      </div>
      <div className="border-t border-border pt-2">
        <h4 className="mb-1 font-medium">Largest classified sector</h4>
        {risk.largestSector ? <p>{risk.largestSector.label} · {weight(risk.largestSector.weight)}</p> : <p>Sector classification unavailable.</p>}
        <p className="text-xs text-text-2">
          SIC classifications cover {weight(risk.sectorCoverageWeight)} of valued holdings. Fund constituents and crypto are outside the SIC breakdown.
          {risk.issuerLookupsLimited ? " Some issuer records are temporarily unavailable." : ""}
        </p>
        {risk.sectorSources.length > 0 && <details className="mt-1 text-xs">
          <summary className="cursor-pointer text-primary-fg">Sector sources</summary>
          <ul className="space-y-1">
            {risk.sectorSources.map(row => <li key={row.id}>
              <a className="text-primary-fg underline" href={row.url} target="_blank" rel="noreferrer">{row.issuer} · SEC</a>
              {row.observedAt && ` · ${row.observedAt.slice(0, 10)}`}
            </li>)}
          </ul>
        </details>}
      </div>
      <div className="border-t border-border pt-2">
        <h4 className="mb-1 font-medium">Recent drawdowns in the largest listings</h4>
        <ul className="space-y-2">
          {risk.recentPriceRisk.map(({ id, symbol, venue, risk: history }) => <li key={id}>
            <Link href={`/markets/${encodeURIComponent(id)}#asset-risk`} className="text-primary-fg underline">{symbol} · {venue}</Link>
            {" · "}{history ? percent(-history.maxDrawdownPct, { signed: false, decimals: 2 }) : "History unavailable"}
            {history && <p className="text-xs text-text-2">
              {history.from} to {history.through} · {history.source}
              {history.missingSessions + history.missedRecentSessions > 0 ? " · Some expected closes are missing" : ""}
            </p>}
          </li>)}
        </ul>
      </div>
      <p className="text-xs text-text-2">
        Weights use current open holdings valued in AUD and exclude cash.
        {risk.fxDates.length > 0 ? ` ECB exchange rates observed ${risk.fxDates.join(", ")}.` : ""}
      </p>
    </>}
    <Link href="/portfolio" className="text-primary-fg underline">Open Portfolio</Link>
  </section>;
}
