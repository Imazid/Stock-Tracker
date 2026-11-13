// Real prices from Alpaca's Market Data API (https://data.alpaca.markets).
//
// MARKET DATA ONLY. This file talks to the data host and to four read-only paths on it:
// historical bars and snapshots, for US stocks/ETFs and for crypto. It has no order,
// position or account call, and the credentials it is given are never sent anywhere
// else. Keep it that way: trading goes through a separate broker layer with its own keys.
//
// The sourcing rules are the phone app's (Stock Tracker/TradingMarketData.swift), so the
// phone and the server decide on the same inputs:
//   US daily bars   the consolidated tape first (`feed=sip`, ending 16 minutes ago — the
//                   free plan serves it once it is 15 minutes old): every exchange's
//                   trades, so the volume is the whole market's. If the plan doesn't
//                   allow it (HTTP 403/422) or it has no bars for a symbol, IEX instead.
//   US hourly bars  IEX. One exchange: its volume is a slice, and is marked as one.
//   crypto bars     Alpaca's own venue. Also a slice, and marked as one.
//   quotes          the last trade. The bid and ask only when they make a believable
//                   market. Never a day volume — a snapshot's is one venue's.
//
// Shapes below were checked against Alpaca's reference (docs.alpaca.markets/reference:
// stockbars, stocksnapshots-1, cryptobars-1, cryptosnapshots-1) in November 2026:
//   bars       {"bars": {"AAPL": [{"t","o","h","l","c","v","n","vw"}]}, "next_page_token"}
//              `limit` (max 10000) counts data points across ALL symbols, sorted by symbol
//              and then by time, so one answer can take several pages.
//   stocks     snapshots are keyed by symbol at the top level: {"AAPL": {latestTrade, ...}}
//   crypto     snapshots are nested: {"snapshots": {"BTC/USD": {latestTrade, ...}}}
//   a snapshot latestTrade {t, p}, latestQuote {t, bp, ap}
//
// Nothing is made up here. A symbol Alpaca doesn't answer for, an answer that can't be
// read, a price that isn't a positive number, a time that isn't a time: each is recorded
// as a failure for that instrument and no value is produced.

import {
  type Bar,
  type DataProvenance,
  type Instrument,
  instrumentID,
  makeBarSeries,
  marketProvenance,
  type Quote,
  type Timeframe,
  venueDisplayName,
  VENUES,
} from "../trading/market.ts";
import {
  barRequestProblem,
  type BarsResult,
  chunked,
  type DollarVolumeSource,
  failureReason,
  finiteNumber,
  isRecord,
  lastBars,
  type MarketDataProvider,
  own,
  parseVenueTime,
  positiveNumber,
  ProviderError,
  type QuotesResult,
  uniqueInstruments,
} from "./provider.ts";

export interface AlpacaDataProviderOptions {
  keyId: string;
  secret: string;
  fetch?: typeof fetch;
  /** Default "https://data.alpaca.markets". */
  baseURL?: string;
  /** Per attempt. Default 8000. */
  timeoutMs?: number;
  /** Default 3. */
  maxAttempts?: number;
  /** Doubles after every failed attempt. Default 300. */
  backoffMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /** One small event per HTTP attempt. It never carries a header, a key or a query string. */
  log?: (event: Record<string, unknown>) => void;
  /**
   * Where market-wide traded value comes from for crypto, whose Alpaca volume is only
   * Alpaca's own venue. Without one, `dollarVolume()` knows nothing.
   */
  volumeSource?: DollarVolumeSource;
}

const DATA_HOST = "https://data.alpaca.markets";

// The only four paths this provider ever requests. All are GET, all are market data.
const STOCK_BARS = "/v2/stocks/bars";
const STOCK_SNAPSHOTS = "/v2/stocks/snapshots";
const CRYPTO_BARS = "/v1beta3/crypto/us/bars";
const CRYPTO_SNAPSHOTS = "/v1beta3/crypto/us/snapshots";

/** Every US exchange's trades. Free once 15 minutes old; real time needs a paid plan. */
const CONSOLIDATED_FEED = "sip";
/** The free plan's only real-time equity feed: one exchange, a few percent of US volume. */
const IEX_FEED = "iex";
/** How far back a consolidated request ends, to stay behind the 15-minute line. */
const CONSOLIDATED_DELAY_MS = 16 * 60_000;

