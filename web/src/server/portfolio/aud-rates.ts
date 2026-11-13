import {
  ECB_FIRST_DATE, ECB_LOOKBACK_DAYS, ecbRate, ecbURL, offsetDay, parseECBObservations,
  type ECBRate,
} from "../../../../supabase/functions/_shared/market/ecb.ts";
import { sydneyDate } from "./lots.ts";
import type { TransactionRow } from "./transactions.ts";

export type AudReference =
  | { source: "AUD input"; rate: "1" }
  | ({ source: "ECB reference" } & ECBRate)
  | { source: "Original currency missing" | "Position snapshot" | "Original amounts missing" |
      "Trade date unavailable" | "No ECB reference rate" | "ECB lookup unavailable" };

function directAudReference(transaction: TransactionRow, day: string | null, today: string): AudReference | undefined {
  const source = transaction.trade_provenance;
  if (source?.source === "broker_position" || source?.source === "csv_position") return { source: "Position snapshot" };
  if (!source?.currency || !/^[A-Z]{3}$/.test(source.currency)) return { source: "Original currency missing" };
  if (source.unitPrice == null && source.fees == null) return { source: "Original amounts missing" };
  if (!day || day > today) return { source: "Trade date unavailable" };
  if (source.currency === "AUD") return { source: "AUD input", rate: "1" };
  if (day < ECB_FIRST_DATE) return { source: "No ECB reference rate" };
}

export async function audReferences(transactions: TransactionRow[], signal: AbortSignal, request = fetch, now = Date.now()) {
  const references = new Map<string, AudReference>();
  const today = sydneyDate(new Date(now).toISOString())!;
  type Trade = { id: string; day: string; currency: string };
  const byYear = new Map<string, Trade[]>();
  for (const trade of transactions) {
    const day = sydneyDate(trade.transaction_date);
    const direct = directAudReference(trade, day, today);
    if (direct) {
      references.set(trade.id, direct);
      continue;
    }
    if (!day || !trade.trade_provenance?.currency) continue;
    const year = day.slice(0, 4);
    const batch = byYear.get(year) ?? [];
    batch.push({ id: trade.id, day, currency: trade.trade_provenance.currency });
    byYear.set(year, batch);
  }

  const batches = [...byYear].sort(([a], [b]) => b.localeCompare(a));
  const deadline = AbortSignal.any([signal, AbortSignal.timeout(24_000)]);
  // A year of daily rates covers every selected trade with one request. Limit
  // simultaneous calls and give older years a separate fetch when needed.
  async function loadBatches() {
    while (batches.length) {
      const [year, trades] = batches.shift()!;
      const from = offsetDay(year + "-01-01", -ECB_LOOKBACK_DAYS);
      const yearEnd = year + "-12-31";
      const through = yearEnd < today ? yearEnd : today;
      const currencies = [...new Set(["AUD", ...trades.map((trade) => trade.currency).filter((code) => code !== "EUR")])].sort();
      const url = ecbURL(currencies, from, through);
      let observations;
      let unavailable = false;
      try {
        const response = await request(url, {
          redirect: "error",
          signal: AbortSignal.any([deadline, AbortSignal.timeout(9500)]),
          next: { revalidate: yearEnd < today ? 86_400 : 3600 },
        });
        if (response.ok && response.status !== 204) {
          const csv = await response.text();
          observations = csv.length <= 2_000_000 ? parseECBObservations(csv, currencies, from, through) : undefined;
          unavailable = observations === undefined;
        } else {
          unavailable = response.status !== 204 && response.status !== 404;
        }
      } catch {
        unavailable = true;
      }
      for (const { id, day, currency } of trades) {
        const rate = observations && ecbRate(observations, currency, "AUD", day);
        references.set(id, rate ? { source: "ECB reference", ...rate }
          : { source: unavailable ? "ECB lookup unavailable" : "No ECB reference rate" });
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(batches.length, 3) }, loadBatches));
  return references;
}
