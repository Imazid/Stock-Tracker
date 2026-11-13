// Technical indicators over a price series. A port of
// TradingCore/Sources/TradingCore/Indicators.swift.
//
// Every function returns one value per input bar; the value at index `i` is computed only
// from bars `0...i`, so nothing here can look ahead. `undefined` means "not enough
// history yet". The arithmetic is written in the same order as the Swift so the results
// are bit-for-bit the same (only + − × ÷ and sqrt are used).

import type { Bar } from "./market.ts";

export type Series = (number | undefined)[];

function blank(count: number): Series {
  return new Array<number | undefined>(count).fill(undefined);
}

export function sma(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length < period) return out;
  let sum = 0;
  for (let i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= period) sum -= values[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

/** Exponential average seeded with the simple average of the first `period` values. */
export function ema(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length < period) return out;
  const k = 2 / (period + 1);
  let seed = 0;
  for (let i = 0; i < period; i++) seed += values[i];
  let prev = seed / period;
  out[period - 1] = prev;
  for (let i = period; i < values.length; i++) {
    prev = prev + k * (values[i] - prev);
    out[i] = prev;
  }
  return out;
}

function rsiValue(avgGain: number, avgLoss: number): number {
  if (avgLoss === 0) return avgGain === 0 ? 50 : 100;
  const rs = avgGain / avgLoss;
  return 100 - 100 / (1 + rs);
}

/** Wilder's RSI. First value at index `period`. */
export function rsi(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length <= period) return out;
  let gain = 0, loss = 0;
  for (let i = 1; i <= period; i++) {
    const change = values[i] - values[i - 1];
    if (change >= 0) gain += change;
    else loss -= change;
  }
  let avgGain = gain / period;
  let avgLoss = loss / period;
  out[period] = rsiValue(avgGain, avgLoss);
  for (let i = period + 1; i < values.length; i++) {
    const change = values[i] - values[i - 1];
    avgGain = (avgGain * (period - 1) + Math.max(change, 0)) / period;
    avgLoss = (avgLoss * (period - 1) + Math.max(-change, 0)) / period;
    out[i] = rsiValue(avgGain, avgLoss);
  }
  return out;
}

export interface MACD { line: Series; signal: Series; histogram: Series }

export function macd(values: number[], fast: number, slow: number, signal: number): MACD {
  const n = values.length;
  const line = blank(n), signalLine = blank(n), histogram = blank(n);
  if (!(fast > 0 && slow > fast && signal > 0 && n >= slow)) return { line, signal: signalLine, histogram };
  const fastEMA = ema(values, fast);
  const slowEMA = ema(values, slow);
  const defined: number[] = [];
  let firstIndex: number | undefined;
  for (let i = 0; i < n; i++) {
    const f = fastEMA[i], s = slowEMA[i];
    if (f !== undefined && s !== undefined) {
      line[i] = f - s;
      defined.push(f - s);
      if (firstIndex === undefined) firstIndex = i;
    }
  }
  if (firstIndex !== undefined) {
    const sig = ema(defined, signal);
    for (let offset = 0; offset < sig.length; offset++) {
      const value = sig[offset], l = line[firstIndex + offset];
      if (value === undefined || l === undefined) continue;
      signalLine[firstIndex + offset] = value;
      histogram[firstIndex + offset] = l - value;
    }
  }
  return { line, signal: signalLine, histogram };
}

export interface Bollinger { upper: Series; middle: Series; lower: Series }

/** Bollinger Bands with the population standard deviation (the standard definition). */
export function bollinger(values: number[], period: number, deviations: number): Bollinger {
  const n = values.length;
  const middle = sma(values, period);
  const upper = blank(n), lower = blank(n);
  if (!(period > 0) || n < period) return { upper, middle, lower };
  for (let i = period - 1; i < n; i++) {
    const mean = middle[i];
    if (mean === undefined) continue;
    let sumSquares = 0;
    for (let j = i - period + 1; j <= i; j++) {
      const d = values[j] - mean;
      sumSquares += d * d;
    }
    const sd = Math.sqrt(sumSquares / period);
    upper[i] = mean + deviations * sd;
    lower[i] = mean - deviations * sd;
  }
  return { upper, middle, lower };
}

/** Wilder's Average True Range. First value at index `period`. */
export function atr(bars: Bar[], period: number): Series {
  const out = blank(bars.length);
  if (!(period > 0) || bars.length <= period) return out;
  const trueRanges = new Array<number>(bars.length).fill(0);
  for (let i = 1; i < bars.length; i++) {
    const prevClose = bars[i - 1].close;
    trueRanges[i] = Math.max(bars[i].high - bars[i].low, Math.abs(bars[i].high - prevClose), Math.abs(bars[i].low - prevClose));
  }
  let sum = 0;
  for (let i = 1; i <= period; i++) sum += trueRanges[i];
  let value = sum / period;
  out[period] = value;
  for (let i = period + 1; i < bars.length; i++) {
    value = (value * (period - 1) + trueRanges[i]) / period;
    out[i] = value;
  }
  return out;
}

/**
 * Highest value of the `period` bars *before* each bar (the bar itself is excluded, so
 * "close above the prior 20-day high" is a real breakout test).
 */
export function priorHighest(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length <= period) return out;
  for (let i = period; i < values.length; i++) {
    let best = values[i - period];
    for (let j = i - period + 1; j < i; j++) if (values[j] > best) best = values[j];
    out[i] = best;
  }
  return out;
}

export function priorLowest(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length <= period) return out;
  for (let i = period; i < values.length; i++) {
    let best = values[i - period];
    for (let j = i - period + 1; j < i; j++) if (values[j] < best) best = values[j];
    out[i] = best;
  }
  return out;
}

/** Percent change over `period` bars. */
export function rateOfChange(values: number[], period: number): Series {
  const out = blank(values.length);
  if (!(period > 0) || values.length <= period) return out;
  for (let i = period; i < values.length; i++) {
    if (values[i - period] > 0) out[i] = (values[i] / values[i - period] - 1) * 100;
  }
  return out;
}

export const Indicators = { sma, ema, rsi, macd, bollinger, atr, priorHighest, priorLowest, rateOfChange };
