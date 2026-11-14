// Port of TradingCore/StrategyParser.swift. Helpers absent from the trading port live
// here: Foundation-compatible regex character classes, text recognition, DraftEnvelope decoding, the template schedule/position defaults
// from Templates.swift, and StrategyParser.money's grouped en_US decimal formatting.

import { AGENT_MODES, type AgentMode, agentModeDisplayName, modeIsLive } from "../trading/agent.ts";
import { lookupInstrument, UniverseCatalog } from "../trading/catalog.ts";
import { Currencies } from "../trading/currencies.ts";
import { type Instrument, instrumentID, usETF, type Venue } from "../trading/market.ts";
import { type RiskPolicy, standardPolicy } from "../trading/risk.ts";
import { roundAway } from "../trading/rounding.ts";
import { type AgentDraft, makeDraft, TradingError } from "../trading/state.ts";
import { conditionLabel, decodeStrategySpec, makeSpec, type StrategySpec, StrategyValidator } from "../trading/strategy.ts";
import * as Templates from "../trading/templates.ts";
import { compareStrings, trimNumber } from "../trading/text.ts";
import { describedRules } from "./described-rules.ts";

export interface ParsedAgentRequest {
  draft: AgentDraft;
  understood: string[];
  assumptions: string[];
  unrecognisedSymbols: string[];
}

export interface DraftEnvelope {
  name: string;
  mode?: AgentMode;
  budget?: number;
  maxPositionPct?: number;
  reviewEachPaperTrade?: boolean;
  intervalMinutes?: number;
  spec: StrategySpec;
  notes?: string[];
}

// The existing templates.ts ports the strategies, but not AgentTemplate metadata.
const templateDefaults: Record<string, { maxPositionPct: number; intervalMinutes: number }> = {
  momentum: { maxPositionPct: 10, intervalMinutes: 60 },
  trend: { maxPositionPct: 25, intervalMinutes: 60 },
  meanReversion: { maxPositionPct: 10, intervalMinutes: 60 },
  dca: { maxPositionPct: 60, intervalMinutes: 1_440 },
  breakout: { maxPositionPct: 10, intervalMinutes: 60 },
  etfRebalance: { maxPositionPct: 70, intervalMinutes: 1_440 },
  cryptoMonitor: { maxPositionPct: 35, intervalMinutes: 60 },
  riskManager: { maxPositionPct: 100, intervalMinutes: 60 },
  research: { maxPositionPct: 10, intervalMinutes: 1_440 },
};

function money(x: number, currency = "USD"): string {
  // NumberFormatter's decimal style uses grouping, no minimum fraction digits, and
  // half-even rounding. NumberText.money is reused elsewhere, but has fixed decimals
  // and no grouping, unlike this particular Swift helper.
  const options = {
    style: "decimal", useGrouping: true, minimumFractionDigits: 0,
    maximumFractionDigits: x === roundAway(x) ? 0 : Currencies.decimals(currency),
    roundingMode: "halfEven",
  } as Intl.NumberFormatOptions;
  return Currencies.symbol(currency) + new Intl.NumberFormat("en-US", options).format(x);
}

const driftPatterns = [
  String.raw`\b(?:drift(?:s|ed)?(?:\s+by)?(?:\s+(?:beyond|above|over|exceeds?|more than|of))?|threshold(?:\s+of)?)\s+(\d+(?:\.\d+)?)\s*(?:%|percentage points?|percent|points?)`,
  String.raw`\b(\d+(?:\.\d+)?)\s*(?:%|percentage points?|percent|points?)\s+drift(?:\s+threshold)?`,
];

