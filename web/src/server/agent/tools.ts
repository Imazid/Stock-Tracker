// The assistant's tools. Every one of them only READS or PREPARES something for the person
// to review — none can place, approve or cancel an order, change a limit or move money, and
// none calls the order functions. The tool list is fixed and in a fixed order (it is part of
// the cached prompt prefix).
//
// Every result goes back to the model wrapped as untrusted data (see `asToolResult`): text
// from providers (instrument names, notes) is cleaned, capped and labelled so it can't pose
// as an instruction.

import { RESEARCH_SECTIONS, type Evidence, type ResearchSection } from "@/lib/research-types";
import { filingPassages } from "@/server/research/documents";
import { companyReport } from "@/server/research/report";
import { getResearch, parseFilters, ResearchInputError } from "@/server/research/service";
import { StrategyParser } from "@studio/parser.ts";
import { BadInstrumentError, parseInstrumentID } from "@/server/market/instruments";
import { getCandles, getQuote, NoDataError, search } from "@/server/market/service";
import { BacktestRequestError, decodeInputs, runBacktest } from "@/server/strategy/backtest";
import { CHART_RANGES, type ChartRange } from "@/lib/market-types";
import { clean, type ToolContext, type ToolName, TOOL_NAMES, type ToolOutcome } from "./tools-schema.ts";

export { asToolResult, TOOLS, type ToolContext, type ToolName } from "./tools-schema.ts";

// MARK: - Input validation (the model's input is untrusted too)

class ToolInputError extends Error {}
const str = (input: Record<string, unknown>, key: string, required = true, max = 400): string | undefined => {
  const v = input[key];
  if (v === undefined || v === null || v === "") {
    if (required) throw new ToolInputError(`${key} is required.`);
    return undefined;
  }
  if (typeof v !== "string" || v.length > max) throw new ToolInputError(`${key} must be text up to ${max} characters.`);
  return v;
};
const DECIMAL = /^(0|[1-9]\d*)(\.\d{1,18})?$/;

function instrumentFrom(input: Record<string, unknown>) {
  const id = str(input, "instrument_id", true, 40)!;
  try {
    return parseInstrumentID(id);
  } catch (error) {
    if (error instanceof BadInstrumentError) throw new ToolInputError(`${id} isn't a valid instrument id. Use search_instruments first.`);
    throw error;
  }
}

// MARK: - Executors

function quoteSource(q: { source: string; observedAt: string; status: string; stale: boolean }, label: string) {
  return { label, source: q.source, observedAt: q.observedAt, status: q.stale ? `${q.status}, stale` : q.status };
}

function researchSources(rows: { label: string; evidence: Evidence }[]) {
  return [...new Map(rows.map(({ label, evidence }) => [evidence.url, {
    label, source: evidence.provider, observedAt: evidence.publishedAt ?? evidence.retrievedAt, url: evidence.url,
  }])).values()].slice(0, 20);
}

