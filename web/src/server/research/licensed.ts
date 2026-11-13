import type { Evidence, FinancialFact, ResearchEvent, ResearchProfile, ResearchRecord } from "../../lib/research-types.ts";
import { cached } from "../market/cache.ts";
import { asNumber, asObject, asText, providerJSON, safeUrl } from "./upstream.ts";

export const FMP = "Financial Modeling Prep";
export const MASSIVE = "Massive";
export const fmpConfigured = () => process.env.RESEARCH_FMP_DISPLAY === "true" && Boolean(process.env.RESEARCH_FMP_API_KEY?.trim());
export const massiveConfigured = () => process.env.RESEARCH_MASSIVE_DISPLAY === "true" && Boolean(process.env.RESEARCH_MASSIVE_API_KEY?.trim());
const DOCS = "https://site.financialmodelingprep.com/developer/docs";
const FMP_TICKER = /^[A-Z0-9][A-Z0-9.\-&]{0,29}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const CURRENCY = /^[A-Z]{3}$/;
const isRow = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);

interface VendorRows {
  rows: Record<string, unknown>[];
  evidence: Evidence;
}

export function vendorEvidence(provider: typeof FMP | typeof MASSIVE, url: string, publishedAt?: string): Evidence {
  return { provider, url, retrievedAt: new Date().toISOString(), license: "licensed", publishedAt };
}

export async function fmpRows(path: string, query: Record<string, string>, ttl = 900_000): Promise<VendorRows> {
  return cached(`research:fmp:${path}:${new URLSearchParams(query)}`, ttl, async () => {
    const url = new URL(`https://financialmodelingprep.com/stable/${path}`);
    url.search = new URLSearchParams({ ...query, apikey: process.env.RESEARCH_FMP_API_KEY!.trim() }).toString();
    const raw = await providerJSON(url, FMP, {}, 250);
    if (!Array.isArray(raw)) throw new Error("FMP returned an unreadable dataset.");
    return { rows: raw.filter(isRow), evidence: vendorEvidence(FMP, DOCS) };
  });
}

export async function fmpProfile(symbol: string): Promise<ResearchProfile | undefined> {
  const data = await fmpRows("profile", { symbol });
  const row = data.rows.find((r) => r.symbol === symbol);
  const name = asText(row?.companyName);
  if (!row || !name) return undefined;
  const numericEmployees = typeof row.fullTimeEmployees === "string" && /^\d+$/.test(row.fullTimeEmployees) ? Number(row.fullTimeEmployees) : row.fullTimeEmployees;
  return {
    name, exchange: asText(row.exchangeFullName) ?? asText(row.exchange),
    cik: asText(row.cik), isin: asText(row.isin), cusip: asText(row.cusip),
    kind: row.isEtf === true ? "ETF" : row.isAdr === true ? "ADR" : row.isFund === true ? "Fund" : undefined,
    sector: asText(row.sector), industry: asText(row.industry),
    description: asText(row.description, 3000), website: safeUrl(row.website), logo: safeUrl(row.image),
    headquarters: [asText(row.city), asText(row.state), asText(row.country)].filter(Boolean).join(", ") || undefined,
    ceo: asText(row.ceo), employees: asNumber(numericEmployees), ipoDate: asText(row.ipoDate),
    evidence: { ...data.evidence, url: `${DOCS}/stable/profile-symbol` },
  };
}

const FMP_METADATA = new Set(["calendarYear", "fiscalYear", "date", "symbol", "period", "reportedCurrency", "cik", "filingDate", "fillingDate", "acceptedDate", "link", "finalLink"]);
const FMP_STATEMENTS = [["income-statement", "income"], ["balance-sheet-statement", "balance"], ["cash-flow-statement", "cash"]] as const;
export async function fmpFacts(symbol: string, period: "annual" | "quarter"): Promise<{ facts: FinancialFact[]; partial: boolean }> {
  const data = await Promise.allSettled(FMP_STATEMENTS.map(async ([path, statement]) => {
    const response = await fmpRows(path, { symbol, period, limit: "20" });
    return response.rows.flatMap((row): FinancialFact[] => {
      const end = asText(row.date);
      const currency = asText(row.reportedCurrency);
      const publishedAt = asText(row.filingDate ?? row.fillingDate ?? row.acceptedDate)?.slice(0, 10);
      if (row.symbol !== symbol || !end || !DATE.test(end) || !currency || !CURRENCY.test(currency) || !publishedAt || !DATE.test(publishedAt) || publishedAt < end) return [];
      return Object.entries(row).flatMap(([key, raw]) => {
        if (FMP_METADATA.has(key) || asNumber(raw) === undefined) return [];
        const label = key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (first) => first.toUpperCase());
        const unit = /^eps/i.test(key) ? `${currency}/shares` : /shares/i.test(key) ? "shares" : currency;
        return [{
          concept: `fmp:${key}`, statement, label, period, unit, value: raw as number, end,
          evidence: { ...response.evidence, url: safeUrl(row.finalLink) ?? safeUrl(row.link) ?? `${DOCS}/stable/${path}`, publishedAt },
        }];
      });
    });
  }));
  if (data.every((result) => result.status === "rejected")) throw (data[0] as PromiseRejectedResult).reason;
  return { facts: data.flatMap((result) => result.status === "fulfilled" ? result.value : []), partial: data.some((result) => result.status === "rejected" || result.value.length === 0) };
}

