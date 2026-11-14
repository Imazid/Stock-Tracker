import type { InstrumentView, QuoteResponse } from "./market-types.ts";
import { holdingValue, matchingHoldingQuote, type PortfolioReferenceRates } from "./portfolio-exposure.ts";
import type { HoldingBrokerAccount } from "./portfolio-transfers.ts";

export type PortfolioHolding = {
  id: string;
  asset_symbol: string;
  asset_name: string;
  asset_kind: "Stock" | "Crypto";
  asset_exchange: string | null;
  broker_account: HoldingBrokerAccount | null;
  shares: number;
  avg_cost: number;
  instrument: InstrumentView | null;
};

export type HoldingClass = InstrumentView["assetClass"] | "unclassified";
export type HoldingSort = "value" | "change" | "drop" | "gain" | "loss" | "symbol";

export function holdingComparison(
  holdings: readonly PortfolioHolding[],
  quoteFor: (id: string) => QuoteResponse | undefined,
  rates: PortfolioReferenceRates | undefined,
  gains: ReadonlyMap<string, number> | undefined,
) {
  let total = 0;
  let valued = 0;
  const fxDates = new Set<string>();
  const rows = holdings.map((holding) => {
    const { instrument } = holding;
    const data = instrument ? quoteFor(instrument.id) : undefined;
    const quote = matchingHoldingQuote(instrument, data?.quote);
    const listing = data && data.instrument.id === instrument?.id ? data.instrument : instrument;
    const { local, converted, fxDate } = quote ? holdingValue(holding.shares, quote, "USD", rates) : {};
    const value = converted !== undefined && Number.isFinite(total + converted) ? converted : undefined;
    if (value !== undefined) {
      total += value;
      valued++;
      if (fxDate) fxDates.add(fxDate);
    }
    const change = quote && Number.isFinite(quote.changePct) ? quote.changePct : undefined;
    return {
      holding, quote, local, value, change,
      currentChange: quote?.stale ? undefined : change,
      gain: gains?.get(holding.id),
      assetClass: listing?.assetClass ?? "unclassified",
      symbol: instrument?.symbol ?? holding.asset_symbol,
      name: holding.asset_name || listing?.name || holding.asset_symbol,
      venue: instrument?.venueShort ?? holding.asset_exchange,
    } as const;
  });
  return {
    rows: rows.map((row) => ({ ...row, weight: row.value === undefined ? undefined : row.value / total * 100 })),
    valued, fxDates: [...fxDates].sort(),
  };
}

export type HoldingComparisonRow = ReturnType<typeof holdingComparison>["rows"][number];

export function findHoldings(
  rows: readonly HoldingComparisonRow[],
  search: string,
  assetClass: HoldingClass | "all",
  sort: HoldingSort,
) {
  const terms = search.trim().toLowerCase().split(/\s+/).filter(Boolean);
  return rows.filter(({ holding, symbol, name, venue, assetClass: kind }) => {
    if (assetClass !== "all" && kind !== assetClass) return false;
    const text = [symbol, holding.asset_symbol, name, venue, holding.asset_exchange, holding.broker_account?.label].join(" ").toLowerCase();
    return terms.every((term) => text.includes(term));
  }).sort((a, b) => {
    const bySymbol = a.symbol.localeCompare(b.symbol) || (a.venue ?? "").localeCompare(b.venue ?? "") ||
      (a.holding.broker_account?.label ?? "").localeCompare(b.holding.broker_account?.label ?? "") || a.holding.id.localeCompare(b.holding.id);
    if (sort === "symbol") return bySymbol;
    const metric = sort === "change" || sort === "drop" ? "currentChange" : sort === "loss" ? "gain" : sort;
    const left = a[metric], right = b[metric];
    if (left === undefined) return right === undefined ? bySymbol : 1;
    if (right === undefined) return -1;
    return (sort === "loss" || sort === "drop" ? left - right : right - left) || bySymbol;
  });
}
