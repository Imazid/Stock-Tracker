import { ECB_LOOKBACK_DAYS, ecbRate, ecbURL, isoDay, offsetDay, parseECBObservations } from "../../../../supabase/functions/_shared/fx/ecb.ts";
import type { ExposureCurrency, PortfolioReferenceRates } from "../../lib/portfolio-exposure.ts";

// The quote currencies of the supported exchanges, plus both reporting currencies.
const currencies = ["AUD", "CHF", "GBP", "HKD", "INR", "JPY", "KRW", "SGD", "USD"];
const bases: ExposureCurrency[] = ["AUD", "USD"];

export async function portfolioReferenceRates(signal: AbortSignal, request = fetch, now = Date.now()): Promise<PortfolioReferenceRates> {
  const today = isoDay(now);
  const from = offsetDay(today, -ECB_LOOKBACK_DAYS);
  const response = await request(ecbURL(currencies, from, today), {
    redirect: "error",
    signal: AbortSignal.any([signal, AbortSignal.timeout(12_000)]),
    next: { revalidate: 1800 },
  });
  if (!response.ok || response.status === 204) throw new Error("ECB reference rates unavailable");
  const csv = await response.text();
  const observations = csv.length <= 32_768 ? parseECBObservations(csv, currencies, from, today) : undefined;
  if (!observations?.size) throw new Error("ECB reference rates unreadable");

  const rates: PortfolioReferenceRates = { AUD: {}, USD: {} };
  for (const base of bases) {
    for (const currency of [...currencies, "EUR"]) {
      if (currency === base) continue;
      const rate = ecbRate(observations, currency, base, today);
      if (rate) rates[base][currency] = rate;
    }
  }
  return rates;
}
