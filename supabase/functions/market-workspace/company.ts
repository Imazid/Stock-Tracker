import { HttpError } from "../_shared/server/http.ts";

type RecordValue = Record<string, unknown>;
const records = (value: unknown): RecordValue[] => Array.isArray(value) ?
  value.filter((item) => item && typeof item === "object" && !Array.isArray(item)) : [];
const record = (value: unknown): RecordValue => value && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : {};
const number = (value: unknown) => typeof value === "number" && Number.isFinite(value) ? value : null;
const text = (value: unknown, limit = 250) => typeof value === "string" ? value.trim().slice(0, limit) : "";
const date = (value: number) => new Date(value).toISOString().slice(0, 10);

function httpsLink(raw: unknown) {
  try {
    const url = new URL(String(raw));
    return url.protocol === "https:" && !url.username && !url.password ? url.href : "";
  } catch {
    return "";
  }
}

export async function companyResearch(symbol: string, now: number, key: string | undefined) {
  if (!key) throw new HttpError(503, "research_unavailable", "Company data is awaiting provider configuration.");
  const read = async (path: string, params: Record<string, string> = {}) => {
    const query = new URLSearchParams({ symbol, ...params });
    try {
      const response = await fetch(`https://finnhub.io/api/v1/${path}?${query}`, {
        headers: { "X-Finnhub-Token": key },
        signal: AbortSignal.timeout(8_000),
      });
      return response.ok ? await response.json() : null;
    } catch {
      return null;
    }
  };
  const [profileRaw, metricsRaw, earningsRaw, newsRaw] = await Promise.all([
    read("stock/profile2"), read("stock/metric", { metric: "all" }), read("stock/earnings", { limit: "4" }),
    read("company-news", { from: date(now - 14 * 86_400_000), to: date(now) }),
  ]);
  const profile = record(profileRaw);
  const metric = record(record(metricsRaw).metric);
  const earnings = records(earningsRaw).slice(0, 4).map((row) => ({
    date: text(row.period, 12), actual: number(row.actual), estimate: number(row.estimate), surprise: number(row.surprisePercent),
  })).filter((row) => row.date);
  const news = records(newsRaw).map((row) => ({
    title: text(row.headline), url: httpsLink(row.url), source: text(row.source, 50), time: (number(row.datetime) ?? 0) * 1000,
  })).filter((row) => row.title && row.url && row.time > 0).sort((a, b) => b.time - a.time).slice(0, 6);
  const values = {
    marketCapMillions: number(profile.marketCapitalization), pe: number(metric.peTTM ?? metric.peNormalizedAnnual),
    revenueGrowth: number(metric.revenueGrowthTTMYoy), margin: number(metric.netProfitMarginTTM), beta: number(metric.beta),
    high52: number(metric["52WeekHigh"]), low52: number(metric["52WeekLow"]),
  };
  if (!text(profile.name) && !Object.values(values).some((value) => value !== null) && !earnings.length && !news.length) {
    throw new HttpError(404, "no_company_data", "The provider returned no company research for this asset.");
  }
  return {
    profile: { name: text(profile.name), industry: text(profile.finnhubIndustry), exchange: text(profile.exchange), website: httpsLink(profile.weburl), currency: text(profile.currency, 8) || "USD" },
    values, earnings, news, asOf: now, source: "Finnhub",
  };
}
