import { dayKey, coversDate, isTradingDay } from "../trading/calendar.ts";
import { makeInstrument, type Venue } from "../trading/market.ts";
import { ecbRate, ecbURL, offsetDay, parseECBObservations, validISODay } from "../fx/ecb.ts";
import { BENCHMARK_MAX_DAYS, type PortfolioBenchmark, type PortfolioBenchmarkResult } from "./benchmark_types.ts";
import { YahooFinanceProvider } from "../market/yahoo.ts";
import { ProviderError } from "../market/provider.ts";

const instruments = { SPY: makeInstrument("SPY", "etf", "us"), STW: makeInstrument("STW", "etf", "asx") };
const firstSession = { SPY: "1993-01-22", STW: "2001-08-27" };
const sourceUrls = { SPY: "https://finance.yahoo.com/quote/SPY/history/", STW: "https://finance.yahoo.com/quote/STW.AX/history/" };
type Close = { time: number; close: number };
type Rate = { date: string; rate: string };
const maxGap = 7;
const instant = (day: string) => Date.parse(day + "T12:00:00Z");
const cache = new Map<string, { expires: number; result: Promise<PortfolioBenchmarkResult | null> }>();

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

export async function yahooAdjustedCloses(instrument: typeof instruments.SPY, start: number, end: number) {
  try {
    return await new YahooFinanceProvider({ maxAttempts: 1 }).adjustedCloses(instrument, start, end);
  } catch (error) {
    if (!(error instanceof ProviderError) || (!error.retryable && error.status !== 401 && error.status !== 403)) throw error;
    return new YahooFinanceProvider({ baseURL: "https://query2.finance.yahoo.com", maxAttempts: 1 }).adjustedCloses(instrument, start, end);
  }
}

async function benchmarkRates(start: string, end: string, request = fetch): Promise<(Rate | undefined)[]> {
  const currencies = ["AUD", "USD"];
  const from = offsetDay(start, -maxGap);
  const response = await request(ecbURL(currencies, from, end), {
    redirect: "error", signal: AbortSignal.timeout(24_000),
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
    source: "Yahoo Finance (unofficial)", sourceUrl: sourceUrls[id],
  };
}

export function cachedPortfolioBenchmark(id: PortfolioBenchmark, start: string, end: string, now = Date.now()) {
  const key = `${id}:${start}:${end}`;
  const hit = cache.get(key);
  if (hit && hit.expires > now) return hit.result;
  cache.delete(key);
  if (cache.size >= 128) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  const result = portfolioBenchmark(id, start, end, now);
  cache.set(key, { expires: now + 600_000, result });
  result.catch(() => { if (cache.get(key)?.result === result) cache.delete(key); });
  return result;
}
