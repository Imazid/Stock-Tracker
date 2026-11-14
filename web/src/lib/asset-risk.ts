import { MarketCalendar } from "../../../supabase/functions/_shared/trading/calendar.ts";
import { measureStats } from "../../../supabase/functions/_shared/trading/market.ts";
import type { CandlesView } from "./market-types.ts";

export const ASSET_RISK_RANGES = ["3M", "6M", "1Y"] as const;
export type AssetRiskRange = (typeof ASSET_RISK_RANGES)[number];

const VOLATILITY_SESSIONS = 20;
const RANGE_DAYS: Record<AssetRiskRange, number> = { "3M": 92, "6M": 183, "1Y": 366 };
const DAY_MS = 86_400_000;

export function assetRisk(history: CandlesView, now: number) {
  if (history.interval !== "1d" || history.intraday) return undefined;
  const range = history.range as AssetRiskRange;
  if (!ASSET_RISK_RANGES.includes(range)) return undefined;
  const venue = history.instrument.venue;
  const cutoff = Math.min(now, Date.parse(history.fetchedAt));
  if (!Number.isFinite(cutoff)) return undefined;

  // Evaluate completeness when the feed was fetched. A cached intraday update
  // remains an incomplete daily bar even after the exchange has since closed.
  const closes = new Map<string, { time: number; close: number }>();
  const duplicates = new Set<string>();
  for (const { time, close } of history.candles) {
    const timestamp = time * 1000;
    if (!Number.isFinite(timestamp) || timestamp < cutoff - (RANGE_DAYS[range] + 1) * DAY_MS || timestamp >= cutoff ||
      !Number.isFinite(close) || close <= 0) continue;
    const session = MarketCalendar.session(venue, timestamp);
    if (!session || session.end > cutoff) continue;
    const date = MarketCalendar.dayKey(venue, timestamp);
    if (closes.has(date)) duplicates.add(date);
    closes.set(date, { time: timestamp, close });
  }
  for (const date of duplicates) closes.delete(date);
  const bars = [...closes.entries()].sort(([left], [right]) => left.localeCompare(right));
  if (bars.length < 2) return undefined;

  const [from, first] = bars[0];
  const [through, last] = bars[bars.length - 1];
  const today = MarketCalendar.dayKey(venue, now);
  const currentSession = MarketCalendar.session(venue, now);
  const alreadyClosed = currentSession !== undefined && currentSession.end <= now;
  const missedRecentSessions = through === today ? 0 : Math.max(0,
    MarketCalendar.tradingDays(venue, last.time, now) - 1 + Number(alreadyClosed));

  let peak = first.close;
  let peakDate = from;
  let missingSessions = 0;
  let lastGap = 0;
  let maxDrawdownPct = 0;
  let drawdownPeakDate = from;
  let drawdownTroughDate = from;
  for (let index = 1; index < bars.length; index++) {
    const [date, bar] = bars[index];
    const gap = MarketCalendar.tradingDays(venue, bars[index - 1][1].time, bar.time) - 1;
    if (gap > 0) {
      missingSessions += gap;
      lastGap = index;
    }
    if (bar.close >= peak) {
      peak = bar.close;
      peakDate = date;
    }
    const decline = (1 - bar.close / peak) * 100;
    if (decline > maxDrawdownPct) {
      maxDrawdownPct = decline;
      drawdownPeakDate = peakDate;
      drawdownTroughDate = date;
    }
  }

  const volatilityBars = bars.slice(Math.max(lastGap, bars.length - VOLATILITY_SESSIONS - 1));
  const volatility = measureStats(volatilityBars.map(([, { time, close }]) => ({
    time, open: close, high: close, low: close, close, volume: 0,
  })), VOLATILITY_SESSIONS)?.dailyVolatilityPct;
  const dailyVolatilityPct = volatility !== undefined && Number.isFinite(volatility) ? volatility : null;
  const priceChange = (last.close / first.close - 1) * 100;
  return {
    instrumentId: history.instrument.id,
    range,
    currency: history.currency,
    source: history.source,
    status: history.status,
    adjustment: history.adjustment,
    fetchedAt: history.fetchedAt,
    from,
    through,
    sessions: bars.length,
    missingSessions,
    missedRecentSessions,
    calendarCovered: MarketCalendar.coversDate(venue, first.time) && MarketCalendar.coversDate(venue, now),
    priceChangePct: Number.isFinite(priceChange) ? priceChange : null,
    maxDrawdownPct,
    drawdownPeakDate,
    drawdownTroughDate,
    dailyVolatilityPct,
    volatilityFrom: dailyVolatilityPct === null ? null : volatilityBars[0][0],
  };
}

export type AssetRisk = NonNullable<ReturnType<typeof assetRisk>>;