const CONSOLIDATED_SOURCE = "Alpaca (consolidated)";
const IEX_SOURCE = "Alpaca (IEX)";
const CRYPTO_SOURCE = "Alpaca crypto";

/** Alpaca documents no symbol limit per request; these keep URLs and answers modest. */
const STOCK_CHUNK = 100;
const CRYPTO_CHUNK = 20;
/** The documented maximum page size (data points across every symbol in the request). */
const PAGE_LIMIT = 10_000;
/** A bars answer longer than this many pages is treated as a failure, not read forever. */
const MAX_PAGES = 50;
const MAX_RETRY_AFTER_MS = 5_000;

/** A bid and ask further apart than this, or this far from the last trade, aren't a market. */
const MAX_BOOK_SPREAD = 0.01;
const MAX_BOOK_DISTANCE = 0.01;

const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;
/** Alpaca's history starts in 2016; asking from earlier only risks an unformattable date. */
const EARLIEST_START = Date.UTC(2015, 0, 1);

// What a symbol must look like before it is put in a request. A symbol is joined into a
// comma-separated list, so anything else (a comma, a slash, a space) could ask for
// something other than what the instrument says — and could fail everyone else's request.
const STOCK_SYMBOL = /^[A-Z0-9]{1,12}(?:[.\-][A-Z0-9]{1,6}){0,2}$/;
const CRYPTO_SYMBOL = /^[A-Z0-9]{1,15}$/;

type Kind = "stock" | "crypto";

interface Target {
  id: string;
  instrument: Instrument;
  /** What Alpaca calls it: "AAPL", "BTC/USD". */
  symbol: string;
}

interface Chunk {
  kind: Kind;
  targets: Target[];
}

/** One bars request: which feed, and where it stops (no `end` = up to the present). */
interface BarsQuery {
  feed?: string;
  end?: number;
}

/** How a set of bars is labelled once it becomes a series. */
interface SeriesLabel {
  source: string;
  volumeIsMarketWide: boolean;
}

interface Attempt {
  body?: unknown;
  error?: ProviderError;
  retryAfterMs?: number;
}

export class AlpacaDataProvider implements MarketDataProvider {
  readonly name = "alpaca";

  // Private fields, so the credentials can't be printed or serialised with the object.
  readonly #keyId: string;
  readonly #secret: string;
  readonly #fetch: typeof fetch;
  readonly #baseURL: string;
  readonly #timeoutMs: number;
  readonly #maxAttempts: number;
  readonly #backoffMs: number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #log?: (event: Record<string, unknown>) => void;
  readonly #volumeSource?: DollarVolumeSource;

  constructor(options: AlpacaDataProviderOptions) {
    this.#keyId = options.keyId;
    this.#secret = options.secret;
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
    this.#baseURL = checkedBaseURL(options.baseURL ?? DATA_HOST);
    this.#timeoutMs = atLeast(options.timeoutMs, 1, 8_000);
    this.#maxAttempts = Math.floor(atLeast(options.maxAttempts, 1, 3));
    this.#backoffMs = atLeast(options.backoffMs, 0, 300);
    this.#sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.#log = options.log;
    this.#volumeSource = options.volumeSource;
  }

  supports(instrument: Instrument): boolean {
    return instrument.venue === "us" || instrument.venue === "crypto";
  }

