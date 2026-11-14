// Routing: which source answers for which listing, with fallbacks, and the freshness
// verdict on every answer. Nothing here invents a number: when every source fails the
// caller gets an error with the reasons, and the page says the price isn't available.

import { catalogInstruments } from "@engine/catalog.ts";
import { MarketCalendar } from "@engine/calendar.ts";
import { type Instrument, instrumentID, makeInstrument } from "@engine/market.ts";
import type {
  CandlesView,
  ChartRange,
  InstrumentResponse,
  QuoteResponse,
  QuoteView,
  SearchResponse,
  SearchResult,
} from "@/lib/market-types";
import { ALPACA_CRYPTO_SOURCE, ALPACA_IEX_SOURCE, alpacaCandles, alpacaConfigured, alpacaQuote, alpacaSupports } from "./alpaca";
import { cached } from "./cache";
import { COIN_NAMES, COINGECKO_IDS, COINGECKO_SOURCE, coinGeckoQuote } from "./coingecko";
import { decodeSearch, researchSearch } from "@/server/research/search";
import { UpstreamError } from "./http";
import { marketState, toView } from "./instruments";
import { YAHOO_SOURCE, yahooChart, yahooQuote, yahooSearch, yahooVolumeScope } from "./yahoo";

export class NoDataError extends Error {
  constructor(message: string, readonly reasons: string[]) {
    super(message);
    this.name = "NoDataError";
  }
}

const reason = (error: unknown): string => (error instanceof UpstreamError ? error.message : "The request failed");

/** Freshness: an old price is labelled stale, never shown as current. */
function staleness(instrument: Instrument, observedAt: number, delayMinutes: number | undefined, now: number): { stale: boolean; reason?: string } {
  const ageMin = (now - observedAt) / 60_000;
  if (instrument.venue === "crypto") {
    return ageMin > 15 ? { stale: true, reason: `Last update was ${Math.round(ageMin)} minutes ago` } : { stale: false };
  }
  const open = MarketCalendar.isOpen(instrument.venue, now);
  if (!open) return { stale: false };
  // Unknown delay: allow for the common 20-minute exchange delay (ASX via Yahoo runs ~20 min behind).
  const allowed = 15 + (delayMinutes ?? 20);
  if (ageMin > allowed) return { stale: true, reason: `The market is open but the last price is ${Math.round(ageMin)} minutes old` };
  return { stale: false };
}

/** Yahoo is unofficial: crypto there is an aggregate (indicative); equities count as delayed
 * unless Yahoo itself says the feed has no delay. */
function yahooStatus(instrument: Instrument, delayMinutes: number | undefined): QuoteView["status"] {
  if (instrument.venue === "crypto") return "indicative";
  return delayMinutes === 0 ? "real_time" : "delayed";
}

function withChange(q: Pick<QuoteView, "last" | "previousClose">): { change?: number; changePct?: number } {
  if (q.previousClose === undefined || !(q.previousClose > 0)) return {};
  const change = q.last - q.previousClose;
  return { change, changePct: (change / q.previousClose) * 100 };
}

