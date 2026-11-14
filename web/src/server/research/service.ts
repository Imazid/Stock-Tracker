import { instrumentID, type Instrument } from "@engine/market.ts";
import type { DatasetCoverage, FinancialFact, ResearchEvent, ResearchResponse, ResearchSection, Statement } from "@/lib/research-types";
import { cached } from "@/server/market/cache";
import { yahooTicker } from "@/server/market/yahoo";
import { annualMetrics, annualRevenue, dayOf, latestVersions, reportedOn, trailingFacts } from "@/lib/research-financials";
import { FMP, MASSIVE, fmpConfigured, fmpFacts, fmpNews, fmpProfile, fmpRecords, massiveConfigured, optionsSnapshot } from "./licensed";
import { SEC, SEC_DIRECTORY, findSecListing, secArchive, secConfigured, secDirectory, secFacts, secSubmissions, type SecListing } from "./sec";
import { readSnapshot, saveSnapshot } from "./storage";
import { ResearchProviderError } from "./upstream";

export interface ResearchFilters {
  asOf: string;
  period: FinancialFact["period"] | "all";
  statement?: Statement;
  query: string;
  page: number;
  limit: number;
  versions: boolean;
  expiry?: string;
  cursor?: string;
  archive?: number;
  publicOnly?: boolean;
  eventsOnly?: "news" | "filings";
}

export class ResearchInputError extends Error {}

export function parseFilters(params: URLSearchParams, now = Date.now()): ResearchFilters {
  const today = dayOf(now);
  const asOf = params.get("asOf") ?? today;
  const period = params.get("period") ?? "annual";
  const statement = params.get("statement") ?? undefined;
  const query = params.get("q")?.trim() ?? "";
  const page = Number(params.get("page") ?? 0);
  const limit = Number(params.get("limit") ?? 25);
  const archive = params.has("archive") ? Number(params.get("archive")) : undefined;
  const expiry = params.get("expiry") ?? undefined;
  const cursor = params.get("cursor") ?? undefined;
  const isDate = (value: string) => /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && dayOf(Date.parse(value)) === value;
  if (!isDate(asOf) || asOf > today || expiry && !isDate(expiry) || cursor && !/^[\w.=%+-]{1,700}$/.test(cursor)
      || !["annual", "quarter", "ttm", "other", "all"].includes(period)
      || statement && !["income", "balance", "cash", "other"].includes(statement)
      || query.length > 100 || !Number.isInteger(page) || page < 0 || page > 1000
      || !Number.isInteger(limit) || limit < 1 || limit > 100
      || archive !== undefined && (!Number.isInteger(archive) || archive < 0 || archive > 100)) {
    throw new ResearchInputError("Check the research filters and try again.");
  }
  return { asOf, period: period as ResearchFilters["period"], statement: statement as Statement | undefined, query, page, limit, versions: params.get("versions") === "true", expiry, cursor, archive };
}

function coverage(dataset: string, status: DatasetCoverage["status"], detail: string, refreshedAt?: string): DatasetCoverage {
  return { dataset, status, detail, refreshedAt };
}

function failure(dataset: string, error: unknown, provider: string) {
  if (error instanceof ResearchProviderError && provider === SEC && error.status === 403) {
    return coverage(dataset, "unavailable", "EDGAR denied this request. Check the operator contact and the server's SEC fair-access status.");
  }
  if (error instanceof ResearchProviderError && [401, 402, 403].includes(error.status ?? 0)) {
    return coverage(dataset, "restricted", `${provider} refused access. Check credentials and dataset entitlement.`);
  }
  return coverage(dataset, "unavailable", `${provider} could not return this dataset.`);
}

async function lookup(instrument: Instrument, target: ResearchResponse): Promise<SecListing | undefined> {
  if (instrument.venue !== "us") return;
  if (!secConfigured()) {
    target.coverage.push(coverage("SEC issuer directory", "unavailable", "EDGAR access is awaiting an operator contact."));
    return;
  }
  try {
    const listing = findSecListing(await secDirectory(), instrument.symbol);
    if (!listing) target.coverage.push(coverage("SEC issuer directory", "unavailable", "No unambiguous current ticker mapping. Historical and delisted listings may require a security master."));
    return listing;
  } catch (error) {
    target.coverage.push(failure("SEC issuer directory", error, SEC));
  }
}

