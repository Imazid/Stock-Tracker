import { dayKey, coversDate, isTradingDay } from "../../../../supabase/functions/_shared/trading/calendar.ts";
import { makeInstrument, type Venue } from "../../../../supabase/functions/_shared/trading/market.ts";
import { ecbRate, ecbURL, offsetDay, parseECBObservations, validISODay } from "../../../../supabase/functions/_shared/fx/ecb.ts";
import { BENCHMARK_MAX_DAYS, type PortfolioBenchmark, type PortfolioBenchmarkResult } from "../../lib/portfolio-benchmark.ts";
import { cached } from "../market/cache.ts";
import { yahooAdjustedCloses, YAHOO_SOURCE } from "../market/yahoo.ts";

const instruments = { SPY: makeInstrument("SPY", "etf", "us"), STW: makeInstrument("STW", "etf", "asx") };
const firstSession = { SPY: "1993-01-22", STW: "2001-08-27" };
const sourceUrls = { SPY: "https://finance.yahoo.com/quote/SPY/history/", STW: "https://finance.yahoo.com/quote/STW.AX/history/" };
type Close = { time: number; close: number };
type Rate = { date: string; rate: string };
const maxGap = 7;
const instant = (day: string) => Date.parse(day + "T12:00:00Z");

export function validBenchmarkPeriod(start: string, end: string) {
  return validISODay(start) && validISODay(end) && start >= "1900-01-01" && start < end
    && instant(end) - instant(start) <= BENCHMARK_MAX_DAYS * 86_400_000;
}

export function benchmarkBoundary(venue: Venue, closes: ReadonlyMap<string, number>, day: string) {
  for (let offset = 0; offset <= maxGap; offset++) {
    const session = offsetDay(day, -offset);
    const date = instant(session);
    const known = coversDate(venue, date);
    const close = closes.get(session);
    if (close && Number.isFinite(close) && close > 0) return { session, close };
    if (known && isTradingDay(venue, date)) return undefined;
  }
}

export function benchmarkReturn(open: number, close: number, openingRate = 1, closingRate = 1) {
  if (![open, close, openingRate, closingRate].every((value) => Number.isFinite(value) && value > 0)) return undefined;
  const result = ((close * closingRate) / (open * openingRate) - 1) * 100;
  return Number.isFinite(result) ? result : undefined;
}

async function benchmarkRates(start: string, end: string, request = fetch): Promise<(Rate | undefined)[]> {
  const currencies = ["AUD", "USD"];
  const from = offsetDay(start, -maxGap);
  const response = await request(ecbURL(currencies, from, end), {
    redirect: "error", signal: AbortSignal.timeout(24_000), next: { revalidate: 3600 },
  });
  if (response.status === 204 || response.status === 404) return [];
  if (!response.ok) throw new Error("ECB benchmark rates are unavailable");
  const csv = await response.text();
  const observations = csv.length <= 600_000 && parseECBObservations(csv, currencies, from, end);
  if (!observations) throw new Error("ECB benchmark rates are unreadable");
  return [start, end].map((day) => ecbRate(observations, "AUD", "USD", day));
}

export async function portfolioBenchmark(
  id: PortfolioBenchmark, start: string, end: string, now = Date.now(),
  deps: { closes: (instrument: typeof instruments.SPY, start: number, end: number) => Promise<Close[]>; rates: typeof benchmarkRates } =
    { closes: yahooAdjustedCloses, rates: benchmarkRates },
): Promise<PortfolioBenchmarkResult | null> {
  const instrument = instruments[id];
  // The venue's current day can contain a forming bar. Compare completed calendar dates.
  if (start < firstSession[id] || end >= dayKey(instrument.venue, now)) return null;
  const [closes, rates] = await Promise.all([
    deps.closes(instrument, Date.parse(offsetDay(start, -maxGap)), Date.parse(offsetDay(end, 2))),
    id === "STW" ? deps.rates(start, end) : Promise.resolve([]),
  ]);
  const daily = new Map(closes.map(({ time, close }) => [dayKey(instrument.venue, time), close]));
  const opening = benchmarkBoundary(instrument.venue, daily, start);
  const closing = benchmarkBoundary(instrument.venue, daily, end);
  if (!opening || !closing) return null;
  const [openingRate, closingRate] = rates;
  if (id === "STW" && (!openingRate || !closingRate)) return null;
  const returnPct = benchmarkReturn(opening.close, closing.close,
    openingRate ? Number(openingRate.rate) : 1, closingRate ? Number(closingRate.rate) : 1);
  if (returnPct === undefined) return null;
  return {
    returnPct, start: { session: opening.session, fxDate: openingRate?.date }, end: { session: closing.session, fxDate: closingRate?.date },
    source: YAHOO_SOURCE, sourceUrl: sourceUrls[id],
  };
}

export function cachedPortfolioBenchmark(id: PortfolioBenchmark, start: string, end: string) {
  return cached(`portfolio-benchmark:${id}:${start}:${end}`, 600_000, () => portfolioBenchmark(id, start, end));
}
