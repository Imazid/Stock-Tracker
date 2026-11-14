import type { QuoteView } from "../../lib/market-types.ts";
import type { CompanyAlert } from "../../lib/research-alert-types.ts";

export interface AlertEvent {
  event_key: string;
  title: string;
  url?: string;
  occurred_at: string;
}

export type Evaluation = {
  condition: boolean | null;
  observedAt?: string;
  events: AlertEvent[];
  problem: string | null;
};

type Rule = Pick<CompanyAlert, "kind" | "threshold" | "currency" | "created_at"> & {
  instrument_id: string;
  last_condition: boolean | null;
  last_observed_at: string | null;
};

export function evaluateQuoteAlert(rule: Rule, quote: QuoteView, now: number): Evaluation {
  const observed = Date.parse(quote.observedAt);
  const previous = rule.last_observed_at ? Date.parse(rule.last_observed_at) : -Infinity;
  const threshold = Number(rule.threshold);
  const isVolume = rule.kind === "volume_above";
  const value = isVolume ? (quote.volumeScope === "consolidated" ? quote.volume : undefined)
    : quote.currency === rule.currency ? quote.last : undefined;
  if (quote.instrumentId !== rule.instrument_id || quote.stale || !Number.isFinite(observed) || observed > now ||
    now - observed > 3 * 86_400_000 || value === undefined || !Number.isFinite(value) || value < 0 ||
    (!isVolume && value === 0) || !Number.isFinite(threshold) || threshold <= 0) {
    return { condition: null, events: [], problem: "A recent observation in the required currency or volume coverage is unavailable." };
  }
  if (observed < Date.parse(rule.created_at) || observed <= previous) return { condition: null, events: [], problem: null };
  const condition = rule.kind === "price_below" ? value <= threshold : value >= threshold;
  const symbol = rule.instrument_id.split(":")[1];
  const events = condition && rule.last_condition !== true ? [{
    event_key: `${rule.kind}:${quote.observedAt}`,
    title: `${symbol} ${isVolume ? "volume" : "price"} reached ${value} ${isVolume ? "shares" : quote.currency} (${quote.source}, ${quote.status.replaceAll("_", " ")})`,
    occurred_at: quote.observedAt,
  }] : [];
  return { condition, observedAt: quote.observedAt, events, problem: null };
}
