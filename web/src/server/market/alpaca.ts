// Alpaca market data (read-only data keys — never trading keys). Used only when
// ALPACA_DATA_KEY_ID / ALPACA_DATA_SECRET are set.
//
// The free plan's US stock feed is IEX: real time, but ONE exchange. Its last trade is a
// real price; its volume is a few percent of the market, so it's labelled single-venue
// and never presented as consolidated volume.

import type { Instrument } from "@engine/market.ts";
import type { CandleView, ChartRange } from "@/lib/market-types";
import { getJSON, UpstreamError } from "./http";

const DATA = "https://data.alpaca.markets";
export const ALPACA_IEX_SOURCE = "Alpaca (IEX feed — one exchange)";
export const ALPACA_CRYPTO_SOURCE = "Alpaca crypto (US venue)";

export function alpacaConfigured(): boolean {
  return Boolean(process.env.ALPACA_DATA_KEY_ID && process.env.ALPACA_DATA_SECRET);
}

function headers(): Record<string, string> {
  return { "APCA-API-KEY-ID": process.env.ALPACA_DATA_KEY_ID ?? "", "APCA-API-SECRET-KEY": process.env.ALPACA_DATA_SECRET ?? "" };
}

export function alpacaSupports(instrument: Instrument): boolean {
  return !instrument.symbol.startsWith("^") && alpacaConfigured() && (instrument.venue === "us" || instrument.venue === "crypto");
}

interface AlpacaBar { t: string; o: number; h: number; l: number; c: number; v: number }

export interface AlpacaQuote {
  last: number;
  previousClose?: number;
  bid?: number;
  ask?: number;
  dayHigh?: number;
  dayLow?: number;
  observedAt: number;
}

export async function alpacaQuote(instrument: Instrument): Promise<AlpacaQuote> {
  if (instrument.venue === "us") {
    const body = (await getJSON(`${DATA}/v2/stocks/${encodeURIComponent(instrument.symbol)}/snapshot?feed=iex`, { label: "Alpaca", headers: headers() })) as {
      latestTrade?: { p?: number; t?: string };
      latestQuote?: { bp?: number; ap?: number };
      dailyBar?: AlpacaBar;
      prevDailyBar?: AlpacaBar;
    };
    const p = body.latestTrade?.p;
    const t = body.latestTrade?.t;
    if (typeof p !== "number" || !(p > 0) || !t) throw new UpstreamError("Alpaca has no recent trade for that", 404);
    // Pre-market: the latest trade is on a later day than dailyBar, so dailyBar IS the previous close.
    const tradeDay = t.slice(0, 10);
    const dailyDay = body.dailyBar?.t?.slice(0, 10);
    const previousClose = dailyDay && tradeDay > dailyDay ? body.dailyBar?.c : body.prevDailyBar?.c;
    const sameDay = dailyDay === tradeDay;
    return {
      last: p,
      previousClose,
      bid: body.latestQuote?.bp && body.latestQuote.bp > 0 ? body.latestQuote.bp : undefined,
      ask: body.latestQuote?.ap && body.latestQuote.ap > 0 ? body.latestQuote.ap : undefined,
      dayHigh: sameDay ? body.dailyBar?.h : undefined,
      dayLow: sameDay ? body.dailyBar?.l : undefined,
      observedAt: Date.parse(t),
    };
  }
  if (instrument.venue === "crypto") {
    const pair = `${instrument.symbol}/USD`;
    const body = (await getJSON(`${DATA}/v1beta3/crypto/us/snapshots?symbols=${encodeURIComponent(pair)}`, { label: "Alpaca", headers: headers() })) as {
      snapshots?: Record<string, { latestTrade?: { p?: number; t?: string }; latestQuote?: { bp?: number; ap?: number }; prevDailyBar?: AlpacaBar; dailyBar?: AlpacaBar }>;
    };
    const s = body.snapshots?.[pair];
    const p = s?.latestTrade?.p;
    const t = s?.latestTrade?.t;
    if (!s || typeof p !== "number" || !(p > 0) || !t) throw new UpstreamError("Alpaca has no recent crypto trade for that", 404);
    return { last: p, previousClose: s.prevDailyBar?.c, bid: s.latestQuote?.bp, ask: s.latestQuote?.ap, dayHigh: s.dailyBar?.h, dayLow: s.dailyBar?.l, observedAt: Date.parse(t) };
  }
  throw new UpstreamError("Alpaca doesn't carry that market", 404);
}

const FRAMES: Record<ChartRange, { timeframe: string; days: number; interval: string }> = {
  "1D": { timeframe: "5Min", days: 4, interval: "5m" },
  "5D": { timeframe: "15Min", days: 8, interval: "15m" },
  "1M": { timeframe: "1Hour", days: 31, interval: "1h" },
  "3M": { timeframe: "1Day", days: 92, interval: "1d" },
  "6M": { timeframe: "1Day", days: 183, interval: "1d" },
  "1Y": { timeframe: "1Day", days: 366, interval: "1d" },
  "5Y": { timeframe: "1Week", days: 1830, interval: "1wk" },
};

export async function alpacaCandles(instrument: Instrument, range: ChartRange, now = Date.now()): Promise<{ candles: CandleView[]; interval: string }> {
  const frame = FRAMES[range];
  const start = new Date(now - frame.days * 86_400_000).toISOString();
  const out: CandleView[] = [];
  let pageToken: string | undefined;
  for (let page = 0; page < 10; page++) {
    let url: string;
    if (instrument.venue === "us") {
      url = `${DATA}/v2/stocks/${encodeURIComponent(instrument.symbol)}/bars?timeframe=${frame.timeframe}&start=${encodeURIComponent(start)}&feed=iex&adjustment=all&limit=10000&sort=asc`;
    } else if (instrument.venue === "crypto") {
      url = `${DATA}/v1beta3/crypto/us/bars?symbols=${encodeURIComponent(`${instrument.symbol}/USD`)}&timeframe=${frame.timeframe}&start=${encodeURIComponent(start)}&limit=10000&sort=asc`;
    } else {
      throw new UpstreamError("Alpaca doesn't carry that market", 404);
    }
    if (pageToken) url += `&page_token=${encodeURIComponent(pageToken)}`;
    const body = (await getJSON(url, { label: "Alpaca", headers: headers() })) as { bars?: AlpacaBar[] | Record<string, AlpacaBar[]> | null; next_page_token?: string | null };
    const bars: AlpacaBar[] = Array.isArray(body.bars) ? body.bars : body.bars ? body.bars[`${instrument.symbol}/USD`] ?? [] : [];
    for (const b of bars) {
      if (!(b.o > 0 && b.h > 0 && b.l > 0 && b.c > 0) || b.h < b.l) continue;
      out.push({ time: Math.floor(Date.parse(b.t) / 1000), open: b.o, high: b.h, low: b.l, close: b.c, volume: b.v >= 0 ? b.v : 0 });
    }
    pageToken = body.next_page_token ?? undefined;
    if (!pageToken) break;
  }
  return { candles: out, interval: frame.interval };
}
