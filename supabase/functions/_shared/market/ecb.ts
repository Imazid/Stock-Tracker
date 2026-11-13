import { compare, div, isDecimal, isZero, round } from "../decimal.ts";

const header = "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE";
const dayMs = 86_400_000;
export const ECB_LOOKBACK_DAYS = 7;
export const ECB_FIRST_DATE = "1999-01-04";

export function isoDay(timestamp: number) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

export function validISODay(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const time = Date.parse(value + "T00:00:00Z");
  return Number.isFinite(time) && isoDay(time) === value;
}

export function offsetDay(day: string, days: number) {
  return isoDay(Date.parse(day + "T00:00:00Z") + days * dayMs);
}

export function ecbURL(currencies: string[], from: string, through: string) {
  const url = new URL(`https://data-api.ecb.europa.eu/service/data/EXR/D.${currencies.join("+")}.EUR.SP00.A`);
  url.search = new URLSearchParams({ startPeriod: from, endPeriod: through, format: "csvdata", detail: "dataonly" }).toString();
  return url;
}

type Observations = Map<string, Map<string, string>>;
export type ECBRate = { date: string; rate: string };

export function parseECBObservations(csv: string, currencies: string[], from: string, through: string): Observations | undefined {
  const [columns, ...rows] = csv.trim().split(/\r?\n/);
  if (columns !== header) return undefined;
  const days: Observations = new Map();
  for (const row of rows) {
    const [key, frequency, code, denominator, type, suffix, day, value] = row.split(",");
    if (frequency !== "D" || denominator !== "EUR" || type !== "SP00" || suffix !== "A" ||
        key !== `EXR.D.${code}.EUR.SP00.A` || !currencies.includes(code) || !validISODay(day) ||
        day < ECB_FIRST_DATE || day < from || day > through || !isDecimal(value) || value.length > 18 || isZero(value)) continue;
    const rates = days.get(day) ?? new Map<string, string>();
    rates.set(code, value);
    days.set(day, rates);
  }
  return days;
}

export function ecbRate(observations: Observations, currency: string, target: string, day: string): ECBRate | undefined {
  for (let offset = 0; offset <= ECB_LOOKBACK_DAYS; offset++) {
    const date = offsetDay(day, -offset);
    const row = observations.get(date);
    const sourceUnits = currency === "EUR" ? "1" : row?.get(currency);
    const targetUnits = target === "EUR" ? "1" : row?.get(target);
    if (!sourceUnits || !targetUnits) continue;
    const rate = round(div(targetUnits, sourceUnits, 13), 12);
    if (!isZero(rate) && compare(rate, "1000000000000") < 0) return { date, rate };
  }
  return undefined;
}
