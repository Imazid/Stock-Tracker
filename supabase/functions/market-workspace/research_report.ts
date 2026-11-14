import { HttpError } from "../_shared/server/http.ts";
import { type Venue, VENUES } from "../_shared/trading/market.ts";

const unavailable = () => new HttpError(503, "research_unavailable", "The company report is temporarily unavailable.");

export function researchListing(instrumentID: string) {
  const [venue, symbol, extra] = instrumentID.split(":");
  if (!VENUES.includes(venue as Venue) || venue === "crypto" || extra !== undefined ||
      !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(symbol ?? "")) {
    throw new HttpError(422, "invalid_asset", "Choose a company or fund listing.");
  }
  return { venue: venue as Venue, symbol };
}

export function researchOrigin(origin: string | undefined, bypass: string | undefined, unavailable: () => HttpError) {
  let web: URL;
  try {
    web = new URL(origin ?? "");
  } catch {
    throw unavailable();
  }
  if (web.protocol !== "https:" || web.username || web.password || web.pathname !== "/" ||
      web.search || web.hash || !bypass) throw unavailable();
  return { web, bypass };
}

export async function mobileAssetRisk(
  instrumentID: string,
  range: string,
  origin: string | undefined,
  bypass: string | undefined,
  request: typeof fetch = fetch,
) {
  const [venue, symbol, extra] = instrumentID.split(":");
  if (!VENUES.includes(venue as Venue) || extra !== undefined ||
      !/^(?:[A-Z0-9][A-Z0-9.\-&]{0,19}|\^[A-Z0-9]{2,14})$/.test(symbol ?? "")) {
    throw new HttpError(422, "invalid_asset", "Choose a valid listing.");
  }
  if (!["3M", "6M", "1Y"].includes(range)) throw new HttpError(400, "invalid", "Choose 3M, 6M or 1Y.");
  const failure = () => new HttpError(503, "risk_unavailable", "Daily price history is temporarily unavailable.");
  const resolved = researchOrigin(origin, bypass, failure);
  try {
    const url = new URL(`/api/markets/instruments/${encodeURIComponent(instrumentID)}/risk`, resolved.web);
    url.searchParams.set("range", range);
    const result = await request(url, {
      headers: { Accept: "application/json", "x-vercel-protection-bypass": resolved.bypass },
      signal: AbortSignal.timeout(25_000),
      redirect: "error",
    });
    if (result.status === 404) throw new HttpError(404, "insufficient_history", "Too few completed daily closes for this period.");
    if (result.status === 429) throw new HttpError(429, "rate_limit", "Price history is busy. Wait a minute and retry.");
    if (!result.ok || !result.headers.get("content-type")?.includes("application/json")) throw failure();
    const risk = await result.json();
    if (risk?.instrumentId !== instrumentID || risk?.range !== range || !Number.isFinite(risk.maxDrawdownPct)) throw failure();
    return risk;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw failure();
  }
}

export async function mobileResearchReport(
  instrumentID: string,
  origin: string | undefined,
  bypass: string | undefined,
  request: typeof fetch = fetch,
  publicOnly = false,
) {
  researchListing(instrumentID);
  const resolved = researchOrigin(origin, bypass, unavailable);

  const encoded = encodeURIComponent(instrumentID);
  try {
    const url = new URL(`/api/markets/instruments/${encoded}/research/report`, resolved.web);
    if (publicOnly) url.searchParams.set("publicOnly", "true");
    const result = await request(url, {
      headers: { Accept: "application/json", "x-vercel-protection-bypass": resolved.bypass },
      signal: AbortSignal.timeout(25_000),
      redirect: "error",
    });
    if (result.status === 429) throw new HttpError(429, "rate_limit", "Company research is busy. Wait a minute and retry.");
    if (!result.ok || !result.headers.get("content-type")?.includes("application/json")) throw unavailable();
    const report = await result.json();
    if (report?.instrumentId !== instrumentID || typeof report.asOf !== "string" ||
        !Array.isArray(report.coverage) || !Array.isArray(report.facts) || !Array.isArray(report.events)) {
      throw unavailable();
    }
    return { report, dashboardURL: new URL(`/markets/${encoded}`, resolved.web).href };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw unavailable();
  }
}