async function quoteFromSources(instrument: Instrument, now: number): Promise<QuoteView & { isEtf?: boolean }> {
  const reasons: string[] = [];
  const id = instrumentID(instrument);
  const fetchedAt = new Date(now).toISOString();

  if (instrument.venue === "crypto") {
    if (COINGECKO_IDS[instrument.symbol]) {
      try {
        const q = await coinGeckoQuote(instrument);
        const s = staleness(instrument, q.observedAt, undefined, now);
        const previousClose = q.changePct !== undefined ? q.last / (1 + q.changePct / 100) : undefined;
        return {
          instrumentId: id, last: q.last, previousClose,
          change: previousClose !== undefined ? q.last - previousClose : undefined,
          changePct: q.changePct,
          volume: q.volume24hUSD, volumeScope: "aggregate",
          currency: "USD", source: COINGECKO_SOURCE, observedAt: new Date(q.observedAt).toISOString(), fetchedAt,
          status: "indicative", stale: s.stale, staleReason: s.reason,
          notes: ["Change is over the last 24 hours (crypto has no daily close).", "Volume is 24-hour USD volume across exchanges."],
        };
      } catch (error) {
        reasons.push(`CoinGecko: ${reason(error)}`);
      }
    }
    if (alpacaSupports(instrument)) {
      try {
        const q = await alpacaQuote(instrument);
        const s = staleness(instrument, q.observedAt, 0, now);
        return {
          instrumentId: id, last: q.last, previousClose: q.previousClose, ...withChange(q), bid: q.bid, ask: q.ask,
          dayHigh: q.dayHigh, dayLow: q.dayLow, volumeScope: "single_venue", currency: "USD", source: ALPACA_CRYPTO_SOURCE,
          observedAt: new Date(q.observedAt).toISOString(), fetchedAt, status: "real_time", stale: s.stale, staleReason: s.reason,
          notes: ["Price from one US crypto venue."],
        };
      } catch (error) {
        reasons.push(`Alpaca: ${reason(error)}`);
      }
    }
  } else if (instrument.venue === "us" && alpacaConfigured()) {
    try {
      const q = await alpacaQuote(instrument);
      const s = staleness(instrument, q.observedAt, 0, now);
      return {
        instrumentId: id, last: q.last, previousClose: q.previousClose, ...withChange(q), bid: q.bid, ask: q.ask,
        dayHigh: q.dayHigh, dayLow: q.dayLow, volumeScope: "single_venue", currency: "USD", source: ALPACA_IEX_SOURCE,
        observedAt: new Date(q.observedAt).toISOString(), fetchedAt, status: "real_time", stale: s.stale, staleReason: s.reason,
        notes: ["Last trade on IEX, a single US exchange. Day range is IEX-only."],
      };
    } catch (error) {
      reasons.push(`Alpaca: ${reason(error)}`);
    }
  }

  try {
    const q = await yahooQuote(instrument);
    const currency = q.currency ?? instrument.currency;
    const s = staleness(instrument, q.observedAt, q.delayMinutes, now);
    const notes: string[] = [];
    if (currency !== instrument.currency) notes.push(`Quoted in ${currency}, not the venue's usual ${instrument.currency}.`);
    if (instrument.venue === "crypto") notes.push("Change is since 00:00 UTC.");
    return {
      instrumentId: id, last: q.last, previousClose: q.previousClose, ...withChange(q), dayHigh: q.dayHigh, dayLow: q.dayLow,
      volume: q.volume, volumeScope: yahooVolumeScope(instrument), currency, source: YAHOO_SOURCE,
      observedAt: new Date(q.observedAt).toISOString(), fetchedAt,
      status: yahooStatus(instrument, q.delayMinutes),
      delayMinutes: q.delayMinutes, stale: s.stale, staleReason: s.reason, isEtf: q.isEtf,
      notes: q.delayMinutes === undefined && instrument.venue !== "crypto" ? [...notes, "Yahoo doesn't state this feed's delay, so it's treated as delayed."] : notes,
    };
  } catch (error) {
    reasons.push(`Yahoo: ${reason(error)}`);
  }
  throw new NoDataError("No source could price this right now.", reasons);
}

export async function getQuote(instrument: Instrument): Promise<QuoteResponse> {
  const now = Date.now();
  const { isEtf, ...quote } = await cached(`quote:${instrumentID(instrument)}`, 10_000, () => quoteFromSources(instrument, now));
  // Re-judge freshness at read time: a cached answer can age past the line.
  const s = staleness(instrument, Date.parse(quote.observedAt), quote.delayMinutes, Date.now());
  const listing = isEtf && instrument.assetClass === "equity" ? { ...instrument, assetClass: "etf" as const } : instrument;
  return { instrument: toView(listing), quote: { ...quote, stale: s.stale, staleReason: s.reason }, market: marketState(instrument.venue, now) };
}