  async bars(instruments: Instrument[], timeframe: Timeframe, count: number, now: number): Promise<BarsResult> {
    const result: BarsResult = { series: {}, failures: {} };
    const wanted = uniqueInstruments(instruments);
    try {
      const problem = barRequestProblem(timeframe, count, now);
      if (problem !== undefined) {
        for (const instrument of wanted) result.failures[instrumentID(instrument)] = problem;
        return result;
      }
      const chunks = this.#plan(wanted, result.failures);
      await Promise.all(chunks.map((chunk) => this.#barsChunk(chunk, timeframe, count, now, result)));
    } catch (error) {
      // Nothing above is expected to throw; if it does, whatever has no answer yet fails.
      for (const instrument of wanted) {
        const id = instrumentID(instrument);
        if (result.series[id] === undefined && result.failures[id] === undefined) result.failures[id] = failureReason(error);
      }
    }
    return result;
  }

  async quotes(instruments: Instrument[], _now: number): Promise<QuotesResult> {
    const result: QuotesResult = { quotes: {}, failures: {} };
    const wanted = uniqueInstruments(instruments);
    try {
      const chunks = this.#plan(wanted, result.failures);
      await Promise.all(chunks.map((chunk) => this.#quotesChunk(chunk, result)));
    } catch (error) {
      for (const instrument of wanted) {
        const id = instrumentID(instrument);
        if (result.quotes[id] === undefined && result.failures[id] === undefined) result.failures[id] = failureReason(error);
      }
    }
    return result;
  }

  /**
   * Market-wide traded value for crypto, from the volume source this provider was given.
   * Alpaca itself has no such figure: its crypto volume is its own venue's. Stocks aren't
   * asked about here — their consolidated bars already carry the whole market's volume.
   */
  async dollarVolume(instruments: Instrument[], now: number): Promise<Record<string, number>> {
    const known: Record<string, number> = {};
    try {
      const source = this.#volumeSource;
      const crypto = uniqueInstruments(instruments).filter((instrument) => instrument.venue === "crypto");
      if (source === undefined || crypto.length === 0) return known;
      const answer = await source.dollarVolume(crypto, now);
      for (const instrument of crypto) {
        const id = instrumentID(instrument);
        const value = positiveNumber(own(answer, id));
        if (value !== undefined) known[id] = value;
      }
    } catch {
      // Not knowing is an answer: the instrument is simply left out.
    }
    return known;
  }

  /** Sorts instruments into requests. What can't be asked for is failed here, unrequested. */
  #plan(instruments: Instrument[], failures: Record<string, string>): Chunk[] {
    const stocks: Target[] = [];
    const crypto: Target[] = [];
    for (const instrument of instruments) {
      const id = instrumentID(instrument);
      if (!this.supports(instrument)) {
        // A venue this code has never heard of (bad input) has no name to look up.
        const market = VENUES.includes(instrument.venue) ? venueDisplayName(instrument.venue) : "This market";
        failures[id] = `${market} isn't supported by this data source`;
        continue;
      }
      const symbol = typeof instrument.symbol === "string" ? instrument.symbol.toUpperCase() : "";
      if (instrument.venue === "crypto") {
        if (CRYPTO_SYMBOL.test(symbol)) crypto.push({ id, instrument, symbol: `${symbol}/USD` });
        else failures[id] = `Alpaca has no data for ${instrument.symbol}`;
      } else {
        if (STOCK_SYMBOL.test(symbol)) stocks.push({ id, instrument, symbol });
        else failures[id] = `Alpaca has no data for ${instrument.symbol}`;
      }
    }
    return [
      ...chunked(stocks, STOCK_CHUNK).map((targets): Chunk => ({ kind: "stock", targets })),
      ...chunked(crypto, CRYPTO_CHUNK).map((targets): Chunk => ({ kind: "crypto", targets })),
    ];
  }

  async #barsChunk(chunk: Chunk, timeframe: Timeframe, count: number, now: number, result: BarsResult): Promise<void> {
    if (chunk.kind === "stock" && timeframe === "day") {
      await this.#stockDailyChunk(chunk.targets, count, now, result);
      return;
    }
    // Hourly stock bars come from IEX and crypto bars from Alpaca's own venue: either way
    // the volume is one venue's.
    const stock = chunk.kind === "stock";
    await this.#fillSeries(
      chunk.targets,
      chunk.kind,
      timeframe,
      count,
      now,
      stock ? { feed: IEX_FEED } : {},
      { source: stock ? IEX_SOURCE : CRYPTO_SOURCE, volumeIsMarketWide: false },
      result,
    );
  }

  /**
   * Daily stock bars: the consolidated tape where the plan and the symbol allow it, IEX
   * where they don't. The switch to IEX is made for exactly two reasons — "not on this
   * plan" (HTTP 403/422) and "no bars for this symbol". An outage is not one of them: a
   * consolidated request that times out or returns a 5xx fails its instruments.
   */
  async #stockDailyChunk(targets: Target[], count: number, now: number, result: BarsResult): Promise<void> {
    let unanswered = targets;
    try {
      const bars = await this.#pagedBars("stock", symbolsOf(targets), "day", count, now, {
        feed: CONSOLIDATED_FEED,
        end: now - CONSOLIDATED_DELAY_MS,
      });
      unanswered = [];
      for (const target of targets) {
        const answered = bars.get(target.symbol) ?? [];
        if (answered.length === 0) unanswered.push(target);
        else record(target, answered, "day", count, now, { source: CONSOLIDATED_SOURCE, volumeIsMarketWide: true }, result);
      }
    } catch (error) {
      const notOnThisPlan = error instanceof ProviderError && (error.status === 403 || error.status === 422);
      if (!notOnThisPlan) {
        for (const target of targets) result.failures[target.id] = failureReason(error);
        return;
      }
    }
    if (unanswered.length === 0) return;
    // One more request, for just the symbols the consolidated tape didn't answer for.
    await this.#fillSeries(unanswered, "stock", "day", count, now, { feed: IEX_FEED }, { source: IEX_SOURCE, volumeIsMarketWide: false }, result);
  }

  /** One paged bars request turned into series, or the same failure for all of its targets. */
  async #fillSeries(
    targets: Target[],
    kind: Kind,
    timeframe: Timeframe,
    count: number,
    now: number,
    query: BarsQuery,
    label: SeriesLabel,
    result: BarsResult,
  ): Promise<void> {
    try {
      const bars = await this.#pagedBars(kind, symbolsOf(targets), timeframe, count, now, query);
      for (const target of targets) record(target, bars.get(target.symbol) ?? [], timeframe, count, now, label, result);
    } catch (error) {
      for (const target of targets) {
        delete result.series[target.id];
        result.failures[target.id] = failureReason(error);
      }
    }
  }

  /**
   * Every bar Alpaca has for these symbols in the window, by symbol, exactly as sent
   * (unreadable times aside). Throws a ProviderError unless every page arrived.
   */
  async #pagedBars(kind: Kind, symbols: string[], timeframe: Timeframe, count: number, now: number, options: BarsQuery): Promise<Map<string, Bar[]>> {
    const bars = new Map<string, Bar[]>(symbols.map((symbol) => [symbol, []]));
    const query: [string, string][] = [
      ["symbols", symbols.join(",")],
      ["timeframe", timeframe === "day" ? "1Day" : "1Hour"],
      ["start", rfc3339(windowStart(kind, timeframe, count, now))],
    ];
    // Without an `end` the answer runs to the present and may finish with a bar that is
    // still forming. It is passed on untouched — deciding what is complete is the engine's job.
    if (options.end !== undefined) query.push(["end", rfc3339(options.end)]);
    query.push(["limit", String(PAGE_LIMIT)]);
    // Split- and dividend-adjusted, or a split draws as a crash. Crypto has neither option.
    if (kind === "stock") query.push(["adjustment", "all"]);
    if (options.feed !== undefined) query.push(["feed", options.feed]);
    query.push(["sort", "asc"]);

    // Every page must arrive before any of it is used. Pages are sorted by symbol and
    // then by time, so stopping early would leave a symbol's history ending in the
    // past — an old price dressed up as the latest.
    let pageToken: string | undefined;
    for (let page = 1; ; page++) {
      if (page > MAX_PAGES) throw new ProviderError("Alpaca sent more price history than could be read");
      const body = await this.#get(
        kind === "stock" ? STOCK_BARS : CRYPTO_BARS,
        pageToken === undefined ? query : [...query, ["page_token", pageToken]],
        symbols.length,
      );
      if (!isRecord(body)) throw new ProviderError("Alpaca returned an unreadable response");
      const bySymbol = body.bars;
      if (bySymbol !== undefined && bySymbol !== null) { // null is how Alpaca says "no bars"
        if (!isRecord(bySymbol)) throw new ProviderError("Alpaca returned an unreadable response");
        for (const symbol of symbols) {
          const list = own(bySymbol, symbol);
          if (!Array.isArray(list)) continue;
          const collected = bars.get(symbol)!;
          for (const item of list) {
            const bar = parseBar(item);
            if (bar !== undefined) collected.push(bar);
          }
        }
      }
      const next = body.next_page_token;
      if (typeof next !== "string" || next === "") break;
      if (next === pageToken) throw new ProviderError("Alpaca returned an unreadable response");
      pageToken = next;
    }
    return bars;
  }

  async #quotesChunk(chunk: Chunk, result: QuotesResult): Promise<void> {
    try {
      const stock = chunk.kind === "stock";
      const symbols = symbolsOf(chunk.targets);
      const query: [string, string][] = [["symbols", symbols.join(",")]];
      if (stock) query.push(["feed", IEX_FEED]);
      const body = await this.#get(stock ? STOCK_SNAPSHOTS : CRYPTO_SNAPSHOTS, query, symbols.length);
      if (!isRecord(body)) throw new ProviderError("Alpaca returned an unreadable response");

      const provenance = marketProvenance(stock ? IEX_SOURCE : CRYPTO_SOURCE);
      for (const target of chunk.targets) {
        // Stocks are keyed at the top level and crypto under "snapshots"; either is read.
        const snapshot = own(body, target.symbol) ?? own(body.snapshots, target.symbol);
        const quote = parseQuote(snapshot, target.id, provenance);
        if (quote === undefined) result.failures[target.id] = `Alpaca has no live quote for ${target.instrument.symbol}`;
        else result.quotes[target.id] = quote;
      }
    } catch (error) {
      for (const target of chunk.targets) {
        delete result.quotes[target.id];
        result.failures[target.id] = failureReason(error);
      }
    }
  }

  /**
   * One GET, retried on a network error, a timeout, HTTP 429 and HTTP 5xx. Resolves with
   * the decoded JSON or throws a ProviderError whose message is safe to record.
   */
  async #get(path: string, query: [string, string][], symbols: number): Promise<unknown> {
    // The keys travel in headers only. The query holds symbols and bar settings.
    const url = `${this.#baseURL}${path}?${new URLSearchParams(query).toString()}`;
    for (let attempt = 1; ; attempt++) {
      const outcome = await this.#attempt(url, path, symbols, attempt);
      if (outcome.error === undefined) return outcome.body;
      if (!outcome.error.retryable || attempt >= this.#maxAttempts) throw outcome.error;
      const backoff = this.#backoffMs * 2 ** (attempt - 1);
      await this.#sleep(Math.max(backoff, outcome.retryAfterMs ?? 0));
    }
  }

  async #attempt(url: string, path: string, symbols: number, attempt: number): Promise<Attempt> {
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.#timeoutMs);
    const started = performance.now();
    const event: Record<string, unknown> = { event: "market_data_request", provider: this.name, path, symbols, attempt };
    try {
      const response = await this.#fetch(url, {
        method: "GET",
        headers: {
          "APCA-API-KEY-ID": this.#keyId,
          "APCA-API-SECRET-KEY": this.#secret,
          "Accept": "application/json",
        },
        signal: controller.signal,
        // A redirect would carry the key headers to wherever it points. Don't follow one.
        redirect: "manual",
      });
      const status = response.status;
      event.status = status;

      if (!response.ok) {
        const retryAfterMs = retryAfter(response.headers.get("retry-after"));
        await response.body?.cancel().catch(() => {});
        if (status === 401 || status === 403) {
          return { error: new ProviderError("Alpaca rejected the data credentials", status) };
        }
        if (status === 429) {
          return { error: new ProviderError("Alpaca is rate limiting requests (HTTP 429)", status, true), retryAfterMs };
        }
        return { error: new ProviderError(`Alpaca returned HTTP ${status}`, status, status >= 500), retryAfterMs };
      }

      const text = await response.text(); // still under the timeout
      try {
        return { body: JSON.parse(text) };
      } catch {
        event.error = "unreadable";
        return { error: new ProviderError("Alpaca returned an unreadable response", status) };
      }
    } catch {
      // Whatever was thrown is not looked at: only which of the two things happened.
      event.error = timedOut ? "timeout" : "network";
      return { error: new ProviderError(timedOut ? "The request timed out" : "Alpaca couldn't be reached", undefined, true) };
    } finally {
      clearTimeout(timer);
      event.ms = Math.round(performance.now() - started);
      try {
        this.#log?.(event);
      } catch {
        // A broken logger must not cost anyone their prices.
      }
    }
  }
}

