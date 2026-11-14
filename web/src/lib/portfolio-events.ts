import type { Evidence, ResearchEvent } from "./research-types.ts";

export type PortfolioEventKind = "earnings" | "news" | "filings";

export type HoldingEvent = {
  instrumentId: string;
  symbol: string;
  event: ResearchEvent;
};

export type PortfolioEventGroup = {
  eligible: number;
  checked: number;
  status: "available" | "restricted" | "partial" | "unavailable" | "not_applicable";
  items: HoldingEvent[];
};

export type PortfolioEventsResponse = {
  owner: string;
  asOf: string;
  holdingsTruncated: boolean;
  groups: Record<PortfolioEventKind, PortfolioEventGroup>;
};

export function upcomingEarnings(rows: Record<string, unknown>[], symbol: string, today: string, through: string, evidence: Evidence) {
  return rows.flatMap((row): ResearchEvent[] => {
    const date = row.date;
    if (row.symbol !== symbol || typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date) ||
      date < today || date > through || !Number.isFinite(Date.parse(date)) || new Date(date).toISOString().slice(0, 10) !== date ||
      row.epsActual != null || row.revenueActual != null) return [];
    return [{ id: `${symbol}:${date}`, date, title: "Expected earnings report", category: "Earnings", evidence }];
  });
}

export function portfolioEventGroup(
  kind: PortfolioEventKind,
  eligible: number,
  configured: boolean,
  results: { instrumentId: string; symbol: string; events?: ResearchEvent[] }[],
  asOf: string,
): PortfolioEventGroup {
  const checked = results.filter(({ events }) => events !== undefined).length;
  const now = Date.parse(asOf);
  const since = now - (kind === "news" ? 7 : 30) * 86_400_000;
  const items = results.flatMap(({ instrumentId, symbol, events }) => (events ?? []).flatMap((event) => {
    const observed = Date.parse(event.evidence.publishedAt ?? event.date);
    if (!Number.isFinite(observed) || (kind !== "earnings" && (observed < since || observed > now))) return [];
    return [{ instrumentId, symbol, event }];
  })).sort((a, b) => {
    const left = Date.parse(a.event.evidence.publishedAt ?? a.event.date);
    const right = Date.parse(b.event.evidence.publishedAt ?? b.event.date);
    return (kind === "earnings" ? left - right : right - left) || a.instrumentId.localeCompare(b.instrumentId);
  });
  const seen = new Set<string>();
  const unique = items.filter(({ event, instrumentId }) => {
    const key = kind === "earnings" ? `${instrumentId}:${event.date}` : `${instrumentId}:${event.evidence.url}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  const status = eligible === 0 ? "not_applicable" : !configured ? "restricted"
    : checked === 0 ? "unavailable" : checked < eligible ? "partial" : "available";
  return { eligible, checked, status, items: unique.slice(0, 5) };
}
