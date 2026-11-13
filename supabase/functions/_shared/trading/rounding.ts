// One place for every rounding rule. A port of TradingCore/Sources/TradingCore/Rounding.swift;
// the shared vectors (TradingCore/Tests/Vectors/rounding.json) keep the two in step.

import { cFixed } from "./text.ts";

const POWERS_OF_TEN = [1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18,
  1e19, 1e20, 1e21, 1e22];

function powerOfTen(places: number): number {
  return Number.isInteger(places) && places >= 0 && places < POWERS_OF_TEN.length ? POWERS_OF_TEN[places] : Math.pow(10, places);
}

/** Nearest integer, halves away from zero — Swift's `.rounded()`. (Math.round sends -2.5 to -2.) */
export function roundAway(x: number): number {
  if (!Number.isFinite(x)) return x;
  const whole = Math.trunc(x);
  return Math.abs(x - whole) >= 0.5 ? whole + (x < 0 ? -1 : 1) : whole;
}

/**
 * Swift's `max(x, y)` and `min(x, y)`. They differ from Math.max / Math.min on signed
 * zeros: `max(0, -0.0)` is -0.0 in Swift, which then prints as "-0.0%". Use these wherever
 * the Swift writes `max(0, something)` and the result reaches text.
 */
export function swiftMax(x: number, y: number): number {
  return y >= x ? y : x;
}

export function swiftMin(x: number, y: number): number {
  return y < x ? y : x;
}

/** Half away from zero at `places` decimal places. */
export function round(x: number, places: number): number {
  if (!Number.isFinite(x)) return x;
  const m = powerOfTen(places);
  return roundAway(x * m) / m;
}

/** Cash amounts are kept to the cent. */
export function money(x: number): number {
  return round(x, 2);
}

/** Decimal places implied by an increment (0.01 → 2, 0.00000001 → 8, 1 → 0). */
export function decimals(increment: number): number {
  if (!(increment > 0 && increment < 1)) return 0;
  let places = 0;
  let value = increment;
  while (places < 10 && Math.abs(value - roundAway(value)) > 1e-9) {
    value *= 10;
    places += 1;
  }
  return places;
}

/**
 * The largest multiple of `increment` that is not above `x`.
 * The small tolerance stops 0.3 / 0.1 (2.9999999999999996) flooring to 2.
 */
export function floor(x: number, increment: number): number {
  if (!(increment > 0) || !Number.isFinite(x)) return x;
  const steps = Math.floor(x / increment + 1e-9);
  return round(steps * increment, decimals(increment));
}

/** The nearest multiple of `increment`. */
export function nearest(x: number, increment: number): number {
  if (!(increment > 0) || !Number.isFinite(x)) return x;
  const steps = roundAway(x / increment);
  return round(steps * increment, decimals(increment));
}

/** Whether `x` sits on the increment grid. */
export function isMultiple(x: number, increment: number): boolean {
  if (!(increment > 0)) return true;
  return Math.abs(nearest(x, increment) - x) <= increment * 1e-6;
}

/** A plain decimal string at the increment's precision ("0.00012300", never "1.23e-4"). */
export function string(x: number, increment: number): string {
  return cFixed(x, decimals(increment));
}

export const Rounding = { round, money, decimals, floor, nearest, isMultiple, string, roundAway, swiftMax, swiftMin };
