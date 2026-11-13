// How much of a coin trades in a day across the whole market, from CoinGecko.
//
// Alpaca's crypto bars count only Alpaca's own small venue, so they can't say how liquid
// a coin is. This asks CoinGecko's public "coins/markets" list for `total_volume` — the
// traded value in US dollars over the last 24 hours, across every exchange it tracks —
// the same figure the phone app uses.
//
// MARKET DATA ONLY: one read-only GET. The API key is optional (a free "Demo" key raises
// the rate limit); when there is one it travels in a header and nowhere else — never in
// the URL, a log line or an error. It must be a Demo key: this is the Demo host, and
// CoinGecko refuses a Pro key here.
//
// An unknown figure stays unknown. A coin this file has no id for, an instrument that
// isn't a US-dollar crypto asset, an HTTP error, a timeout, an unreadable answer or a
// volume that isn't a positive number: the instrument is simply left out. Nothing here
// throws and nothing is estimated.

import { type Instrument, instrumentID } from "../trading/market.ts";
import { type DollarVolumeSource, isRecord, positiveNumber, uniqueInstruments } from "./provider.ts";

export interface CoinGeckoVolumeSourceOptions {
  /** A CoinGecko Demo key. Optional: without one the shared, slower public limit applies. */
  apiKey?: string;
  fetch?: typeof fetch;
  /** Per attempt. Default 6000. */
  timeoutMs?: number;
  /** The pause before the one retry. Default 500. */
  backoffMs?: number;
  sleep?: (ms: number) => Promise<void>;
  /** One small event per HTTP attempt. It never carries a header, a key or a query string. */
  log?: (event: Record<string, unknown>) => void;
}

const MARKETS_URL = "https://api.coingecko.com/api/v3/coins/markets";
const MARKETS_PATH = "/api/v3/coins/markets";
const DEMO_KEY_HEADER = "x-cg-demo-api-key";

/** One retry is enough: this figure is a nice-to-have next to prices, not worth a long wait. */
const MAX_ATTEMPTS = 2;
/** A server that asks for a longer pause than this isn't waited for. */
const MAX_RETRY_WAIT_MS = 2_000;

/** The coins the app can price, by ticker → CoinGecko id (QuoteService.coinGeckoIDMap). */
const COIN_IDS: ReadonlyMap<string, string> = new Map([
  ["BTC", "bitcoin"],
  ["ETH", "ethereum"],
  ["SOL", "solana"],
  ["ADA", "cardano"],
  ["BNB", "binancecoin"],
  ["XRP", "ripple"],
  ["DOGE", "dogecoin"],
  ["DOT", "polkadot"],
  ["MATIC", "matic-network"],
  ["LINK", "chainlink"],
  ["AVAX", "avalanche-2"],
  ["UNI", "uniswap"],
  ["LTC", "litecoin"],
  ["ATOM", "cosmos"],
]);

interface Attempt {
  body?: unknown;
  /** True when the failure is one a second try might cure (HTTP 429 or 5xx). */
  retry?: boolean;
  retryAfterMs?: number;
}

export class CoinGeckoVolumeSource implements DollarVolumeSource {
  // Private, so the key can't be printed or serialised with the object.
  readonly #apiKey: string;
  readonly #fetch: typeof fetch;
  readonly #timeoutMs: number;
  readonly #backoffMs: number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #log?: (event: Record<string, unknown>) => void;

  constructor(options: CoinGeckoVolumeSourceOptions = {}) {
    this.#apiKey = typeof options.apiKey === "string" ? options.apiKey.trim() : "";
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
    this.#timeoutMs = atLeast(options.timeoutMs, 1, 6_000);
    this.#backoffMs = atLeast(options.backoffMs, 0, 500);
    this.#sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.#log = options.log;
  }

