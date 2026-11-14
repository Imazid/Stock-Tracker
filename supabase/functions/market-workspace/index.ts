// Read-only market data and strategy preparation for the Stock Tracker workspace.
import { serviceClient } from "../_shared/secure/edge.ts";
import { authenticate } from "../_shared/server/auth.ts";
import { errorResponse, Field, HttpError, ok, readJSONObject, sameSecret } from "../_shared/server/http.ts";
import { historicalCashConversion } from "./historical_fx.ts";
import { providerFromEnv } from "../_shared/market/index.ts";
import { cachedPortfolioBenchmark, validBenchmarkPeriod } from "../_shared/portfolio/benchmark.ts";
import { PORTFOLIO_BENCHMARKS, type PortfolioBenchmark } from "../_shared/portfolio/benchmark_types.ts";
import { catalogInstruments } from "../_shared/trading/catalog.ts";
import { decodeInstrument, instrumentID, parseYahooSymbol, venueCurrency, VENUES } from "../_shared/trading/market.ts";
import { validate } from "../_shared/trading/strategy.ts";
import { companyResearch } from "./company.ts";
import { prepareStrategy, runHistory } from "./strategy.ts";

const env = (name: string) => Deno.env.get(name);
const ranges = {
  "1D": ["hour", 24], "1W": ["day", 7], "1M": ["day", 23],
  "3M": ["day", 66], "1Y": ["day", 260],
} as const;

function asset(raw: unknown) {
  const value = Field.object(raw, "asset");
  if (value.venue !== undefined) Field.oneOf(value.venue, VENUES, "venue");
  const symbol = Field.string(value.symbol, "symbol", 16).trim().toUpperCase();
  if (!/^[A-Z0-9][A-Z0-9.-]{0,15}$/.test(symbol)) throw new HttpError(422, "invalid_symbol", "Enter a valid ticker.");
  const listing = parseYahooSymbol(symbol);
  try {
    const instrument = decodeInstrument({ ...value, symbol, ...listing, currency: undefined });
    if ((instrument.venue === "crypto") !== (instrument.assetClass === "crypto")) throw new Error("Select the market that matches this asset.");
    instrument.currency = venueCurrency(instrument.venue);
    return instrument;
  } catch (error) {
    throw new HttpError(422, "invalid_asset", error instanceof Error ? error.message : "Select a valid asset.");
  }
}