// ---------------------------------------------------------------------------------------

/**
 * The data host, or a stand-in for tests. Refuses anything else on Alpaca's domain (that
 * is where orders live) and refuses to send keys over plain http to a remote machine.
 */
function checkedBaseURL(baseURL: string): string {
  let url: URL;
  try {
    url = new URL(baseURL);
  } catch {
    throw new ProviderError("The market data address isn't valid");
  }
  const host = url.hostname.toLowerCase();
  const alpaca = host === "alpaca.markets" || host.endsWith(".alpaca.markets");
  if (alpaca && !host.startsWith("data.")) throw new ProviderError("Only Alpaca's market data host can be used for market data");
  const local = host === "localhost" || host === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) throw new ProviderError("The market data address must use https");
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function atLeast(value: number | undefined, minimum: number, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum ? value : fallback;
}

function symbolsOf(targets: Target[]): string[] {
  return [...new Set(targets.map((target) => target.symbol))];
}

/**
 * Turns one instrument's bars into its series (the last `count` valid bars), or into a
 * failure when none of them is usable.
 */
function record(target: Target, bars: Bar[], timeframe: Timeframe, count: number, now: number, label: SeriesLabel, result: BarsResult): void {
  const series = makeBarSeries(target.instrument, timeframe, bars, marketProvenance(label.source), now, label.volumeIsMarketWide);
  if (series.bars.length === 0) {
    result.failures[target.id] = `Alpaca has no price history for ${target.instrument.symbol}`;
  } else {
    result.series[target.id] = lastBars(series, count);
  }
}

