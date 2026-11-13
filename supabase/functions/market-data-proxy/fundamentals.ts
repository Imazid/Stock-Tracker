type ProviderRequest = {
  target: URL;
  keyName: string;
  auth: "query" | "X-Finnhub-Token" | "X-API-KEY";
};

const finnhubPaths = new Set([
  "/api/v1/news", "/api/v1/company-news", "/api/v1/calendar/earnings", "/api/v1/stock/earnings",
  "/api/v1/stock/recommendation", "/api/v1/stock/upgrade-downgrade", "/api/v1/stock/fund-ownership",
  "/api/v1/stock/metric", "/api/v1/stock/profile2",
]);
const fmpPaths = new Set([
  "profile", "quote", "ratios-ttm", "ratios", "analyst-estimates", "grades-consensus", "earnings",
  "price-target-consensus", "grades", "income-statement", "balance-sheet-statement", "cash-flow-statement",
].map((path) => "/stable/" + path));
const fiscalPaths = new Set(["/v2/company/profile", "/v1/company/ratios"]);
const alphaFunctions = new Set(["SYMBOL_SEARCH", "GLOBAL_QUOTE", "TIME_SERIES_DAILY"]);

const checks: Record<string, (v: string) => boolean> = {
  symbol: (v) => /^[A-Z0-9][A-Z0-9.\-]{0,23}$/.test(v),
  category: (v) => v === "general",
  minId: (v) => /^\d{1,14}$/.test(v),
  from: (v) => /^\d{4}-\d{2}-\d{2}$/.test(v),
  to: (v) => /^\d{4}-\d{2}-\d{2}$/.test(v),
  limit: (v) => /^\d{1,2}$/.test(v) && Number(v) >= 1 && Number(v) <= 25,
  metric: (v) => v === "all",
  period: (v) => v === "annual",
  page: (v) => v === "0",
  companyKey: (v) => /^[\w.:-]{1,80}$/.test(v),
  function: (v) => alphaFunctions.has(v),
  keywords: (v) => /^[\p{L}\p{N} .&'-]{1,50}$/u.test(v),
  outputsize: (v) => v === "compact" || v === "full",
};

export function fundamentalsRequest(input: URL): ProviderRequest | undefined {
  const params = input.searchParams;
  const provider = params.get("provider");
  const path = params.get("path") ?? "";
  let target: URL;
  let keyName: string;
  let auth: ProviderRequest["auth"];
  let allowed: string[];
  switch (provider) {
    case "finnhub":
      if (!finnhubPaths.has(path)) return;
      target = new URL(path, "https://finnhub.io");
      keyName = "FINNHUB_API_KEY";
      auth = "X-Finnhub-Token";
      allowed = path === "/api/v1/news" ? ["category", "minId"] : ["symbol", "from", "to", "limit", "metric"];
      break;
    case "fmp":
      if (!fmpPaths.has(path)) return;
      target = new URL(path, "https://financialmodelingprep.com");
      keyName = "FMP_API_KEY";
      auth = "query";
      allowed = ["symbol", "limit", "period", "page"];
      break;
    case "fiscal":
      if (!fiscalPaths.has(path)) return;
      target = new URL(path, "https://api.fiscal.ai");
      keyName = "FISCAL_AI_API_KEY";
      auth = "X-API-KEY";
      allowed = ["companyKey"];
      break;
    case "alpha":
      if (path !== "/query" || !alphaFunctions.has(params.get("function") ?? "")) return;
      target = new URL(path, "https://www.alphavantage.co");
      keyName = "ALPHA_VANTAGE_API_KEY";
      auth = "query";
      allowed = params.get("function") === "SYMBOL_SEARCH" ? ["function", "keywords"] : ["function", "symbol", "outputsize"];
      break;
    default:
      return;
  }
  const seen = new Set<string>();
  for (const [name, value] of params) {
    if (seen.has(name)) return;
    seen.add(name);
    if (name === "path" || name === "provider") continue;
    if (!allowed.includes(name) || !checks[name](value)) return;
    target.searchParams.set(name, value);
  }
  const required = provider === "fiscal" ? "companyKey" : path === "/api/v1/news" ? "category" :
    params.get("function") === "SYMBOL_SEARCH" ? "keywords" : "symbol";
  if (!seen.has(required)) return;
  target.searchParams.sort();
  return { target, keyName, auth };
}
