import { type Instrument, instrumentID } from "@engine/market.ts";
import type { CompanyReport } from "@/lib/research-types";
import { getCandles, getQuote } from "@/server/market/service";
import { getResearch, parseFilters } from "./service";

export async function companyReport(instrument: Instrument, publicOnly = false): Promise<CompanyReport> {
  const filters = { ...parseFilters(new URLSearchParams({ limit: "8" })), publicOnly };
  const [overview, valuation, events, ownership, earnings, peers, quote, chart] = await Promise.all([
    getResearch(instrument, "overview", filters),
    getResearch(instrument, "valuation", filters),
    getResearch(instrument, "events", filters),
    getResearch(instrument, "ownership", { ...filters, limit: 4 }),
    getResearch(instrument, "earnings", filters),
    getResearch(instrument, "peers", filters),
    getQuote(instrument).then((r) => r.quote).catch(() => undefined),
    getCandles(instrument, "1Y").catch(() => undefined),
  ]);
  const first = chart?.candles[0];
  const last = chart?.candles.at(-1);
  const history = chart && first && last && first.time !== last.time && first.close > 0 ? {
    first: new Date(first.time * 1000).toISOString(), last: new Date(last.time * 1000).toISOString(),
    changePct: (last.close / first.close - 1) * 100, source: chart.source, adjustment: chart.adjustment, currency: chart.currency,
  } : undefined;
  const marketCoverage = [
    { dataset: "Latest quote", status: quote ? quote.stale ? "historical" : quote.status === "delayed" ? "delayed" : "available" : "unavailable",
      detail: quote ? `${quote.source} · ${quote.status.replaceAll("_", " ")}` : "The connected market feeds could not price this listing.", refreshedAt: quote?.fetchedAt },
    { dataset: "Price history", status: history ? "historical" : "unavailable",
      detail: history ? `${history.source} · ${history.adjustment}` : "The market feeds returned insufficient history for a one-year comparison.", refreshedAt: chart?.fetchedAt },
  ] as const;
  return {
    instrumentId: instrumentID(instrument), asOf: filters.asOf,
    profile: overview.profile, facts: valuation.facts ?? [], multiples: valuation.records ?? [], events: events.events ?? [], ownership: ownership.events ?? [],
    earnings: (earnings.records ?? []).slice(0, 10), peers: (peers.records ?? []).slice(0, 10),
    quote, history, links: events.links,
    coverage: [...new Map([...overview.coverage, ...valuation.coverage, ...events.coverage, ...ownership.coverage, ...earnings.coverage, ...peers.coverage, ...marketCoverage]
      .map((item) => [item.dataset, item])).values()],
  };
}