export function parse(text: string): ParsedAgentRequest {
  const lower = text.toLowerCase();
  const understood: string[] = [];
  const assumptions: string[] = [];
  const { instruments: assets, unknown, note } = universe(text);
  const has = (...words: string[]): boolean => words.some((word) => lower.includes(word));
  const periods = averagePeriods(lower);
  let templateID: string;
  let spec: StrategySpec;
  let name: string;
  let mode: AgentMode = "paper";
  const pick = assets.length === 0 ? undefined : assets;

  const explicit = describedRules(lower);
  if (explicit) {
    templateID = "customRules"; name = "Custom Strategy";
    const timeframe = /\d+[- ]hour\b|\bhourly (?:bars|chart)\b/.test(lower) ? "hour" : "day";
    spec = makeSpec({ kind: "rules", title: "Custom rules",
      summary: "Uses the buy and sell conditions from your description.",
      timeframe, universe: pick ?? UniverseCatalog.broadETFs, entry: explicit.entry, exit: explicit.exit });
    assumptions.push(...explicit.notes);
    if (spec.entry) understood.push(`Buy when ${conditionLabel(spec.entry, timeframe)}`);
    if (spec.exit && spec.exit.conditions?.length !== 0) understood.push(`Sell when ${conditionLabel(spec.exit, timeframe)}`);
  } else if (has("rebalanc") && has("every month", "each month", "monthly")) {
    templateID = "etfRebalance"; name = "Monthly ETF Investing Agent";
    const funds = pick ?? UniverseCatalog.balancedETFs;
    spec = Templates.monthlyInvesting(funds, 0);
    const captured = firstMatch(String.raw`\b(?:invest|buy|allocate|contribute|put)\s+(?:a\s+fixed\s+amount\s+of\s+)?((?:a?\$\s*[\d,]+(?:\.\d+)?\s*[km]?(?![a-z])|[\d,]+(?:\.\d+)?\s*[km]?\s*(?:usd|aud|dollars)\b))`, lower);
    const amount = captured === undefined ? undefined : dollarAmounts(captured)[0];
    if (amount === undefined) assumptions.push("Enter the fixed monthly amount before running the strategy.");
    else {
      if (spec.monthlyInvestment) spec.monthlyInvestment.amount = amount;
      understood.push(`Monthly investment: ${money(amount, funds[0]?.currency)} total`);
    }
  } else if (has("rebalanc")) {
    templateID = "etfRebalance"; name = "ETF Rebalancing Agent";
    spec = Templates.etfRebalancing(pick ?? UniverseCatalog.balancedETFs);
  } else if (has("dollar-cost", "dollar cost", " dca", "recurring", "every week", "each week", "every month", "regularly")) {
    templateID = "dca"; name = "Dollar-Cost Averaging Agent";
    const interval = has("every day", "daily") ? 1 : (has("every month", "monthly") ? 21 : 5);
    spec = Templates.dollarCostAveraging(pick ?? [usETF("SPY", "S&P 500 ETF")], 100, interval);
  } else if (has("risk manag", "protect my", "guard my")) {
    templateID = "riskManager"; name = "Risk Management Agent";
    spec = Templates.riskManager();
  } else if (has("research") && !has("trade", "buy", "sell", "paper")) {
    templateID = "research"; name = "Portfolio Research Agent"; mode = "researchOnly";
    spec = Templates.portfolioResearch(pick ?? UniverseCatalog.technology);
  } else if (has("breakout", "break out", "breaks out", "new high")) {
    templateID = "breakout"; name = "Breakout Agent";
    spec = Templates.breakout(pick ?? UniverseCatalog.technology);
  } else if (has("mean reversion", "mean-reversion", "oversold", "buy the dip", "dips", "bollinger")) {
    templateID = "meanReversion"; name = "Mean Reversion Agent";
    spec = Templates.meanReversion(pick ?? UniverseCatalog.technology);
  } else if (has("crossover", "cross over", "cross-over", "crosses", "moving average", "moving-average")) {
    templateID = has("momentum") ? "momentum" : "trend";
    name = has("momentum") ? "Momentum Agent" : "Trend Following Agent";
    spec = Templates.movingAverageCrossover(pick ?? UniverseCatalog.technology, periods?.fast ?? 20, periods?.slow ?? 50, has("ema", "exponential"));
    if (!periods) assumptions.push("Used 20-day and 50-day averages for the crossover.");
  } else if (has("momentum")) {
    templateID = "momentum"; name = "Momentum Agent";
    spec = Templates.momentum(pick ?? UniverseCatalog.technology);
  } else if (has("trend")) {
    templateID = "trend"; name = "Trend Following Agent";
    spec = Templates.trendFollowing(pick ?? UniverseCatalog.broadETFs);
  } else if (assets.length > 0 && assets.every((i) => i.assetClass === "crypto")) {
    templateID = "cryptoMonitor"; name = "Crypto Agent";
    spec = Templates.cryptoMonitor(assets);
    assumptions.push("No strategy was named, so this uses a crypto trend strategy.");
  } else {
    templateID = "trend"; name = "Trend Following Agent";
    spec = Templates.trendFollowing(pick ?? UniverseCatalog.broadETFs);
    assumptions.push("No strategy was named, so this uses trend following.");
  }
  const allocation = spec.monthlyInvestment?.allocation ?? spec.rebalance;
  if (allocation) {
    const drift = driftPatterns.map((pattern) => firstMatch(pattern, lower)).find((value) => value !== undefined);
    if (drift !== undefined) {
      allocation.driftThresholdPct = Number(drift);
      understood.push(`Rebalance at ${trimNumber(Number(drift))} percentage points of drift`);
    } else if (spec.monthlyInvestment !== undefined) {
      if (has("threshold", "drift")) {
        allocation.driftThresholdPct = 0;
        assumptions.push("Enter the drift threshold before running the strategy.");
      } else assumptions.push("Used a 5 percentage point drift threshold.");
    }
    if (spec.monthlyInvestment !== undefined) {
      const weights = fundsWeights(text, spec.universe);
      if (Object.keys(weights).length) {
        allocation.targets = weights;
        understood.push("Used the ETF weights in your description.");
      } else assumptions.push("Used the default target weights. Review the ETF allocation before starting.");
    }
  }
  understood.push(`Strategy: ${spec.title}`);
  if (spec.followsLedgerPositions) {
    understood.push("Assets: the positions in the portfolio it guards");
  } else if (assets.length === 0) {
    assumptions.push(`No assets were named, so it starts with ${spec.universe.map((i) => i.symbol).join(", ")}.`);
  } else {
    understood.push(`Assets: ${note}`);
  }

  const currency = spec.universe[0]?.currency ?? "USD";
  const formattedMoney = (x: number): string => money(x, currency);
  if (currency !== "USD") assumptions.push(`These assets trade in ${currency}, so the agent's practice money is held in ${currency}.`);
  const budgetAmount = spec.monthlyInvestment !== undefined ? (
    firstMatch(String.raw`((?:a?\$\s*[\d,]+(?:\.\d+)?\s*[km]?|[\d,]+(?:\.\d+)?\s*(?:dollars|usd|aud)))\s+(?:starting\s+|paper\s+|practice\s+)?budget\b`, lower) ??
    firstMatch(String.raw`\bbudget(?:\s+of)?\s+((?:a?\$\s*[\d,]+(?:\.\d+)?\s*[km]?|[\d,]+(?:\.\d+)?\s*(?:dollars|usd|aud)))`, lower)
  ) : text;
  const amounts = budgetAmount ? dollarAmounts(budgetAmount) : [];
  let budget = Currencies.defaultBudget(currency);
  if (amounts.length > 0) {
    const largest = Math.max(...amounts);
    const smallest = Math.min(...amounts);
    if (spec.kind === "dca" && amounts.length >= 2 && smallest < largest) {
      budget = largest;
      if (spec.dca) spec.dca.amountPerBuy = smallest;
      spec.sizing.value = smallest;
      understood.push(`Buys ${formattedMoney(smallest)} at a time`);
    } else if (spec.kind === "dca" && largest < 1_000) {
      if (spec.dca) spec.dca.amountPerBuy = largest;
      spec.sizing.value = largest;
      understood.push(`Buys ${formattedMoney(largest)} at a time`);
      assumptions.push(`Used a ${formattedMoney(budget)} paper budget.`);
    } else {
      budget = largest;
    }
    if (budget === largest) understood.push(`Budget: ${formattedMoney(budget)}`);
  } else {
    assumptions.push(`Used a ${formattedMoney(budget)} paper budget.`);
  }

  let maxPositionPct = templateDefaults[templateID]?.maxPositionPct ?? 10;
  const policyEdits: ((policy: RiskPolicy) => void)[] = [];
  const riskText = spec.monthlyInvestment === undefined ? lower :
    driftPatterns.reduce((text, pattern) => text.replace(new RegExp(pattern, "g"), ""), lower);
  for (const { value, meaning } of percentages(riskText)) {
    switch (meaning) {
      case "trailingStop":
        spec.protections.trailingStopPct = value;
        understood.push(`Trailing stop: ${trimNumber(value)}%`);
        break;
      case "stopLoss":
        spec.protections.stopLossPct = value;
        understood.push(`Stop loss: ${trimNumber(value)}%`);
        break;
      case "takeProfit":
        spec.protections.takeProfitPct = value;
        understood.push(`Take profit: ${trimNumber(value)}%`);
        break;
      case "drawdown":
        policyEdits.push((p) => { p.maxDrawdownPct = value; });
        understood.push(`Drawdown limit: ${trimNumber(value)}%`);
        break;
      case "dailyLoss":
        policyEdits.push((p) => { p.maxDailyLossPct = value; });
        understood.push(`Daily loss limit: ${trimNumber(value)}%`);
        break;
      case "position":
        maxPositionPct = value;
        if (spec.sizing.mode === "percentOfEquity" && spec.kind === "rules") spec.sizing.value = Math.min(spec.sizing.value, value);
        understood.push(`Position limit: ${trimNumber(value)}% each`);
        break;
    }
  }

  if (templateID === "customRules" && spec.entry && !spec.exit && !Object.values(spec.protections).some(value => value !== undefined)) {
    assumptions.push("Add a sell condition or a protective exit before running this strategy.");
  }

  if (has("research only", "research-only")) mode = "researchOnly";
  else if (has("signal") && !has("paper")) mode = "signals";
  if (has("real money", "live trading", "live money", "trade live", "go live")) {
    assumptions.push("Live trading isn't available, so this is set up as paper trading.");
  }
  if (mode === "paper" && spec.kind === "research") mode = "researchOnly";
  understood.push(`Mode: ${agentModeDisplayName(mode)}`);
  const review = has("approve", "approval", "ask me", "confirm with me", "check with me", "my permission");
  if (review && mode === "paper") understood.push("Each paper trade waits for your approval");

  let schedule = { intervalMinutes: templateDefaults[templateID]?.intervalMinutes ?? 60 };
  const minutesText = firstMatch(String.raw`every\s+(\d{1,3})\s*min`, lower);
  const minutes = minutesText === undefined ? undefined : Number(minutesText);
  if (minutes !== undefined && minutes >= 5 && minutes <= 720) schedule = { intervalMinutes: minutes };
  else if (has("every hour", "hourly")) schedule = { intervalMinutes: 60 };
  else if (has("once a day", "daily", "every day") && spec.kind !== "dca") schedule = { intervalMinutes: 1_440 };
  const custom = firstMatch(String.raw`(?:called|named)\s+["“']?([A-Za-z0-9][A-Za-z0-9 &'-]{1,38})`, text);
  if (custom !== undefined) name = custom.replace(/^[ "”'.,]+|[ "”'.,]+$/g, "");

  const policy = standardPolicy(budget, maxPositionPct, spec.universe.length > 0 && spec.universe.every((i) => i.assetClass === "crypto"), currency);
  for (const edit of policyEdits) edit(policy);
  const draft = makeDraft({ name, templateID, mode, spec, budget, maxPositionPct, riskPolicy: policy,
    reviewEachPaperTrade: review, schedule, author: "user" });
  return { draft, understood, assumptions, unrecognisedSymbols: unknown };
}

export function decodeDraft(json: string): ParsedAgentRequest {
  const start = json.indexOf("{");
  const end = json.lastIndexOf("}");
  if (start < 0 || end < 0 || start >= end) throw TradingError.invalid(["The reply didn't contain a strategy."]);
  let envelope: DraftEnvelope;
  try {
    envelope = decodeEnvelope(JSON.parse(json.slice(start, end + 1)));
  } catch {
    throw TradingError.invalid(["The drafted strategy wasn't in the expected format."]);
  }
  const assumptions: string[] = [];
  let mode = envelope.mode ?? "paper";
  if (modeIsLive(mode)) {
    mode = "paper";
    assumptions.push("Live trading isn't available, so this is set up as paper trading.");
  }
  if (mode === "paper" && envelope.spec.kind === "research") mode = "researchOnly";
  const currency = envelope.spec.universe[0]?.currency ?? "USD";
  const range = Currencies.budgetRange(currency);
  const budget = Math.min(Math.max(envelope.budget ?? Currencies.defaultBudget(currency), range.lowerBound), range.upperBound);
  const draft = makeDraft({ name: prefixCharacters(envelope.name, 40), mode, spec: envelope.spec, budget,
    maxPositionPct: Math.min(Math.max(envelope.maxPositionPct ?? 10, 1), 100),
    reviewEachPaperTrade: envelope.reviewEachPaperTrade ?? false,
    schedule: { intervalMinutes: Math.min(Math.max(envelope.intervalMinutes ?? 60, 5), 10_080) }, author: "copilot" });
  const problems = StrategyValidator.validate(draft.spec).filter((issue) => issue.severity === "error").map((issue) => issue.message);
  if (problems.length > 0) throw TradingError.invalid(problems);
  return { draft, understood: envelope.notes ?? [], assumptions, unrecognisedSymbols: [] };
}

function prefixCharacters(text: string, count: number): string {
  // Swift String.prefix counts extended grapheme clusters, including joined emoji.
  const segments = new Intl.Segmenter("en", { granularity: "grapheme" }).segment(text);
  let result = "";
  let length = 0;
  for (const { segment } of segments) {
    if (length++ >= count) break;
    result += segment;
  }
  return result;
}

function decodeEnvelope(raw: unknown): DraftEnvelope {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new Error("Invalid envelope");
  const o = raw as Record<string, unknown>;
  if (typeof o.name !== "string") throw new Error("Invalid name");
  const envelope: DraftEnvelope = { name: o.name, spec: decodeStrategySpec(o.spec) };
  const present = (key: string): boolean => o[key] !== undefined && o[key] !== null;
  if (present("mode")) {
    if (typeof o.mode !== "string" || !AGENT_MODES.includes(o.mode as AgentMode)) throw new Error("Invalid mode");
    envelope.mode = o.mode as AgentMode;
  }
  for (const key of ["budget", "maxPositionPct", "intervalMinutes"] as const) {
    if (!present(key)) continue;
    const value = o[key];
    if (typeof value !== "number" || !Number.isFinite(value) || (key === "intervalMinutes" && !Number.isSafeInteger(value))) {
      throw new Error(`Invalid ${key}`);
    }
    envelope[key] = value;
  }
  if (present("reviewEachPaperTrade")) {
    if (typeof o.reviewEachPaperTrade !== "boolean") throw new Error("Invalid reviewEachPaperTrade");
    envelope.reviewEachPaperTrade = o.reviewEachPaperTrade;
  }
  if (present("notes")) {
    if (!Array.isArray(o.notes) || !o.notes.every((note) => typeof note === "string")) throw new Error("Invalid notes");
    envelope.notes = o.notes;
  }
  return envelope;
}

const themes: { words: string[]; label: string; list: Instrument[] }[] = [
  { words: ["uk stock", "uk share", "british", "ftse", "london"], label: "UK blue chips", list: UniverseCatalog.ukBlueChips },
  { words: ["german", "dax", "frankfurt"], label: "German blue chips", list: UniverseCatalog.germanBlueChips },
  { words: ["european", "europe", "euro stoxx", "eurozone"], label: "European blue chips", list: UniverseCatalog.euroBlueChips },
  { words: ["french", "cac 40", "paris"], label: "French blue chips", list: UniverseCatalog.frenchBlueChips },
  { words: ["dutch", "amsterdam", "netherlands"], label: "Dutch blue chips", list: UniverseCatalog.dutchBlueChips },
  { words: ["swiss", "switzerland", "zurich"], label: "Swiss blue chips", list: UniverseCatalog.swissBlueChips },
  { words: ["japan", "japanese", "nikkei", "topix", "tokyo"], label: "Japanese blue chips", list: UniverseCatalog.japanBlueChips },
  { words: ["hong kong", "hang seng", "chinese stock", "china stock"], label: "Hong Kong blue chips", list: UniverseCatalog.hongKongBlueChips },
  { words: ["singapore", "sti "], label: "Singapore blue chips", list: UniverseCatalog.singaporeBlueChips },
  { words: ["korea", "korean", "kospi"], label: "Korean blue chips", list: UniverseCatalog.koreaBlueChips },
  { words: ["india", "indian", "nifty", "sensex"], label: "Indian blue chips", list: UniverseCatalog.indiaBlueChips },
  { words: ["asian", "asia"], label: "Japanese blue chips", list: UniverseCatalog.japanBlueChips },
  { words: ["semiconductor", "chip stock", "chipmaker", "chip maker"], label: "semiconductor stocks", list: UniverseCatalog.semiconductors },
  { words: ["technology", "tech stock", "tech compan", "big tech", "tech sector"], label: "technology stocks", list: UniverseCatalog.technology },
  { words: ["bank", "financial"], label: "financial stocks", list: UniverseCatalog.financials },
  { words: ["healthcare", "health care", "pharma"], label: "healthcare stocks", list: UniverseCatalog.healthcare },
  { words: ["energy stock", "oil"], label: "energy stocks", list: UniverseCatalog.energy },
  { words: ["crypto", "coins"], label: "major crypto", list: UniverseCatalog.cryptoMajors },
  { words: ["asx", "australian stock", "australian share", "aussie"], label: "ASX blue chips", list: UniverseCatalog.asxBlueChips },
  { words: ["etf", "index fund", "funds"], label: "broad-market ETFs", list: UniverseCatalog.broadETFs },
];

const names: Record<string, string> = {
  bitcoin: "BTC", ethereum: "ETH", ether: "ETH", solana: "SOL", dogecoin: "DOGE", cardano: "ADA",
  apple: "AAPL", microsoft: "MSFT", nvidia: "NVDA", alphabet: "GOOGL", google: "GOOGL",
  amazon: "AMZN", meta: "META", tesla: "TSLA", netflix: "NFLX", broadcom: "AVGO",
  "s&p 500": "SPY", "s&p500": "SPY", sp500: "SPY", nasdaq: "QQQ",
  toyota: "7203", sony: "6758", nintendo: "7974", softbank: "9984", tencent: "0700",
  alibaba: "9988", lvmh: "MC", asml: "ASML", nestle: "NESN", "nestlé": "NESN", novartis: "NOVN",
  astrazeneca: "AZN", siemens: "SIE", samsung: "005930", reliance: "RELIANCE", infosys: "INFY",
  unilever: "ULVR", vodafone: "VOD", barclays: "BARC", hsbc: "HSBA", dbs: "D05", airbus: "AIR",
};

const homeVenue: Record<string, Venue> = {
  "7203": "tse", "6758": "tse", "7974": "tse", "9984": "tse", "0700": "hkex", "9988": "hkex", MC: "euronextParis",
  ASML: "euronextAmsterdam", NESN: "six", NOVN: "six", AZN: "lse", SIE: "xetra", "005930": "krx",
  RELIANCE: "nse", INFY: "nse", ULVR: "lse", VOD: "lse", BARC: "lse", HSBA: "lse", D05: "sgx", AIR: "euronextParis",
};

const notTickers = new Set([
  "AI", "ETF", "ETFS", "USD", "AUD", "RSI", "MACD", "DCA", "ASX", "US", "USA", "EMA", "SMA", "MA", "ATR",
  "I", "A", "AN", "THE", "AND", "OR", "TO", "IT", "IN", "ON", "OF", "MY", "ME", "IF", "AT", "BY", "FOR",
  "BUY", "SELL", "HOLD", "CREATE", "PAPER", "LIVE", "STOP", "LOSS", "ALL", "NYSE", "NASDAQ", "CEO", "IPO", "PE", "UK", "EU",
]);

export function instruments(text: string): Instrument[] { return universe(text).instruments; }

function universe(text: string): { instruments: Instrument[]; unknown: string[]; note: string } {
  const lower = text.toLowerCase();
  const seen = new Set<string>();
  let out: Instrument[] = [];
  const labels: string[] = [];
  const add = (instrument: Instrument): void => {
    const id = instrumentID(instrument);
    if (!seen.has(id)) { seen.add(id); out.push({ ...instrument }); }
  };
  const unknown: string[] = [];
  const wantsASX = lower.includes("asx") || lower.includes("australian");
  for (const token of text.match(foundationRegex(String.raw`\$[A-Za-z]{1,6}\b|\b[A-Z]{2,6}\b`, "g")) ?? []) {
    const upper = token.toUpperCase();
    const explicit = upper.startsWith("$");
    const symbol = explicit ? upper.slice(1) : upper;
    if (notTickers.has(symbol)) continue;
    const instrument = lookupInstrument(symbol, wantsASX ? "asx" : undefined);
    if (instrument) add(instrument);
    else if (explicit && StrategyValidator.isValidSymbol(symbol)) unknown.push(symbol);
  }
  for (const word of Object.keys(names).sort(compareStrings)) {
    if (!lower.includes(word)) continue;
    if (word === "meta" && firstMatch("(?<![a-z])meta(?![a-z])", lower, 0) === undefined) continue;
    if (word === "ether" && lower.includes("ethereum")) continue;
    const symbol = names[word];
    const instrument = lookupInstrument(symbol, homeVenue[symbol]);
    if (instrument) add(instrument);
  }
  if (out.length > 0) labels.push(out.map((i) => i.symbol).join(", "));
  if (out.length === 0) {
    for (const theme of themes) {
      if (!theme.words.some((word) => lower.includes(word))) continue;
      theme.list.forEach(add);
      labels.push(theme.label);
    }
  }
  const currency = out[0]?.currency;
  if (currency !== undefined && out.some((i) => i.currency !== currency)) {
    out = out.filter((i) => i.currency === currency);
    labels.push(`(${currency} assets only — an agent trades in one currency)`);
  }
  if (out.length > StrategyValidator.maxUniverse) out = out.slice(0, StrategyValidator.maxUniverse);
  return { instruments: out, unknown, note: labels.join(" ") };
}

function fundsWeights(text: string, funds: Instrument[]): Record<string, number> {
  const targets: Record<string, number> = {};
  for (const fund of funds) {
    const ticker = fund.symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const weight = firstMatch(String.raw`\b(\d+(?:\.\d+)?)\s*%\s*(?:in\s+|to\s+)?\$?` + ticker + String.raw`\b`, text) ??
      firstMatch(String.raw`\b` + ticker + String.raw`\s*(?:at|:|=)?\s*(\d+(?:\.\d+)?)\s*%`, text);
    if (weight !== undefined) targets[instrumentID(fund)] = Number(weight);
  }
  return targets;
}

function dollarAmounts(text: string): number[] {
  const regex = foundationRegex(String.raw`(?:a?\$\s?([\d,]+(?:\.\d+)?)\s*([kKmM])?(?![a-zA-Z]))|(?:\b([\d,]+(?:\.\d+)?)\s*([kKmM])?\s*(?:dollars|usd|aud)\b)`, "g");
  const amounts: number[] = [];
  for (const match of text.matchAll(regex)) {
    let value = Number((match[1] ?? match[3]).replaceAll(",", ""));
    const suffix = (match[2] ?? match[4])?.toLowerCase();
    if (suffix === "k") value *= 1_000;
    else if (suffix === "m") value *= 1_000_000;
    if (value > 0) amounts.push(value);
  }
  return amounts;
}

type PercentMeaning = "trailingStop" | "stopLoss" | "takeProfit" | "drawdown" | "dailyLoss" | "position";

function meaning(words: string): PercentMeaning | undefined {
  if (words.includes("trailing")) return "trailingStop";
  if (words.includes("stop")) return "stopLoss";
  if (words.includes("take profit") || words.includes("take-profit") || words.includes("profit target")) return "takeProfit";
  if (words.includes("drawdown")) return "drawdown";
  if (["daily loss", "loss per day", "lose", "loss a day"].some((word) => words.includes(word))) return "dailyLoss";
  if (["position", "each", "per ", "allocation", "any one", "single"].some((word) => words.includes(word))) return "position";
  return undefined;
}

function percentages(lower: string): { value: number; meaning: PercentMeaning }[] {
  const out: { value: number; meaning: PercentMeaning }[] = [];
  for (const match of lower.matchAll(foundationRegex(String.raw`(\d{1,3}(?:\.\d+)?)\s*(?:%|percent)`, "g"))) {
    const value = Number(match[1]);
    if (!(value > 0 && value <= 100)) continue;
    const start = Math.max(match.index! - 48, 0);
    const matchEnd = match.index! + match[0].length;
    const end = Math.min(matchEnd + 30, lower.length);
    let before = lower.slice(start, match.index);
    const breaksBefore = Array.from(before.matchAll(/[\p{N}%.;,]/gu));
    if (breaksBefore.length > 0) {
      const cut = breaksBefore[breaksBefore.length - 1];
      before = before.slice(cut.index! + cut[0].length);
    }
    let after = lower.slice(matchEnd, end);
    const cutAfter = /[\p{N}.;,]/u.exec(after);
    if (cutAfter) after = after.slice(0, cutAfter.index);
    const lead = before.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
    const nameCameFirst = ["of", "to", "at", "is", "by", "than", "under", "below", "above", "within", "exceeds", "reaches", ":", "="]
      .some((word) => lead.endsWith(" " + word) || lead === word);
    const result = nameCameFirst ? (meaning(before) ?? meaning(after)) : (meaning(after) ?? meaning(before));
    if (result) out.push({ value, meaning: result });
  }
  return out;
}

function averagePeriods(lower: string): { fast: number; slow: number } | undefined {
  let found = Array.from(lower.matchAll(foundationRegex(String.raw`(\d{1,3})\s*[- ]?\s*(?:day|d\b|period|bar)`, "g")),
    (match) => Number(match[1])).filter(Number.isFinite);
  if (found.length < 2) {
    const pair = firstMatch(String.raw`\b(\d{1,3}\s*/\s*\d{1,3})\b`, lower);
    if (pair !== undefined) found = pair.split("/").map((s) => Number(s.trim()));
  }
  const valid = Array.from(new Set(found.filter((v) => v >= 2 && v <= StrategyValidator.maxPeriod))).sort((a, b) => a - b);
  if (valid.length < 2) return undefined;
  return { fast: valid[0], slow: valid[valid.length - 1] };
}

function foundationRegex(pattern: string, flags = ""): RegExp {
  // ICU's word, digit and whitespace sets are Unicode-aware; JavaScript's \b and
  // \d stay ASCII even with /u. All patterns used here have standalone \b escapes.
  const word = String.raw`[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\u200c\u200d]`;
  const boundary = `(?:(?<=${word})(?!${word})|(?<!${word})(?=${word}))`;
  return new RegExp(pattern.replaceAll(String.raw`\b`, boundary)
    .replaceAll(String.raw`\d`, String.raw`\p{Nd}`).replaceAll(String.raw`\s`, String.raw`\p{White_Space}`), flags + "u");
}

function firstMatch(pattern: string, text: string, group = 1): string | undefined {
  return foundationRegex(pattern, "i").exec(text)?.[group];
}

export const StrategyParser = { parse, decodeDraft, instruments, universe, dollarAmounts, percentages, averagePeriods };
