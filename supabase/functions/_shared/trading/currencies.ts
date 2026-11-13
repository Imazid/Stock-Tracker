// What the engine needs to know about each currency a practice portfolio can hold.
// A port of TradingCore/Sources/TradingCore/Currencies.swift.

// (No imports: text.ts reads this file, and everything else reads text.ts.)

/** Nearest integer, halves away from zero — Swift's `.rounded()`. */
function roundAway(x: number): number {
  const whole = Math.trunc(x);
  return Math.abs(x - whole) >= 0.5 ? whole + (x < 0 ? -1 : 1) : whole;
}

export const supportedCurrencies = ["USD", "AUD", "GBP", "EUR", "CHF", "JPY", "HKD", "SGD", "KRW", "INR"];

export const isSupportedCurrency = (code: string): boolean => supportedCurrencies.includes(code);

/** The prefix used in amounts. USD keeps a bare "$" here. */
export function currencySymbol(code: string): string {
  switch (code) {
    case "USD": return "$";
    case "AUD": return "A$";
    case "GBP": return "£";
    case "EUR": return "€";
    case "CHF": return "CHF ";
    case "JPY": return "¥";
    case "HKD": return "HK$";
    case "SGD": return "S$";
    case "KRW": return "₩";
    case "INR": return "₹";
    default: return `${code} `;
  }
}

/** Minor-unit decimals used for cash amounts. */
export const currencyDecimals = (code: string): number => code === "JPY" || code === "KRW" ? 0 : 2;

/** The time zone a portfolio in this currency counts its trading day in. */
export function currencyTimeZone(code: string): string {
  switch (code) {
    case "AUD": return "Australia/Sydney";
    case "GBP": return "Europe/London";
    case "EUR": return "Europe/Paris";
    case "CHF": return "Europe/Zurich";
    case "JPY": return "Asia/Tokyo";
    case "HKD": return "Asia/Hong_Kong";
    case "SGD": return "Asia/Singapore";
    case "KRW": return "Asia/Seoul";
    case "INR": return "Asia/Kolkata";
    default: return "America/New_York";
  }
}

/**
 * Roughly how many units of the currency buy one US dollar. Used ONLY to scale defaults (a
 * sensible starting budget, a liquidity floor) so they mean about the same everywhere. It
 * never converts money: practice portfolios hold one currency and are never mixed.
 */
export function roughUnitsPerUSD(code: string): number {
  switch (code) {
    case "AUD": return 1.5;
    case "GBP": return 0.8;
    case "EUR": case "CHF": return 0.9;
    case "JPY": return 150;
    case "HKD": return 7.8;
    case "SGD": return 1.3;
    case "KRW": return 1_400;
    case "INR": return 85;
    default: return 1;
  }
}

/** A round multiplier for budget limits and suggestions (1 for the dollar-like currencies). */
function budgetScale(code: string): number {
  switch (code) {
    case "JPY": return 100;
    case "HKD": return 10;
    case "KRW": return 1_000;
    case "INR": return 100;
    default: return 1;
  }
}

/** The smallest and largest practice budget allowed in this currency. */
export function budgetRange(code: string): { lowerBound: number; upperBound: number } {
  const scale = budgetScale(code);
  return { lowerBound: 100 * scale, upperBound: 10_000_000 * scale };
}

/** A starting budget large enough to buy a normal trading lot of a large company there. */
export const defaultBudget = (code: string): number => code === "JPY" ? 5_000_000 : 10_000 * budgetScale(code);

/** Suggested starting balances for a new practice portfolio. */
export function balanceChoices(code: string): number[] {
  if (code === "JPY") return [1_000_000, 5_000_000, 10_000_000, 30_000_000];
  const scale = budgetScale(code);
  return [5_000, 10_000, 25_000, 100_000].map((amount) => amount * scale);
}

/**
 * The smallest average daily traded value an agent may buy into: about US$1 million,
 * rounded to one significant figure. (Swift finds the power of ten with log10 and pow;
 * here it is found by stepping, which gives the same number without relying on either.)
 */
export function liquidityFloor(code: string): number {
  const raw = 1_000_000 * roughUnitsPerUSD(code);
  let magnitude = 1;
  while (magnitude * 10 <= raw) magnitude *= 10;
  return roundAway(raw / magnitude) * magnitude;
}

export const Currencies = {
  supported: supportedCurrencies, isSupported: isSupportedCurrency, symbol: currencySymbol, decimals: currencyDecimals,
  timeZone: currencyTimeZone, roughUnitsPerUSD, budgetRange, defaultBudget, balanceChoices, liquidityFloor,
};
