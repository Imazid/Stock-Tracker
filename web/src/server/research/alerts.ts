import { createHash } from "node:crypto";
import type { CompanyAlert } from "@/lib/research-alert-types";
import type { ResearchEvent } from "@/lib/research-types";
import { parseInstrumentID } from "@/server/market/instruments";
import { getQuote } from "@/server/market/service";
import { getResearch, parseFilters } from "./service";
import { researchDatabase } from "./storage";

type ClaimedAlert = CompanyAlert & { instrument_id: string; lease_token: string; last_condition: boolean | null };
interface AlertEvent {
  event_key: string;
  title: string;
  url?: string;
  occurred_at: string;
}

function published(event: ResearchEvent) {
  return event.evidence.publishedAt ?? event.date;
}

function itemEvents(alert: ClaimedAlert, rows: ResearchEvent[]): AlertEvent[] {
  const created = Date.parse(alert.created_at);
  return rows.filter((event) => Date.parse(published(event)) >= created).map((event) => ({
    event_key: createHash("sha256").update(event.id).digest("hex"),
    title: `${event.category} · ${event.title}`,
    url: event.evidence.url,
    occurred_at: new Date(published(event)).toISOString(),
  }));
}

async function evaluate(alert: ClaimedAlert): Promise<{ condition: boolean | null; events: AlertEvent[]; problem: string | null }> {
  const instrument = parseInstrumentID(alert.instrument_id);
  if (alert.kind === "news" && process.env.RESEARCH_FMP_ALERTS !== "true") {
    return { condition: null, events: [], problem: "The news feed is disabled for alert storage." };
  }
  if (alert.kind === "filing" || alert.kind === "insider" || alert.kind === "news") {
    const section = alert.kind === "insider" ? "ownership" : "events";
    const result = await getResearch(instrument, section, { ...parseFilters(new URLSearchParams({ limit: "100" })), publicOnly: alert.kind !== "news", eventsOnly: alert.kind === "news" ? "news" : "filings" });
    const coverage = result.coverage.find((row) => row.dataset === (alert.kind === "news" ? "News" : "SEC filings"));
    const ok = coverage?.status === "available" || coverage?.status === "partial";
    const rows = (result.events ?? []).filter((event) => alert.kind === "news" ? event.category === "News" : event.evidence.provider === "SEC EDGAR");
    return { condition: null, events: itemEvents(alert, rows), problem: ok ? null : "The event feed is unavailable." };
  }

  const { quote } = await getQuote(instrument);
  const date = Date.parse(quote.observedAt);
  const maxAge = 3 * 86_400_000;
  const threshold = Number(alert.threshold);
  const volume = alert.kind === "volume_above";
  const value = volume ? quote.volumeScope === "consolidated" ? quote.volume : undefined
    : quote.currency === alert.currency ? quote.last : undefined;
  if (value === undefined || quote.stale || Date.now() - date > maxAge) {
    return { condition: null, events: [], problem: "A sufficiently recent quote in the expected currency or volume scope is unavailable." };
  }
  const condition = alert.kind === "price_below" ? value <= threshold : value >= threshold;
  const event = condition && alert.last_condition !== true && date >= Date.parse(alert.created_at) ? {
    event_key: `${alert.kind}:${quote.observedAt}`,
    title: `${instrument.symbol} ${volume ? "volume" : "price"} reached ${value} ${volume ? "shares" : quote.currency} (${quote.source}, ${quote.status.replaceAll("_", " ")})`,
    occurred_at: quote.observedAt,
  } : undefined;
  return { condition: date >= Date.parse(alert.created_at) ? condition : null, events: event ? [event] : [], problem: null };
}

export async function runCompanyAlerts() {
  const db = researchDatabase();
  if (!db) throw new Error("The company alerts worker needs a server database connection.");
  const claim = await db.rpc("claim_company_research_alerts", { batch_size: 12 });
  if (claim.error) {
    console.warn("Company research alert claim failed", claim.error.code || "transport");
    throw new Error("The company alerts worker could not claim a batch.");
  }
  const alerts = claim.data as ClaimedAlert[];
  const results = await Promise.all(alerts.map(async (alert) => {
    const { condition, events, problem } = await evaluate(alert).catch(() => ({ condition: null, events: [], problem: "The provider request did not complete." }));
    const finished = await db.rpc("finish_company_research_alert", {
      target_id: alert.id, token: alert.lease_token, observed_condition: condition, problem, new_events: events,
    });
    if (finished.error) console.warn("Company research alert finish failed", finished.error.code || "transport");
    return { finished: finished.data === true, providerProblem: Boolean(problem) };
  }));
  return { claimed: alerts.length, completed: results.filter((result) => result.finished).length, providerProblems: results.filter((result) => result.providerProblem).length };
}
