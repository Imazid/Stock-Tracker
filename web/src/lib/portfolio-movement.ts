import type { QuoteView } from "./market-types";

type Holding = { shares: number; instrument: { id: string; currency: string } };
type Contribution = {
  id: string;
  value: number;
  currency: string;
  quote: QuoteView;
};

export function portfolioMovement(holdings: readonly Holding[], quoteFor: (id: string) => QuoteView | undefined) {
  const byInstrument = new Map<string, Contribution>();
  let covered = 0;
  for (const { shares, instrument } of holdings) {
    const quote = quoteFor(instrument.id);
    const baseline = quote?.previousClose;
    if (!quote || quote.stale || quote.instrumentId !== instrument.id || quote.currency !== instrument.currency ||
        !Number.isFinite(Date.parse(quote.observedAt)) || !Number.isFinite(shares) || shares <= 0 ||
        !Number.isFinite(quote.last) || quote.last <= 0 || baseline === undefined || !Number.isFinite(baseline) || baseline <= 0) continue;
    const value = (quote.last - baseline) * shares;
    if (!Number.isFinite(value)) continue;
    const prior = byInstrument.get(instrument.id);
    byInstrument.set(instrument.id, { id: instrument.id, value: value + (prior?.value ?? 0), currency: quote.currency, quote });
    covered++;
  }
  const totals = new Map<string, number>();
  for (const item of byInstrument.values()) {
    totals.set(item.currency, (totals.get(item.currency) ?? 0) + item.value);
  }
  return {
    covered,
    totals: [...totals.entries()].sort(([left], [right]) => left.localeCompare(right)),
    contributions: [...byInstrument.values()].sort((left, right) => Math.abs(right.value) - Math.abs(left.value)),
  };
}