export async function fmpNews(symbol: string): Promise<ResearchEvent[]> {
  const { rows, evidence } = await fmpRows("news/stock", { symbols: symbol, limit: "50" });
  return rows.flatMap((row): ResearchEvent[] => {
    const url = safeUrl(row.url);
    const title = asText(row.title);
    const date = asText(row.publishedDate);
    if (row.symbol !== symbol || !url || !title || !date || !Number.isFinite(Date.parse(date))) return [];
    return [{ id: url, title, category: "News", date, publisher: asText(row.site ?? row.publisher), evidence: { ...evidence, url, publishedAt: date } }];
  });
}

export async function fmpRecords(path: string, symbol: string, keys: Record<string, string>, name: string, params: Record<string, string> = {}): Promise<ResearchRecord[]> {
  const { rows, evidence } = await fmpRows(path, { symbol, ...params });
  return rows.flatMap((row, index): ResearchRecord[] => {
    const peer = path === "stock-peers";
    const ticker = asText(row.symbol);
    if (!ticker || !FMP_TICKER.test(ticker) || (!peer && ticker !== symbol) || (peer && ticker === symbol)) return [];
    const values: ResearchRecord["values"] = {};
    for (const [key, label] of Object.entries(keys)) {
      const value = asNumber(row[key]) ?? asText(row[key]);
      if (value !== undefined) values[label] = value;
    }
    if (!Object.keys(values).length) return [];
    const date = asText(row.date ?? row.filingDate ?? row.transactionDate);
    const publishedAt = asText(row.filingDate ?? row.lastUpdated);
    return [{ id: `${path}:${index}`, label: peer ? ticker : name, date, values, evidence: { ...evidence, publishedAt } }];
  });
}

export async function optionsSnapshot(symbol: string, expiry?: string, cursor?: string): Promise<{ records: ResearchRecord[]; next?: string }> {
  return cached(`research:massive:options:${symbol}:${expiry ?? ""}:${cursor ?? ""}`, 30_000, async () => {
    const url = new URL(`https://api.massive.com/v3/snapshot/options/${encodeURIComponent(symbol)}`);
    url.search = new URLSearchParams({ limit: "100", sort: "expiration_date", order: "asc", ...(expiry ? { expiration_date: expiry } : {}), ...(cursor ? { cursor } : {}) }).toString();
    const payload = asObject(await providerJSON(url, MASSIVE, { Authorization: `Bearer ${process.env.RESEARCH_MASSIVE_API_KEY!.trim()}` }, 250));
    if (!Array.isArray(payload.results) && payload.status !== "OK") throw new Error("Massive returned an unreadable chain.");
    const ev = vendorEvidence(MASSIVE, "https://massive.com/docs/rest/options/snapshots/option-chain-snapshot");
    const records: ResearchRecord[] = (Array.isArray(payload.results) ? payload.results : []).flatMap((item: unknown) => {
      const row = asObject(item);
      const details = asObject(row.details);
      const id = asText(details.ticker);
      if (!id) return [];
      const quote = asObject(row.last_quote);
      const day = asObject(row.day);
      const greeks = asObject(row.greeks);
      const values: ResearchRecord["values"] = {};
      for (const [key, value] of Object.entries({
        Type: details.contract_type, Strike: details.strike_price, Bid: quote.bid, Ask: quote.ask, Volume: day.volume,
        "Open interest": row.open_interest, "Implied volatility": row.implied_volatility, Delta: greeks.delta,
        Gamma: greeks.gamma, Theta: greeks.theta, Vega: greeks.vega, "Quote feed": quote.timeframe,
      })) {
        const valid = asNumber(value) ?? asText(value);
        if (valid !== undefined) values[key] = valid;
      }
      const updated = asNumber(quote.last_updated);
      const date = updated !== undefined && updated > 0 && updated < 8.64e21 ? new Date(updated / 1_000_000).toISOString() : undefined;
      return [{ id, label: id, date: asText(details.expiration_date), values, evidence: { ...ev, publishedAt: date } }];
    });
    const nextUrl = safeUrl(payload.next_url);
    const next = nextUrl ? new URL(nextUrl).searchParams.get("cursor") ?? undefined : undefined;
    return { records, next };
  });
}
