import { lotUnits } from "./lot-numbers.ts";
import type { InstrumentView, QuoteView } from "./market-types";
import type { PortfolioReferenceRates } from "./portfolio-exposure";

export type OpenCost = { units: string; costUsd: number | null; lastSplit?: string };
export type PortfolioGains = {
  owner: string;
  asOf: string;
  realisedUsd: number | null;
  sales: number;
  matchedSales: number;
  partialSales: number;
  feesUsd: number | null;
  tradeRecords: number;
  feeRecords: number;
  archivedLots: number;
  pendingTransfers: number;
  open: Record<string, OpenCost>;
};

type Holding = { id: string; shares: number; instrument: InstrumentView | null };

export function unrealisedGains(
  holdings: readonly Holding[],
  open: Readonly<Record<string, OpenCost>>,
  quoteFor: (id: string) => QuoteView | undefined,
  rates: PortfolioReferenceRates | undefined,
) {
  const fxDates = new Set<string>();
  const byHolding = new Map<string, number>();
  const sydney = new Intl.DateTimeFormat("sv-SE", { timeZone: "Australia/Sydney", dateStyle: "short" });
  let total = 0;
  let basisMissing = 0;
  let pricesMissing = 0;
  let fxMissing = 0;
  let oldestQuote: string | undefined;
  for (const { id, shares, instrument } of holdings) {
    const basis = open[id];
    const units = basis ? lotUnits(basis.units) : undefined;
    const position = lotUnits(shares);
    // The synced position is a double. Allow conversion noise from fractional
    // fills and split ratios while still requiring the quantities to reconcile.
    if (!basis || !units || !position || basis.costUsd === null || !Number.isFinite(basis.costUsd) ||
        Math.abs(Number(units - position)) > Math.max(1, Number(position) * Number.EPSILON * 32)) {
      basisMissing++;
      continue;
    }
    const quote = instrument ? quoteFor(instrument.id) : undefined;
    const observed = Date.parse(quote?.observedAt ?? "");
    if (!instrument || !quote || quote.instrumentId !== instrument.id || quote.currency !== instrument.currency ||
        quote.stale || !Number.isFinite(quote.last) || quote.last <= 0 || !Number.isFinite(observed) ||
        (basis.lastSplit && sydney.format(observed) < basis.lastSplit)) {
      pricesMissing++;
      continue;
    }
    const fx = quote.currency === "USD" ? undefined : rates?.USD[quote.currency];
    const rate = quote.currency === "USD" ? 1 : Number(fx?.rate);
    if (!Number.isFinite(rate) || rate <= 0) {
      fxMissing++;
      continue;
    }
    const gain = shares * quote.last * rate - basis.costUsd;
    if (!Number.isFinite(gain) || !Number.isFinite(total + gain)) {
      pricesMissing++;
      continue;
    }
    total += gain;
    byHolding.set(id, gain);
    const iso = new Date(observed).toISOString();
    if (!oldestQuote || iso < oldestQuote) oldestQuote = iso;
    if (fx) fxDates.add(fx.date);
  }
  return { total: byHolding.size ? total : null, byHolding, basisMissing, pricesMissing, fxMissing, oldestQuote, fxDates: [...fxDates].sort() };
}