Deno.serve(async (request) => {
  try {
    if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
    const body = await readJSONObject(request, 12_000);
    const featured = body.action === "featured";
    if (featured) {
      const expected = env("WORKSPACE_OVERVIEW_SECRET");
      const provided = request.headers.get("x-workspace-overview-secret");
      if (!expected || !provided || !sameSecret(expected, provided)) {
        throw new HttpError(403, "private_feed", "The featured market feed is limited to the Stock Tracker workspace.");
      }
    } else {
      const caller = await authenticate(request, { url: env("SUPABASE_URL"), anonKey: env("SUPABASE_ANON_KEY") });
      const { data: allowed, error } = await serviceClient().rpc("consume_market_data_quota", { p_user_id: caller.userID });
      if (error) throw new HttpError(503, "unavailable", "Market data limits could not be checked.");
      if (!allowed) throw new HttpError(429, "rate_limit", "Market data request limit reached. Wait a minute and retry.");
    }
    const now = Date.now();
    if (body.action === "historicalFx") return ok(await historicalCashConversion(body, now));
    if (body.action === "portfolioBenchmark") {
      const id = Field.oneOf(body.benchmark, Object.keys(PORTFOLIO_BENCHMARKS) as PortfolioBenchmark[], "benchmark");
      const start = Field.string(body.start, "start", 10);
      const end = Field.string(body.end, "end", 10);
      if (!validBenchmarkPeriod(start, end)) {
        throw new HttpError(400, "invalid_benchmark", "Choose a benchmark period of up to ten years.");
      }
      try {
        return ok({ result: await cachedPortfolioBenchmark(id, start, end, now) });
      } catch {
        throw new HttpError(503, "benchmark_unavailable", "Benchmark data is temporarily unavailable.");
      }
    }
    const { provider } = providerFromEnv(env);
    if (!provider) throw new HttpError(503, "unavailable", "The market data provider is unavailable.");

    if (featured) {
      const assets = ["SPY", "QQQ", "AAPL", "NVDA", "MSFT", "BTC", "ETH", "SOL", "BHP", "CBA"]
        .flatMap((symbol) => catalogInstruments.find((item) => item.symbol === symbol) ?? []);
      const choice = Field.oneOf(body.symbol, assets.map((item) => item.symbol), "symbol");
      const range = Field.oneOf(body.range, ["1D", "1W", "1M", "3M", "1Y"] as const, "range");
      const [timeframe, count] = ranges[range];
      const selected = assets.find((item) => item.symbol === choice)!;
      const [latest, daily, chart] = await Promise.all([
        provider.quotes(assets, now), provider.bars(assets, "day", 6, now), provider.bars([selected], timeframe, count, now),
      ]);
      return ok({ ...latest, series: daily.series, chart: chart.series[instrumentID(selected)] ?? null });
    }

    if (body.action === "fx") {
      const response = await fetch("https://api.frankfurter.dev/v1/latest?base=USD", { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new HttpError(503, "fx_unavailable", "Exchange rates are unavailable.");
      const data = await response.json();
      return ok({ ...data.rates, USD: 1 });
    }

    if (body.action === "company") {
      const instrument = asset(body.asset);
      if (instrument.venue !== "us" || instrument.assetClass !== "equity") {
        throw new HttpError(422, "unsupported_market", "Company fundamentals are available for US-listed stocks.");
      }
      return ok(await companyResearch(instrument.symbol, now, env("FINNHUB_API_KEY")));
    }

    if (body.action === "search") {
      const query = Field.string(body.query, "query", 80).trim().toUpperCase();
      return ok(catalogInstruments.filter((item) =>
        item.symbol.startsWith(query) || item.name.toUpperCase().includes(query)
      ).sort((a, b) => Number(b.symbol === query) - Number(a.symbol === query)).slice(0, 20));
    }

    if (body.action === "quotes") {
      if (!Array.isArray(body.assets) || body.assets.length < 1 || body.assets.length > 24) {
        throw new HttpError(400, "invalid_assets", "Request between 1 and 24 assets.");
      }
      const assets = body.assets.map(asset);
      const [latest, history] = await Promise.all([provider.quotes(assets, now), provider.bars(assets, "day", 2, now)]);
      return ok({ ...latest, series: history.series });
    }

    if (body.action === "chart") {
      const instrument = asset(body.asset);
      const range = Field.oneOf(body.range, ["1D", "1W", "1M", "3M", "1Y"] as const, "range");
      const [timeframe, count] = ranges[range];
      const id = instrumentID(instrument);
      const history = await provider.bars([instrument], timeframe, count, now);
      const series = history.series[id];
      if (!series || series.bars.length === 0) throw new HttpError(404, "no_history", history.failures[id] ?? "Price history is unavailable.");
      return ok(series);
    }

    if (body.action === "strategy") {
      const instrument = asset(body.asset);
      const spec = prepareStrategy(Field.string(body.rule, "rule", 200), instrument);
      const errors = validate(spec).filter((issue) => issue.severity === "error");
      if (errors.length) throw new HttpError(422, "invalid_strategy", errors.map((issue) => issue.message).join(" "));
      return ok({ spec });
    }

    if (body.action === "backtest") {
      const instrument = asset(body.asset);
      const spec = prepareStrategy(Field.string(body.rule, "rule", 200), instrument);
      const errors = validate(spec).filter((issue) => issue.severity === "error");
      if (errors.length) throw new HttpError(422, "invalid_strategy", errors.map((issue) => issue.message).join(" "));
      const startingCash = Field.number(body.startingCash, "startingCash");
      if (startingCash < 100 || startingCash > 10_000_000) throw new HttpError(422, "invalid_budget", "Starting cash must be between 100 and 10,000,000.");
      const history = await provider.bars([instrument], "day", 750, now);
      const id = instrumentID(instrument);
      const series = history.series[id];
      if (!series) throw new HttpError(404, "no_history", history.failures[id] ?? "Historical data is unavailable.");
      const result = runHistory(spec, series, startingCash, now);
      return ok({ ...result, provenance: series.provenance, currency: instrument.currency });
    }

    throw new HttpError(400, "unknown_action", "Unknown market data request.");
  } catch (error) {
    return errorResponse(error);
  }
});