const FACT_TTL = 45 * 60_000;
const STALE_LIMIT = 14 * 86_400_000;

async function statements(id: string, listing: SecListing) {
  return cached(`research:sec:facts:${listing.cik}:${id}`, FACT_TTL, async () => {
    const saved = await readSnapshot(id, listing).catch(() => undefined);
    if (saved && Date.now() - Date.parse(saved.retrievedAt) < FACT_TTL) return { ...saved, stale: false };
    try {
      const facts = await secFacts(listing);
      const retrievedAt = facts[0]?.evidence.retrievedAt ?? new Date().toISOString();
      if (facts.length) await saveSnapshot(id, listing, facts, retrievedAt).catch(() => console.warn("Company research snapshot could not be persisted"));
      return { facts, retrievedAt, stale: false };
    } catch (error) {
      if (saved && Date.now() - Date.parse(saved.retrievedAt) < STALE_LIMIT) return { ...saved, stale: true };
      throw error;
    }
  });
}

const EARNINGS_KEYS = { epsActual: "Actual EPS", epsEstimated: "Estimated EPS", revenueActual: "Actual revenue", revenueEstimated: "Estimated revenue" };
const ESTIMATE_KEYS = { epsAvg: "Consensus EPS", revenueAvg: "Consensus revenue", numAnalystsEps: "EPS analyst count", numAnalystsRevenue: "Revenue analyst count" };
const INSIDER_KEYS = { reportingName: "Insider", transactionType: "Transaction", securitiesTransacted: "Shares", price: "Price", filingDate: "Filed" };
const MULTIPLE_KEYS = {
  priceToEarningsRatioTTM: "P/E (×)", priceToBookRatioTTM: "P/B (×)", priceToSalesRatioTTM: "Price / sales (×)",
  priceToFreeCashFlowRatioTTM: "Price / FCF (×)", enterpriseValueMultipleTTM: "EV / EBITDA (×)",
  debtToEquityRatioTTM: "Debt / equity (×)", quickRatioTTM: "Quick ratio (×)", currentRatioTTM: "Current ratio (×)",
};
const PEER_KEYS = { companyName: "Company", mktCap: "Market cap", stockPrice: "Price" };

function byPublication(event: ResearchEvent) {
  return event.evidence.publishedAt ?? event.date;
}