const CANDLE_TTL: Record<ChartRange, number> = { "1D": 30_000, "5D": 60_000, "1M": 120_000, "3M": 600_000, "6M": 600_000, "1Y": 900_000, "5Y": 3_600_000 };

function lastSessionOnly(instrument: Instrument, candles: CandlesView["candles"]): CandlesView["candles"] {
  if (instrument.venue === "crypto" || candles.length === 0) return candles;
  const lastDay = MarketCalendar.dayKey(instrument.venue, candles[candles.length - 1].time * 1000);
  return candles.filter((c) => MarketCalendar.dayKey(instrument.venue, c.time * 1000) === lastDay);
}

async function candlesFromSources(instrument: Instrument, range: ChartRange, now: number): Promise<CandlesView> {
  const reasons: string[] = [];
  const intraday = range === "1D" || range === "5D" || range === "1M";
  const fetchedAt = new Date(now).toISOString();
  const base = { instrument: toView(instrument), range, intraday, fetchedAt, market: marketState(instrument.venue, now) };

  // US candles prefer Yahoo for consolidated volume; Alpaca IEX is the fallback.
  try {
    const chart = await yahooChart(instrument, range);
    let candles = chart.candles;
    if (range === "1D") candles = lastSessionOnly(instrument, candles);
    if (candles.length === 0) throw new UpstreamError("Yahoo Finance returned no bars for that range", 404);
    const currency = chart.currency ?? instrument.currency;
    const notes: string[] = [];
    if (currency !== instrument.currency) notes.push(`Prices are in ${currency}, not the venue's usual ${instrument.currency}.`);
    return {
      ...base,
      interval: (yahooIntervalLabel(range)),
      candles, currency, source: YAHOO_SOURCE,
      status: yahooStatus(instrument, chart.delayMinutes),
      delayMinutes: chart.delayMinutes,
      observedAt: new Date(candles[candles.length - 1].time * 1000).toISOString(),
      adjustment: "Split-adjusted (not dividend-adjusted)",
      volumeScope: yahooVolumeScope(instrument), notes,
    };
  } catch (error) {
    reasons.push(`Yahoo: ${reason(error)}`);
  }

  if (alpacaSupports(instrument)) {
    try {
      const { candles: raw, interval } = await alpacaCandles(instrument, range, now);
      const candles = range === "1D" ? lastSessionOnly(instrument, raw) : raw;
      if (candles.length === 0) throw new UpstreamError("Alpaca returned no bars for that range", 404);
      return {
        ...base, interval, candles, currency: "USD",
        source: instrument.venue === "crypto" ? ALPACA_CRYPTO_SOURCE : ALPACA_IEX_SOURCE,
        status: "real_time",
        observedAt: new Date(candles[candles.length - 1].time * 1000).toISOString(),
        adjustment: instrument.venue === "crypto" ? "None (crypto)" : "Split- and dividend-adjusted",
        volumeScope: "single_venue",
        notes: [instrument.venue === "crypto" ? "Volume is one US crypto venue's." : "Volume is IEX only — a small slice of US trading."],
      };
    } catch (error) {
      reasons.push(`Alpaca: ${reason(error)}`);
    }
  }
  throw new NoDataError("No source has a chart for this right now.", reasons);
}

function yahooIntervalLabel(range: ChartRange): string {
  return { "1D": "5m", "5D": "15m", "1M": "1h", "3M": "1d", "6M": "1d", "1Y": "1d", "5Y": "1wk" }[range];
}

export async function getCandles(instrument: Instrument, range: ChartRange): Promise<CandlesView> {
  const now = Date.now();
  const view = await cached(`candles:${instrumentID(instrument)}:${range}`, CANDLE_TTL[range], () => candlesFromSources(instrument, range, now));
  return { ...view, market: marketState(instrument.venue, Date.now()) };
}