/**
 * How far back to ask so the answer holds at least `count` bars. Equities trade about
 * five days in seven and about seven hourly bars a day; crypto never stops.
 */
function windowStart(kind: Kind, timeframe: Timeframe, count: number, now: number): number {
  let start: number;
  if (kind === "crypto") {
    start = timeframe === "hour" ? now - (count + 6) * HOUR_MS : now - (count + 3) * DAY_MS;
  } else {
    const days = timeframe === "day" ? count * 1.6 + 10 : (count / 6) * 1.6 + 5;
    start = now - Math.ceil(days) * DAY_MS;
  }
  return Math.max(start, EARLIEST_START);
}

/** "2026-01-05T14:30:00Z" — whole seconds. */
function rfc3339(ms: number): string {
  return new Date(Math.floor(ms / 1_000) * 1_000).toISOString().replace(".000Z", "Z");
}

function numberOrNaN(value: unknown): number {
  return typeof value === "number" ? value : Number.NaN;
}

/**
 * One bar as Alpaca sent it. A field that isn't a number becomes NaN so `makeBarSeries`
 * drops the bar; a bar whose time can't be read is dropped here, because nothing later
 * checks the time and a bar with no place in time can't be ordered.
 */
function parseBar(raw: unknown): Bar | undefined {
  if (!isRecord(raw)) return undefined;
  const time = parseVenueTime(raw.t);
  if (time === undefined) return undefined;
  return {
    time,
    open: numberOrNaN(raw.o),
    high: numberOrNaN(raw.h),
    low: numberOrNaN(raw.l),
    close: numberOrNaN(raw.c),
    volume: numberOrNaN(raw.v),
  };
}