export async function getResearch(instrument: Instrument, section: ResearchSection, filters: ResearchFilters): Promise<ResearchResponse> {
  const id = instrumentID(instrument);
  const symbol = yahooTicker(instrument);
  const result: ResearchResponse = { instrumentId: id, asOf: filters.asOf, coverage: [] };
  if (instrument.venue === "crypto") {
    result.coverage.push(coverage("Company research", "not_applicable", "This instrument is a cryptocurrency."));
    return result;
  }

  const historical = filters.asOf < dayOf(Date.now());
  const useFmp = fmpConfigured() && !historical && !filters.publicOnly;
  const fmpUnavailable = historical ? "Current vendor data is excluded from historical views." :
    filters.publicOnly ? "This vendor dataset has not been enabled for AI processing." : "An FMP display entitlement has not been enabled.";
  const secRelevant = filters.eventsOnly !== "news" && ["overview", "financials", "valuation", "events", "ownership"].includes(section);
  const listing = secRelevant ? await lookup(instrument, result) : undefined;

  if (section === "overview") {
    if (listing && !historical) {
      try {
        result.profile = (await secSubmissions(listing)).profile;
        result.coverage.push(coverage("Issuer profile", "partial", "SEC filer identity, industry and business address.", result.profile.evidence.retrievedAt));
      } catch (error) {
        result.coverage.push(failure("Issuer profile", error, SEC));
        result.profile = { name: listing.name, exchange: listing.exchange, cik: listing.cik,
          evidence: { provider: SEC, url: SEC_DIRECTORY, license: "public_filing", retrievedAt: new Date().toISOString() } };
      }
    }
    if (useFmp) {
      try {
        const profile = await fmpProfile(symbol);
        if (profile) {
          result.profile = profile;
          result.coverage.push(coverage("Business profile", "partial", "Profile, leadership summary and listing identifiers when supplied.", profile.evidence.retrievedAt));
        } else result.coverage.push(coverage("Business profile", "unavailable", "No provider profile matched this exact listing."));
      } catch (error) {
        result.coverage.push(failure("Business profile", error, FMP));
      }
    } else result.coverage.push(coverage("Business profile", historical ? "unavailable" : "restricted", fmpUnavailable));
    return result;
  }

  if (section === "financials" || section === "valuation") {
    let available: FinancialFact[] = [];
    if (listing) {
      try {
        const { facts, retrievedAt, stale } = await statements(id, listing);
        available = reportedOn(facts, filters.asOf);
        result.coverage.push(coverage("Reported SEC XBRL", available.length ? stale || historical ? "historical" : "partial" : "unavailable",
          stale ? "SEC refresh failed. Showing the last successful snapshot." : "Issuer-wide XBRL observations. Open the underlying filing for statement layout, segments and issuer-specific detail.", retrievedAt));
      } catch (error) {
        result.coverage.push(failure("Reported SEC XBRL", error, SEC));
      }
    }
    if (section === "valuation") {
      const latest = latestVersions(available);
      const revenue = annualRevenue(latest);
      result.facts = [...(revenue ? [revenue] : []), ...annualMetrics(latest)];
      if (!result.facts.length) result.coverage.push(coverage("Calculated ratios", "unavailable", "Matching reported annual inputs are unavailable. The scenario calculator accepts explicit assumptions."));
      if (useFmp) {
        try {
          result.records = await fmpRecords("ratios-ttm", symbol, MULTIPLE_KEYS, "Provider TTM multiples");
          result.coverage.push(coverage("Current market multiples", result.records.length ? "partial" : "unavailable",
            "Provider-calculated snapshot. The source does not identify the observation time for these multiples.", result.records[0]?.evidence.retrievedAt));
        } catch (error) {
          result.coverage.push(failure("Current market multiples", error, FMP));
        }
      } else result.coverage.push(coverage("Current market multiples", historical ? "unavailable" : "restricted", fmpUnavailable));
      return result;
    }
    const filter = (fact: FinancialFact) => (filters.period === "all" || filters.period === fact.period)
      && (!filters.statement || filters.statement === fact.statement)
      && (!filters.query || `${fact.label} ${fact.concept} ${fact.unit}`.toLowerCase().includes(filters.query.toLowerCase()));
    let facts = (filters.period === "ttm" ? trailingFacts(available) : filters.versions ? available : latestVersions(available)).filter(filter);
    if (!available.length && useFmp && (filters.period === "annual" || filters.period === "quarter")) {
      try {
        const fallback = await fmpFacts(symbol, filters.period);
        facts = latestVersions(reportedOn(fallback.facts, filters.asOf)).filter(filter);
        result.coverage.push(coverage("Normalised statements", fallback.facts.length ? "partial" : "unavailable",
          "FMP rows are a separate fallback. Only rows with a reported currency and filing date are included.", fallback.facts[0]?.evidence.retrievedAt));
      } catch (error) {
        result.coverage.push(failure("Normalised statements", error, FMP));
      }
    }
    if (!available.length && !useFmp) result.coverage.push(coverage("Normalised statements", historical ? "unavailable" : "restricted", fmpUnavailable));
    result.total = facts.length;
    result.facts = facts.slice(filters.page * filters.limit, (filters.page + 1) * filters.limit);
    result.exportAllowed = result.facts.length > 0 && result.facts.every((fact) => fact.evidence.license === "public_filing");
    return result;
  }

  if (section === "events" || section === "ownership") {
    const events: ResearchEvent[] = [];
    if (instrument.venue === "asx") {
      result.links = [{ label: `${instrument.symbol} on ASX`, url: `https://www.asx.com.au/markets/company/${encodeURIComponent(instrument.symbol)}` }];
      result.coverage.push(coverage("ASX announcements", "restricted", "Announcements are linked at the exchange. An announcement feed is required to ingest them."));
    }
    if (listing) {
      try {
        const data = await secSubmissions(listing);
        events.push(...data.events);
        if (filters.archive !== undefined && data.archives[filters.archive]) {
          try {
            events.push(...await secArchive(listing.cik, data.archives[filters.archive]));
          } catch (error) {
            result.coverage.push(failure("SEC archive batch", error, SEC));
          }
        }
        result.archiveCount = data.archives.length;
        result.coverage.push(coverage("SEC filings", "partial", "Recent submissions with optional historical archive batches.", data.profile.evidence.retrievedAt));
      } catch (error) {
        result.coverage.push(failure("SEC filings", error, SEC));
      }
    }
    if (section === "events" && useFmp && filters.eventsOnly !== "filings") {
      try {
        const news = await fmpNews(symbol);
        events.push(...news);
        result.coverage.push(coverage("News", news.length ? "available" : "unavailable", "Recent linked articles from the licensed news feed.", news[0]?.evidence.retrievedAt));
      } catch (error) {
        result.coverage.push(failure("News", error, FMP));
      }
    } else if (section === "events" && filters.eventsOnly !== "filings") result.coverage.push(coverage("News", historical ? "unavailable" : "restricted", fmpUnavailable));
    if (section === "ownership") {
      result.coverage.push(coverage("Institutional positions and short interest", "restricted", "A licensed positions and short-interest dataset is required."));
    }
    const unique = new Map<string, ResearchEvent>();
    for (const event of events) {
      if (byPublication(event).slice(0, 10) > filters.asOf) continue;
      if (section === "ownership" && !/^(3|4|5|13[DFG]|SC 13[DG]|SCHEDULE 13[DG])(?:[- /]|$)/i.test(event.category)) continue;
      if (filters.query && !`${event.title} ${event.category}`.toLowerCase().includes(filters.query.toLowerCase())) continue;
      unique.set(event.id, event);
    }
    const filtered = [...unique.values()].sort((a, b) => byPublication(b).localeCompare(byPublication(a)));
    result.total = filtered.length;
    result.events = filtered.slice(filters.page * filters.limit, (filters.page + 1) * filters.limit);
    if (section === "events" || !useFmp) return result;
  }

  if (section === "options") {
    if (instrument.venue !== "us" || !massiveConfigured() || historical || filters.publicOnly) {
      result.coverage.push(coverage("Options snapshots", historical ? "unavailable" : "restricted",
        filters.publicOnly ? "This vendor dataset has not been enabled for AI processing." : "Current US chains require a Massive options display entitlement."));
      return result;
    }
    try {
      const chain = await optionsSnapshot(instrument.symbol, filters.expiry, filters.cursor);
      result.records = chain.records;
      result.next = chain.next;
      result.coverage.push(coverage("Options snapshots", chain.records.length ? "partial" : "unavailable",
        "Field coverage and quote delay depend on entitlement. Times and feed status appear when supplied.", chain.records[0]?.evidence.retrievedAt));
    } catch (error) {
      result.coverage.push(failure("Options snapshots", error, MASSIVE));
    }
    return result;
  }

  if (!useFmp) {
    result.coverage.push(coverage(section === "earnings" ? "Earnings and estimates" : "Peer set", historical ? "unavailable" : "restricted", fmpUnavailable));
    return result;
  }
  const requests = section === "earnings" ? [
    ["earnings", EARNINGS_KEYS, "Earnings release", { limit: "30" }],
    ["analyst-estimates", ESTIMATE_KEYS, "Consensus estimate", { period: "annual", page: "0", limit: "12" }],
  ] as const : section === "ownership" ? [
    ["insider-trading/search", INSIDER_KEYS, "Insider transaction", { page: "0", limit: "30" }],
  ] as const : [
    ["stock-peers", PEER_KEYS, "Provider peer"],
  ] as const;
  const datasets = await Promise.all(requests.map(async ([path, fields, label, params]) => {
    try {
      const records = await fmpRecords(path, symbol, fields, label, params);
      return { records, coverage: coverage(label, records.length ? "partial" : "unavailable", "Current provider snapshot. Estimates can be revised.", records[0]?.evidence.retrievedAt) };
    } catch (error) {
      return { records: [], coverage: failure(label, error, FMP) };
    }
  }));
  result.records = datasets.flatMap((data) => data.records);
  result.coverage.push(...datasets.map((data) => data.coverage));
  return result;
}
