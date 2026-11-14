import { HttpError } from "../_shared/server/http.ts";
import { type Venue, VENUES } from "../_shared/trading/market.ts";

const unavailable = () => new HttpError(503, "research_unavailable", "The company report is temporarily unavailable.");

export async function mobileResearchReport(
  instrumentID: string,
  origin: string | undefined,
  bypass: string | undefined,
  request: typeof fetch = fetch,
) {
  const [venue, symbol, extra] = instrumentID.split(":");
  if (!VENUES.includes(venue as Venue) || venue === "crypto" || extra !== undefined ||
      !/^[A-Z0-9][A-Z0-9.\-&]{0,19}$/.test(symbol ?? "")) {
    throw new HttpError(422, "invalid_asset", "Choose a company or fund listing.");
  }

  let web: URL;
  try {
    web = new URL(origin ?? "");
  } catch {
    throw unavailable();
  }
  if (web.protocol !== "https:" || web.username || web.password || web.pathname !== "/" ||
      web.search || web.hash || !bypass) throw unavailable();

  const encoded = encodeURIComponent(instrumentID);
  try {
    const result = await request(new URL(`/api/markets/instruments/${encoded}/research/report`, web), {
      headers: { Accept: "application/json", "x-vercel-protection-bypass": bypass },
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
    return { report, dashboardURL: new URL(`/markets/${encoded}`, web).href };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw unavailable();
  }
}