  /**
   * 24-hour traded value in US dollars, keyed by instrumentID(), for the crypto
   * instruments it can be found for. One request however many are asked about.
   */
  async dollarVolume(instruments: Instrument[], _now: number): Promise<Record<string, number>> {
    const known: Record<string, number> = {};
    try {
      // CoinGecko id → the instrument ids waiting on it.
      const waiting = new Map<string, string[]>();
      for (const instrument of uniqueInstruments(instruments)) {
        // The figure is in US dollars, so it only describes a dollar-priced crypto asset.
        if (instrument.assetClass !== "crypto" || instrument.venue !== "crypto" || instrument.currency !== "USD") continue;
        const coin = typeof instrument.symbol === "string" ? COIN_IDS.get(instrument.symbol.toUpperCase()) : undefined;
        if (coin === undefined) continue;
        const ids = waiting.get(coin) ?? [];
        ids.push(instrumentID(instrument));
        waiting.set(coin, ids);
      }
      if (waiting.size === 0) return known;

      const rows = await this.#get([...waiting.keys()]);
      if (!Array.isArray(rows)) return known;
      for (const row of rows) {
        if (!isRecord(row) || typeof row.id !== "string") continue;
        const volume = positiveNumber(row.total_volume);
        if (volume === undefined) continue;
        for (const id of waiting.get(row.id) ?? []) {
          if (known[id] === undefined) known[id] = volume;
        }
      }
    } catch {
      // Not knowing is an answer: whatever isn't in `known` is unknown.
    }
    return known;
  }

  /** The decoded answer, or undefined when there isn't a usable one. Never throws. */
  async #get(coins: string[]): Promise<unknown> {
    const query = new URLSearchParams([["vs_currency", "usd"], ["ids", coins.join(",")]]);
    const url = `${MARKETS_URL}?${query.toString()}`;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      const outcome = await this.#attempt(url, coins.length, attempt);
      if (outcome.retry !== true) return outcome.body;
      if (attempt === MAX_ATTEMPTS) break;
      const asked = outcome.retryAfterMs ?? 0;
      if (asked > MAX_RETRY_WAIT_MS) break; // it won't be ready in the time we're willing to wait
      await this.#sleep(Math.max(this.#backoffMs, asked));
    }
    return undefined;
  }

  async #attempt(url: string, coins: number, attempt: number): Promise<Attempt> {
    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.#timeoutMs);
    const started = performance.now();
    const event: Record<string, unknown> = { event: "market_data_request", provider: "coingecko", path: MARKETS_PATH, symbols: coins, attempt };
    try {
      const headers: Record<string, string> = { "Accept": "application/json" };
      if (this.#apiKey !== "") headers[DEMO_KEY_HEADER] = this.#apiKey;
      const response = await this.#fetch(url, {
        method: "GET",
        headers,
        signal: controller.signal,
        // A redirect would carry the key header to wherever it points. Don't follow one.
        redirect: "manual",
      });
      const status = response.status;
      event.status = status;
      if (!response.ok) {
        const retryAfterMs = retryAfter(response.headers.get("retry-after"));
        await response.body?.cancel().catch(() => {});
        return { retry: status === 429 || status >= 500, retryAfterMs };
      }
      const text = await response.text(); // still under the timeout
      try {
        return { body: JSON.parse(text) };
      } catch {
        event.error = "unreadable";
        return {};
      }
    } catch {
      // Whatever was thrown is not looked at: only which of the two things happened.
      event.error = timedOut ? "timeout" : "network";
      return {};
    } finally {
      clearTimeout(timer);
      event.ms = Math.round(performance.now() - started);
      try {
        this.#log?.(event);
      } catch {
        // A broken logger must not cost anyone their data.
      }
    }
  }
}

function atLeast(value: number | undefined, minimum: number, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum ? value : fallback;
}

/** A numeric Retry-After (seconds) as milliseconds. The date form is ignored. */
function retryAfter(header: string | null): number | undefined {
  if (header === null || !/^\s*\d+(\.\d+)?\s*$/.test(header)) return undefined;
  return Number(header) * 1_000;
}