export function describeInstrument(instrument: Instrument): InstrumentResponse {
  const quotes: string[] = [];
  const candles: string[] = [];
  if (instrument.venue === "crypto") {
    if (COINGECKO_IDS[instrument.symbol]) quotes.push(COINGECKO_SOURCE);
    if (alpacaConfigured()) quotes.push(ALPACA_CRYPTO_SOURCE);
  } else if (instrument.venue === "us" && alpacaConfigured()) quotes.push(ALPACA_IEX_SOURCE);
  quotes.push(YAHOO_SOURCE);
  candles.push(YAHOO_SOURCE);
  if (alpacaSupports(instrument)) candles.push(instrument.venue === "crypto" ? ALPACA_CRYPTO_SOURCE : ALPACA_IEX_SOURCE);
  return { instrument: toView(instrument), market: marketState(instrument.venue), sources: { quotes, candles } };
}

// MARK: - Search

function rank(query: string, r: SearchResult): number {
  const q = query.toUpperCase();
  if (r.symbol === q) return 0;
  if (r.symbol.startsWith(q)) return 1;
  if (r.name.toUpperCase().startsWith(q)) return 2;
  if (r.name.toUpperCase().includes(q)) return 3;
  return 4;
}

export async function search(query: string, { allowLicensedIdentifiers = true } = {}): Promise<SearchResponse> {
  const q = query.trim();
  if (q === "") return { query: q, results: [] };
  const decoded = decodeSearch(q);
  const upper = decoded.term.toUpperCase();
  const results = new Map<string, SearchResult>();
  const add = (r: SearchResult, preferred = false) => {
    if (decoded.venue && decoded.venue !== r.venue) return;
    if (preferred || !results.has(r.id)) results.set(r.id, r);
  };

  const exactIdentifier = Boolean(decoded.cik || decoded.identifier);
  if (!exactIdentifier) {
    for (const [sym, name] of Object.entries(COIN_NAMES)) {
      if (sym.startsWith(upper) || name.toUpperCase().includes(upper)) add({ ...toView(makeInstrument(sym, "crypto", "crypto", name)), origin: "catalog", exchangeLabel: "Crypto" });
    }
    for (const instrument of catalogInstruments) {
      if (instrument.symbol.startsWith(upper) || instrument.name.toUpperCase().includes(upper)) {
        add({ ...toView(instrument), origin: "catalog", exchangeLabel: instrument.venue.toUpperCase() });
      }
    }
  }

  const [sec, yahoo] = await Promise.allSettled([
    decoded.identifier && !allowLicensedIdentifiers ? Promise.resolve([]) : researchSearch(decoded),
    exactIdentifier ? Promise.resolve([]) : cached(`search:${upper}`, 60_000, () => yahooSearch(decoded.term)),
  ]);
  if (yahoo.status === "fulfilled") {
    for (const hit of yahoo.value) {
      if (hit.venue === "crypto" && !COINGECKO_IDS[hit.symbol]) continue;
      add({ ...toView(makeInstrument(hit.symbol, hit.assetClass, hit.venue, hit.name)), origin: "search", exchangeLabel: hit.exchangeLabel }, true);
    }
  }
  if (sec.status === "fulfilled") {
    for (const row of sec.value) {
      const existing = results.get(row.id);
      add(existing ? { ...row, assetClass: existing.assetClass === "etf" ? "etf" : row.assetClass } : row, true);
    }
  }
  const warning = yahoo.status === "rejected" ? `Market search is temporarily limited (${reason(yahoo.reason)}).`
    : exactIdentifier && !results.size ? "No matching identifier was returned by the connected directories." : undefined;
  const sorted = [...results.values()].sort((a, b) => rank(decoded.term, a) - rank(decoded.term, b));
  return { query: q, results: sorted.slice(0, 20), warning };
}