/**
 * A quote from one snapshot, or undefined when the snapshot holds no usable last trade.
 *
 * The bid and ask are kept only when they make a believable market. IEX is one exchange,
 * and outside busy hours its book can show a zero ask or a bid far from the last trade.
 * Those are dropped — both sides together — and the engine then says the spread couldn't
 * be measured instead of trusting a wrong one.
 *
 * The time is the venue's own: when the trade printed, or when the book was last updated
 * if that book is the one being kept and it is newer. It is never the fetch time.
 *
 * `dayVolume` is never set: a snapshot's daily volume is one venue's, not the market's.
 */
function parseQuote(snapshot: unknown, id: string, provenance: DataProvenance): Quote | undefined {
  if (!isRecord(snapshot)) return undefined;
  const trade = snapshot.latestTrade;
  if (!isRecord(trade)) return undefined;
  const last = positiveNumber(trade.p);
  const tradeTime = parseVenueTime(trade.t);
  if (last === undefined || tradeTime === undefined) return undefined;

  const quote: Quote = { instrumentID: id, last, time: tradeTime, provenance };

  const book = snapshot.latestQuote;
  if (isRecord(book)) {
    const bid = finiteNumber(book.bp);
    const ask = finiteNumber(book.ap);
    if (bid !== undefined && ask !== undefined && bid > 0 && ask >= bid) {
      const mid = (ask + bid) / 2;
      if ((ask - bid) / mid <= MAX_BOOK_SPREAD && Math.abs(mid / last - 1) <= MAX_BOOK_DISTANCE) {
        quote.bid = bid;
        quote.ask = ask;
        const bookTime = parseVenueTime(book.t);
        if (bookTime !== undefined) quote.time = Math.max(tradeTime, bookTime);
      }
    }
  }
  return quote;
}

/** A numeric Retry-After (seconds) as milliseconds, capped. The date form is ignored. */
function retryAfter(header: string | null): number | undefined {
  if (header === null || !/^\s*\d+(\.\d+)?\s*$/.test(header)) return undefined;
  return Math.min(Number(header) * 1_000, MAX_RETRY_AFTER_MS);
}