const executors: Record<ToolName, (input: Record<string, unknown>, ctx: ToolContext) => Promise<ToolOutcome>> = {
  async search_instruments(input) {
    const query = str(input, "query", true, 60)!;
    const res = await search(query, { allowLicensedIdentifiers: process.env.RESEARCH_FMP_AI === "true" });
    return {
      data: { query, results: res.results.slice(0, 10).map((r) => ({ instrumentId: r.id, symbol: r.symbol, name: clean(r.name, 80), venue: r.venue, assetClass: r.assetClass, currency: r.currency })), warning: res.warning },
    };
  },

  async get_quote(input) {
    const instrument = instrumentFrom(input);
    const { quote, market, instrument: view } = await getQuote(instrument);
    return {
      data: { instrument: { id: view.id, symbol: view.symbol, name: clean(view.name, 80), venue: view.venue, currency: view.currency }, quote, market },
      sources: [quoteSource(quote, `${view.symbol} quote`)],
    };
  },

  async get_price_history(input) {
    const instrument = instrumentFrom(input);
    const range = str(input, "range", true, 4) as ChartRange;
    if (!CHART_RANGES.includes(range)) throw new ToolInputError("range must be one of " + CHART_RANGES.join(", "));
    const view = await getCandles(instrument, range);
    const closes = view.candles.map((c) => c.close);
    if (closes.length < 2) return { data: { instrumentId: view.instrument.id, range, note: "Not enough history returned for this range." } };
    const first = closes[0];
    const last = closes[closes.length - 1];
    const returns = closes.slice(1).map((c, i) => Math.log(c / closes[i]));
    const mean = returns.reduce((s, r) => s + r, 0) / returns.length;
    const sd = Math.sqrt(returns.reduce((s, r) => s + (r - mean) ** 2, 0) / Math.max(returns.length - 1, 1));
    return {
      data: {
        instrumentId: view.instrument.id, range, interval: view.interval, currency: view.currency, source: view.source, status: view.status, observedAt: view.observedAt, adjustment: view.adjustment,
        // CandleView.time is seconds since 1970.
        firstBar: { time: new Date(view.candles[0].time * 1000).toISOString(), close: first },
        lastBar: { time: new Date(view.candles[view.candles.length - 1].time * 1000).toISOString(), close: last },
        changePct: Number(((last / first - 1) * 100).toFixed(2)),
        high: Math.max(...view.candles.map((c) => c.high)),
        low: Math.min(...view.candles.map((c) => c.low)),
        perBarVolatilityPct: Number((sd * 100).toFixed(2)),
        method: "changePct = last close / first close − 1; volatility = standard deviation of log returns between consecutive bars",
        lastCloses: view.candles.slice(-10).map((c) => ({ time: new Date(c.time * 1000).toISOString(), close: c.close })),
        notes: view.notes,
      },
      sources: [{ label: `${view.instrument.symbol} ${range} history`, source: view.source, observedAt: view.observedAt, status: view.status }],
    };
  },

  async get_company_research(input) {
    const report = await companyReport(instrumentFrom(input), process.env.RESEARCH_FMP_AI !== "true");
    return {
      data: report,
      sources: researchSources([
        ...report.facts,
        ...report.events.map((event) => ({ label: event.title, evidence: event.evidence })),
        ...report.ownership.map((event) => ({ label: event.title, evidence: event.evidence })),
        ...report.earnings, ...report.peers, ...report.multiples,
        ...(report.profile ? [{ label: report.profile.name, evidence: report.profile.evidence }] : []),
      ]),
    };
  },

  async get_company_dataset(input) {
    const section = str(input, "section", true, 20) as ResearchSection;
    if (!RESEARCH_SECTIONS.includes(section)) throw new ToolInputError("Choose a company research dataset.");
    const params = new URLSearchParams({ limit: "25", q: str(input, "query", false, 100) ?? "", period: str(input, "period", false, 10) ?? "annual" });
    const asOf = str(input, "as_of", false, 10);
    if (asOf) params.set("asOf", asOf);
    if (input.page !== undefined) params.set("page", String(input.page));
    const publicOnly = section === "options" ? process.env.RESEARCH_MASSIVE_AI !== "true" : process.env.RESEARCH_FMP_AI !== "true";
    const data = await getResearch(instrumentFrom(input), section, { ...parseFilters(params), publicOnly });
    return {
      data,
      sources: researchSources([
        ...(data.facts ?? []),
        ...(data.events ?? []).map((event) => ({ label: event.title, evidence: event.evidence })),
        ...(data.records ?? []),
        ...(data.profile ? [{ label: data.profile.name, evidence: data.profile.evidence }] : []),
      ]),
    };
  },

  async search_filing_text(input) {
    const accession = str(input, "accession", true, 20)!;
    const query = str(input, "query", true, 120)!;
    const archive = input.archive;
    if (archive !== undefined && (typeof archive !== "number" || !Number.isInteger(archive) || archive < 0 || archive > 100)) throw new ToolInputError("Choose a valid archive batch.");
    const data = await filingPassages(instrumentFrom(input), accession, query, archive);
    return { data, sources: researchSources([{ label: `Form ${data.form} · ${accession}`, evidence: data.evidence }]) };
  },

  async get_watchlist(_input, ctx) {
    if (!ctx.signedIn || !ctx.supabase) return { data: { error: "Not signed in, so there's no watchlist to read." }, isError: true };
    const { data, error } = await ctx.supabase.from("watchlist_assets").select("symbol, name, kind, exchange").is("deleted_at", null).limit(50);
    if (error) return { data: { error: "The watchlist couldn't be read." }, isError: true };
    const rows = (data ?? []) as { symbol: string; name: string; kind: string; exchange: string | null }[];
    const items = await Promise.all(rows.map(async (r) => {
      const id = r.kind === "Crypto" ? `crypto:${r.symbol}` : /\.AX$|^ASX$/i.test(`${r.symbol} ${r.exchange ?? ""}`) || r.exchange === "ASX" ? `asx:${r.symbol.replace(/\.AX$/i, "")}` : `us:${r.symbol}`;
      try {
        const q = await getQuote(parseInstrumentID(id));
        return { instrumentId: id, name: clean(r.name, 80), last: q.quote.last, changePct: q.quote.changePct, currency: q.quote.currency, source: q.quote.source, observedAt: q.quote.observedAt, status: q.quote.status, stale: q.quote.stale };
      } catch {
        return { instrumentId: id, name: clean(r.name, 80), quote: "unavailable" };
      }
    }));
    return { data: { count: items.length, items }, sources: items.filter((i) => "source" in i).map((i) => ({ label: String(i.instrumentId), source: String((i as { source: string }).source), observedAt: (i as { observedAt?: string }).observedAt })) };
  },

  async get_portfolio(_input, ctx) {
    if (!ctx.signedIn || !ctx.supabase) return { data: { error: "Not signed in, so there's no portfolio to read." }, isError: true };
    const [holdings, positions] = await Promise.all([
      ctx.supabase.from("portfolio_holdings").select("asset_symbol, asset_name, asset_kind, asset_exchange, shares, avg_cost").is("deleted_at", null).limit(200),
      ctx.supabase.from("broker_position_snapshots").select("connection_id, symbol, asset_class, quantity, average_entry_price, market_value, currency, observed_at").order("observed_at", { ascending: false }).limit(200),
    ]);
    const latest = new Map<string, unknown>();
    for (const p of (positions.data ?? []) as { connection_id: string; symbol: string; observed_at: string }[]) {
      const key = `${p.connection_id}:${p.symbol}`;
      if (!latest.has(key)) latest.set(key, p);
    }
    return {
      data: {
        appHoldings: { note: "From the Stock Tracker app. avg_cost is in US$ (the app stores every value in USD).", rows: holdings.error ? "unavailable" : holdings.data },
        providerPositions: { note: "Last synced positions from connected provider accounts (provider currency).", rows: positions.error ? "unavailable" : [...latest.values()] },
      },
    };
  },

  async draft_strategy(input) {
    const description = str(input, "description", true, 2000)!;
    const parsed = StrategyParser.parse(description);
    return {
      data: { spec: parsed.draft.spec, name: parsed.draft.name, understood: parsed.understood, assumptions: parsed.assumptions, unrecognisedSymbols: parsed.unrecognisedSymbols },
      card: { kind: "strategy", title: parsed.draft.name, href: "/strategies", payload: { spec: parsed.draft.spec, name: parsed.draft.name } },
    };
  },

  async run_backtest(input, ctx) {
    let spec = input.spec;
    const description = str(input, "description", false, 2000);
    if (!spec) {
      if (!description) throw new ToolInputError("Give a description or a spec.");
      spec = StrategyParser.parse(description).draft.spec;
    }
    const window = str(input, "window", false, 3) ?? "2y";
    const cash = typeof input.starting_cash === "number" ? input.starting_cash : undefined;
    try {
      const res = await runBacktest(decodeInputs({ spec, window, config: cash ? { startingCash: cash } : {} }, ctx.now), ctx.now);
      const r = res.result;
      return {
        data: {
          strategy: r.strategyTitle, engine: res.engine, ranAt: res.ranAt, window, dataSources: r.dataSources, usedRealMarketData: r.usedRealMarketData,
          overall: r.overall, inSample: r.inSample, outOfSample: r.outOfSample, benchmark: r.benchmarkName ? { name: r.benchmarkName, returnPct: r.benchmarkReturnPct } : undefined,
          trades: r.trades.length, assumptions: (r as unknown as { assumptions?: string[] }).assumptions ?? [], failures: res.failures,
        },
        sources: res.datasets.map((d) => ({ label: `backtest data ${(d as { instrumentId?: string }).instrumentId ?? ""}`.trim(), source: String((d as { source?: string }).source ?? "history") })),
        card: { kind: "backtest", title: `Backtest: ${r.strategyTitle}`, href: "/strategies", payload: { spec, window } },
      };
    } catch (error) {
      if (error instanceof BacktestRequestError) return { data: { error: error.message }, isError: true };
      throw error;
    }
  },

  async prepare_order_ticket(input) {
    const instrument = instrumentFrom(input);
    const side = str(input, "side", true, 4);
    const type = str(input, "order_type", true, 6);
    if (side !== "buy" && side !== "sell") throw new ToolInputError("side must be buy or sell.");
    if (type !== "market" && type !== "limit") throw new ToolInputError("order_type must be market or limit.");
    const quantity = str(input, "quantity", false, 40);
    const notional = str(input, "notional", false, 40);
    const limit = str(input, "limit_price", false, 40);
    if ((quantity === undefined) === (notional === undefined)) throw new ToolInputError("Give a quantity or a notional amount, not both.");
    for (const [k, v] of [["quantity", quantity], ["notional", notional], ["limit_price", limit]] as const) if (v !== undefined && !DECIMAL.test(v)) throw new ToolInputError(`${k} must be a plain positive decimal.`);
    if (type === "limit" && !limit) throw new ToolInputError("A limit order needs limit_price.");
    if (notional && type !== "market") throw new ToolInputError("An amount only works with a market order.");
    const reason = clean(str(input, "reason", true, 300), 300);
    const params = new URLSearchParams({ instrument: `${instrument.venue}:${instrument.symbol}`, side, type });
    if (quantity) params.set("quantity", quantity);
    if (notional) params.set("notional", notional);
    if (limit) params.set("limit", limit);
    params.set("origin", "assistant");
    const ticket = { instrumentId: `${instrument.venue}:${instrument.symbol}`, side, type, quantity, notional, limitPrice: limit, reason };
    return {
      data: { prepared: true, sent: false, ticket, next: "The person reviews this ticket on the Orders screen; the risk engine checks it and only they can approve it. Nothing has been sent." },
      card: { kind: "order_ticket", title: `${side === "buy" ? "Buy" : "Sell"} ${instrument.symbol} — review ticket`, href: `/orders/new?${params.toString()}`, payload: ticket },
    };
  },
};

export async function runTool(name: string, input: unknown, ctx: ToolContext): Promise<ToolOutcome> {
  if (!(TOOL_NAMES as readonly string[]).includes(name)) return { data: { error: `There is no tool called ${clean(name, 40)}.` }, isError: true };
  if (typeof input !== "object" || input === null || Array.isArray(input)) return { data: { error: "Tool input must be an object." }, isError: true };
  try {
    return await executors[name as ToolName](input as Record<string, unknown>, ctx);
  } catch (error) {
    if (error instanceof ToolInputError || error instanceof ResearchInputError) return { data: { error: error.message }, isError: true };
    if (error instanceof NoDataError) return { data: { error: error.message }, isError: true };
    return { data: { error: "That data source didn't answer. Say the data is unavailable rather than guessing." }, isError: true };
  }
}
