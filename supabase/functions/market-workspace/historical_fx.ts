import { compare, isZero, mul, round } from "../_shared/decimal.ts";
import { ECB_FIRST_DATE, ECB_LOOKBACK_DAYS, ecbRate, ecbURL, isoDay, offsetDay, parseECBObservations, validISODay } from "../_shared/fx/ecb.ts";
import { HttpError } from "../_shared/server/http.ts";

const MAX_AMOUNT = "9999999999999.99";

type Reference = { date: string; usdPerUnit: string };
type CacheEntry = { expires: number; pending: Promise<Reference> };
const cache = new Map<string, CacheEntry>();

async function readReference(currency: string, date: string, request: typeof fetch): Promise<Reference> {
  const from = offsetDay(date, -ECB_LOOKBACK_DAYS);
  const currencies = currency === "EUR" ? ["USD"] : ["USD", currency];
  const url = ecbURL(currencies, from, date);

  let csv: string;
  try {
    const response = await request(url, { redirect: "error", signal: AbortSignal.timeout(8000) });
    if (response.status === 404 || response.status === 204) {
      throw new HttpError(404, "no_fx_rate", "No ECB reference rate is available for this currency and date.");
    }
    if (!response.ok) throw new Error("ECB request failed");
    csv = await response.text();
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(503, "fx_unavailable", "Historical exchange rates are temporarily unavailable.");
  }

  const observations = csv.length <= 16_384 ? parseECBObservations(csv, currencies, from, date) : undefined;
  if (!observations) {
    throw new HttpError(502, "invalid_fx_data", "The ECB returned an unreadable exchange-rate response.");
  }
  const result = ecbRate(observations, currency, "USD", date);
  if (result) return { date: result.date, usdPerUnit: result.rate };
  throw new HttpError(404, "no_fx_rate", "No ECB reference rate is available within seven days of this date.");
}

function reference(currency: string, date: string, now: number, request: typeof fetch): Promise<Reference> {
  const key = `${currency}/${date}`;
  const found = cache.get(key);
  if (found && found.expires > now) return found.pending;
  const pending = readReference(currency, date, request);
  if (cache.size >= 128 && !cache.has(key)) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, { expires: now + 3_600_000, pending });
  pending.catch(() => { if (cache.get(key)?.pending === pending) cache.delete(key); });
  return pending;
}

export async function historicalCashConversion(
  input: Record<string, unknown>,
  now: number,
  request: typeof fetch = fetch,
) {
  const { currency, date, amount } = input;
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency) || currency === "USD") {
    throw new HttpError(422, "invalid_fx_currency", "Select a non-USD currency code.");
  }
  if (!validISODay(date) || date < ECB_FIRST_DATE || date > isoDay(now)) {
    throw new HttpError(422, "invalid_fx_date", "Enter a historical date from 4 January 1999.");
  }
  if (typeof amount !== "string" || !/^(?:0|[1-9]\d{0,12})(?:\.\d{1,8})?$/.test(amount) || isZero(amount) || compare(amount, MAX_AMOUNT) > 0) {
    throw new HttpError(422, "invalid_fx_amount", "Enter a positive cash amount within the portfolio ledger limit.");
  }

  const observation = await reference(currency, date, now, request);
  // Only the third decimal digit is needed to round the exact product to cents.
  const product = mul(amount, observation.usdPerUnit);
  const dot = product.indexOf(".");
  const cents = round(dot < 0 ? product : product.slice(0, dot + 4), 2);
  if (isZero(cents) || compare(cents, MAX_AMOUNT) > 0) {
    throw new HttpError(422, "invalid_fx_result", "The converted amount is outside the portfolio ledger range.");
  }
  return {
    usdAmount: Number(cents),
    fx: { source: "ECB", currency, amount, usd_per_unit: observation.usdPerUnit, rate_date: observation.date },
  };
}
