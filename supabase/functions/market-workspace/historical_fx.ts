import { compare, div, isDecimal, isZero, mul, round } from "../_shared/decimal.ts";
import { HttpError } from "../_shared/server/http.ts";

const LOOKBACK_DAYS = 7;
const MAX_AMOUNT = "9999999999999.99";
const DAY = 86_400_000;
const MIN_DATE = "1999-01-04";

type Reference = { date: string; usdPerUnit: string };
type CacheEntry = { expires: number; pending: Promise<Reference> };
const cache = new Map<string, CacheEntry>();

function isoDate(timestamp: number) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

function validDate(date: unknown): date is string {
  if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return false;
  const time = Date.parse(date + "T00:00:00Z");
  return Number.isFinite(time) && isoDate(time) === date;
}

async function readReference(currency: string, date: string, request: typeof fetch): Promise<Reference> {
  const from = isoDate(Date.parse(date + "T00:00:00Z") - LOOKBACK_DAYS * DAY);
  const keys = currency === "EUR" ? "USD" : `USD+${currency}`;
  const url = new URL(`https://data-api.ecb.europa.eu/service/data/EXR/D.${keys}.EUR.SP00.A`);
  url.search = new URLSearchParams({ startPeriod: from, endPeriod: date, format: "csvdata", detail: "dataonly" }).toString();

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

  const [header, ...rows] = csv.trim().split(/\r?\n/);
  if (csv.length > 16_384 || header !== "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE") {
    throw new HttpError(502, "invalid_fx_data", "The ECB returned an unreadable exchange-rate response.");
  }
  const days = new Map<string, Map<string, string>>();
  for (const row of rows) {
    const [key, frequency, code, denominator, type, suffix, day, value] = row.split(",");
    if (frequency !== "D" || denominator !== "EUR" || type !== "SP00" || suffix !== "A" ||
      key !== `EXR.D.${code}.EUR.SP00.A` || (code !== "USD" && code !== currency) ||
      !validDate(day) || day < MIN_DATE || day < from || day > date || !isDecimal(value) || value.length > 18 || isZero(value)) continue;
    const observations = days.get(day) ?? new Map<string, string>();
    observations.set(code, value);
    days.set(day, observations);
  }
  for (const day of [...days.keys()].sort().reverse()) {
    const observations = days.get(day)!;
    const dollars = observations.get("USD");
    const units = currency === "EUR" ? "1" : observations.get(currency);
    if (!dollars || !units) continue;
    const rate = round(div(dollars, units, 13), 12);
    if (!isZero(rate) && compare(rate, "1000000000000") < 0) return { date: day, usdPerUnit: rate };
  }
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
  if (!validDate(date) || date < MIN_DATE || date > isoDate(now)) {
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
