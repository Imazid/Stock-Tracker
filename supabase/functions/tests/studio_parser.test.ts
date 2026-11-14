// Mirrors the parser cases in TradingCore/Tests/TradingCoreTests/StrategyTests.swift.
// Run: npx -y deno test --allow-read supabase/functions/tests/studio_*.test.ts

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { decodeDraft, instruments, parse, StrategyParser } from "../_shared/studio/mod.ts";
import { UniverseCatalog } from "../_shared/trading/catalog.ts";
import { Currencies } from "../_shared/trading/currencies.ts";
import { cryptoAsset, instrumentID } from "../_shared/trading/market.ts";
import { resolvedPolicy, TradingError } from "../_shared/trading/state.ts";
import { Op, Rule, StrategyValidator } from "../_shared/trading/strategy.ts";
import * as Templates from "../_shared/trading/templates.ts";
import { Fx } from "./fixtures.ts";

Deno.test("the example request becomes a validated draft", () => {
  const parsed = parse("Create an agent that monitors technology stocks, identifies momentum opportunities and proposes trades based on moving-average crossovers. Give it a $5,000 paper portfolio and limit each position to 10%.");
  const draft = parsed.draft;
  assertEquals(draft.name, "Momentum Agent");
  assertEquals(draft.mode, "paper");
  assertEquals(draft.budget, 5_000);
  assertEquals(draft.maxPositionPct, 10);
  assertEquals(resolvedPolicy(draft).maxPositionPct, 10);
  assertEquals(resolvedPolicy(draft).maxOrderNotional, 500);
  assertEquals(draft.spec.universe.map((i) => i.symbol), UniverseCatalog.technology.map((i) => i.symbol));
  assertEquals(draft.spec.entry, Rule.crossesAbove(Op.sma(20), Op.sma(50)));
  assertEquals(draft.spec.exit, Rule.crossesBelow(Op.sma(20), Op.sma(50)));
  assert(StrategyValidator.isValid(draft.spec));
  assert(parsed.understood.includes("Budget: $5,000"));
  assert(parsed.understood.includes("Position limit: 10% each"));
  assert(parsed.assumptions.some((s) => s.includes("20-day and 50-day")));
});

Deno.test("crypto request and explicit periods", () => {
  const crypto = parse("Create a paper-trading strategy for BTC and ETH");
  assertEquals(crypto.draft.spec.universe, [Fx.btc, cryptoAsset("ETH", "Ethereum")]);
  assertEquals(crypto.draft.mode, "paper");
  assertEquals(resolvedPolicy(crypto.draft).maxSpreadBps, 100);
  const periods = parse("Trade NVDA and AMD when the 10-day EMA crosses the 30-day EMA");
  assertEquals(periods.draft.spec.entry, Rule.crossesAbove(Op.ema(10), Op.ema(30)));
  assertEquals(periods.draft.spec.universe.map((i) => i.symbol), ["NVDA", "AMD"]);
});

Deno.test("percentages are read from either side of their name", () => {
  const a = parse("Momentum agent on NVDA with an 8% stop loss and 12% trailing stop, ask me before each trade");
  assertEquals(a.draft.spec.protections.stopLossPct, 8);
  assertEquals(a.draft.spec.protections.trailingStopPct, 12);
  assert(a.draft.reviewEachPaperTrade);
  const b = parse("Trend agent for SPY, stop loss of 6% and trailing stop of 9%, max drawdown of 20%, 25% per position");
  assertEquals(b.draft.spec.protections.stopLossPct, 6);
  assertEquals(b.draft.spec.protections.trailingStopPct, 9);
  assertEquals(resolvedPolicy(b.draft).maxDrawdownPct, 20);
  assertEquals(b.draft.maxPositionPct, 25);
  const c = parse("Breakout agent on AAPL with an 8% stop loss and 10% per position");
  assertEquals(c.draft.spec.protections.stopLossPct, 8);
  assertEquals(c.draft.maxPositionPct, 10);
});

Deno.test("scheduled buys separate the budget from the amount", () => {
  const parsed = parse("Buy $100 of SPY every week with a $5,000 budget");
  assertEquals(parsed.draft.spec.kind, "dca");
  assertEquals(parsed.draft.spec.dca, { amountPerBuy: 100, intervalBars: 5 });
  assertEquals(parsed.draft.budget, 5_000);
  assertEquals(parsed.draft.spec.universe.map((i) => i.symbol), ["SPY"]);
});

Deno.test("live requests are set up as paper", () => {
  const parsed = parse("Trend following on AAPL, trade live with real money");
  assertEquals(parsed.draft.mode, "paper");
  assert(parsed.assumptions.some((s) => s.includes("Live trading isn't available")));
});

Deno.test("unknown tickers are reported, not invented", () => {
  const parsed = parse("Momentum on $ZZZZ and $AAPL");
  assertEquals(parsed.unrecognisedSymbols, ["ZZZZ"]);
  assertEquals(parsed.draft.spec.universe.map((i) => i.symbol), ["AAPL"]);
  assertEquals(parse("I WANT TO BUY THE DIP IN AAPL").draft.spec.universe.map((i) => i.symbol), ["AAPL"]);
});

Deno.test("mixed currencies keep one currency", () => {
  const parsed = parse("Trend agent on AAPL, MSFT and BHP");
  assertEquals(new Set(parsed.draft.spec.universe.map((i) => i.currency)), new Set(["USD"]));
  assert(StrategyValidator.isValid(parsed.draft.spec));
});

Deno.test("dollar amounts", () => {
  assertEquals(StrategyParser.dollarAmounts("$5,000 and $2.5k and 300 dollars and A$1m"), [5_000, 2_500, 300, 1_000_000]);
  assertEquals(StrategyParser.dollarAmounts("the 50-day average"), []);
});

const modelJSON = `Here is the strategy:
{"name":"RSI dip buyer","mode":"autonomousLive","budget":2500,"maxPositionPct":20,
 "spec":{"kind":"rules","title":"RSI dips","summary":"Buys oversold tech","timeframe":"day",
         "universe":[{"symbol":"AAPL"},{"symbol":"MSFT"}],
         "entry":{"op":"below","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":30}},
         "exit":{"op":"above","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":55}},
         "protections":{"stopLossPct":7},"sizing":{"mode":"percentOfEquity","value":20},
         "reentryCooldownBars":1,"followsLedgerPositions":false}}`;

Deno.test("model drafts are decoded strictly and never live", () => {
  const parsed = decodeDraft(modelJSON);
  assertEquals(parsed.draft.mode, "paper");
  assertEquals(parsed.draft.author, "copilot");
  assertEquals(parsed.draft.budget, 2_500);
  assertEquals(parsed.draft.spec.entry, Rule.below(Op.rsi(14), Op.constant(30)));
  assert(parsed.assumptions.some((s) => s.includes("Live trading")));
  const broken = modelJSON.replace('"exit":{"op":"above","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":55}},', "")
    .replace('"protections":{"stopLossPct":7}', '"protections":{}');
  assertThrows(() => decodeDraft(broken), TradingError);
  assertThrows(() => decodeDraft("Sure! I'd buy NVDA."), TradingError);
  assertThrows(() => decodeDraft('{"name":"x","spec":{"kind":"wire-money"}}'), TradingError);
});

// Additional coverage for public instrument lookup, wording, template metadata and
// untrusted envelope fields that Swift's Codable decoder type-checks.
Deno.test("parser wording and default metadata match Swift", () => {
  const parsed = parse("Create an agent that monitors technology stocks, identifies momentum opportunities and proposes trades based on moving-average crossovers. Give it a $5,000 paper portfolio and limit each position to 10%.");
  assertEquals(parsed.understood, ["Strategy: Moving-average crossover", "Assets: technology stocks", "Budget: $5,000", "Position limit: 10% each", "Mode: Paper trading"]);
  assertEquals(parsed.assumptions, ["Used 20-day and 50-day averages for the crossover."]);
  const defaults = parse("");
  assertEquals(defaults.draft.maxPositionPct, 25);
  assertEquals(defaults.assumptions, [
    "No strategy was named, so this uses trend following.",
    "No assets were named, so it starts with SPY, QQQ, VTI, IWM.",
    "Used a $10,000 paper budget.",
  ]);
  const cases: [string, string, number, number][] = [
    ["Momentum", "momentum", 10, 60], ["Trend", "trend", 25, 60], ["Oversold", "meanReversion", 10, 60],
    ["Recurring buys", "dca", 60, 1_440], ["Breakout", "breakout", 10, 60], ["Rebalance", "etfRebalance", 70, 1_440],
    ["BTC", "cryptoMonitor", 35, 60], ["Protect my portfolio", "riskManager", 100, 60], ["Research", "research", 10, 1_440],
  ];
  for (const [text, templateID, maxPositionPct, intervalMinutes] of cases) {
    const { draft } = parse(text);
    assertEquals([draft.templateID, draft.maxPositionPct, draft.schedule.intervalMinutes], [templateID, maxPositionPct, intervalMinutes], text);
  }
});

Deno.test("instrument lookup honours themes, names, home venues, deduplication and currency", () => {
  assertEquals(instruments("BTC and bitcoin and ethereum"), [Fx.btc, cryptoAsset("ETH", "Ethereum")]);
  assertEquals(instruments("technology stocks"), UniverseCatalog.technology);
  assertEquals(instruments("technology stocks and $AAPL"), [Fx.aapl]);
  assertEquals(instruments("metadata"), []);
  assertEquals(instruments("caféAAPL $AAPLé"), []);
  assertEquals(instruments("Toyota and Sony").map(instrumentID), ["tse:6758", "tse:7203"]);
  const british = parse("Trend following on British stocks");
  assertEquals(british.draft.spec.universe, UniverseCatalog.ukBlueChips);
  assert(british.assumptions.includes("These assets trade in GBP, so the agent's practice money is held in GBP."));
  assertEquals(parse("Trend agent on AAPL, MSFT and BHP").understood[1], "Assets: AAPL, MSFT, BHP (USD assets only — an agent trades in one currency)");
});

Deno.test("amounts, schedules, modes, names and remaining percentage meanings", () => {
  const scheduled = parse("Recurring buys of $25.5 of SPY every month");
  assertEquals(scheduled.draft.spec.dca, { amountPerBuy: 25.5, intervalBars: 21 });
  assertEquals(scheduled.understood[2], "Buys $25.5 at a time");
  assertEquals(scheduled.assumptions, ["Used a $10,000 paper budget."]);
  const daily = parse("Recurring daily purchases of SPY");
  assertEquals([daily.draft.spec.dca?.intervalBars, daily.draft.schedule.intervalMinutes], [1, 1_440]);
  assertEquals(parse("Trend on AAPL every 15 minutes").draft.schedule.intervalMinutes, 15);
  assertEquals(parse("Trend on AAPL daily").draft.schedule.intervalMinutes, 1_440);
  assertEquals(parse("Trend on AAPL every hour").draft.schedule.intervalMinutes, 60);
  assertEquals(parse("Trend on AAPL, signals").draft.mode, "signals");
  assertEquals(parse("Trend on AAPL, research only").draft.mode, "researchOnly");
  assertEquals(parse('Trend on AAPL called "My Agent"').draft.name, "My Agent");
  const limits = parse("Trend on AAPL, take profit of 12.5%, daily loss of 2%, position limit of 5%");
  assertEquals(limits.draft.spec.protections.takeProfitPct, 12.5);
  assertEquals(resolvedPolicy(limits.draft).maxDailyLossPct, 2);
  assertEquals([limits.draft.maxPositionPct, limits.draft.spec.sizing.value], [5, 5]);
  assertEquals(limits.understood.slice(2, 5), ["Take profit: 12.50%", "Daily loss limit: 2%", "Position limit: 5% each"]);
  assertEquals(StrategyParser.averagePeriods("50/200"), { fast: 50, slow: 200 });
});

Deno.test("draft decoding clamps limits, preserves notes and counts Swift characters", () => {
  const name = "👨‍👩‍👧‍👦".repeat(41);
  const envelope = { name, mode: "approvalRequired", budget: -1, maxPositionPct: 200,
    intervalMinutes: 1, reviewEachPaperTrade: true, notes: ["Exact model note."], spec: Templates.trendFollowing([Fx.aapl]) };
  const parsed = decodeDraft(`\u0060\u0060\u0060json\n${JSON.stringify(envelope)}\n\u0060\u0060\u0060`);
  assertEquals(parsed.draft.name, "👨‍👩‍👧‍👦".repeat(40));
  assertEquals(parsed.draft.mode, "paper");
  assertEquals(parsed.draft.budget, Currencies.budgetRange("USD").lowerBound);
  assertEquals(parsed.draft.maxPositionPct, 100);
  assertEquals(parsed.draft.schedule.intervalMinutes, 5);
  assertEquals(parsed.draft.reviewEachPaperTrade, true);
  assertEquals(parsed.understood, ["Exact model note."]);
  assertEquals(parsed.unrecognisedSymbols, []);
  const research = decodeDraft(JSON.stringify({ name: "R", spec: Templates.portfolioResearch([Fx.aapl]) }));
  assertEquals(research.draft.mode, "researchOnly");
  const high = decodeDraft(JSON.stringify({ ...envelope, budget: 1e12, maxPositionPct: -1, intervalMinutes: 20_000 }));
  assertEquals([high.draft.budget, high.draft.maxPositionPct, high.draft.schedule.intervalMinutes], [Currencies.budgetRange("USD").upperBound, 1, 10_080]);
});

Deno.test("draft envelope rejects wrong types with the same errors as Swift", () => {
  const envelope = { name: "A", spec: Templates.trendFollowing([Fx.aapl]) };
  const invalid: Record<string, unknown>[] = [
    { name: 123 }, { mode: "live" }, { budget: "5000" }, { maxPositionPct: false }, { intervalMinutes: 5.5 },
    { reviewEachPaperTrade: 1 }, { notes: ["ok", 1] }, { spec: [] },
  ];
  for (const fields of invalid) {
    const error = assertThrows(() => decodeDraft(JSON.stringify({ ...envelope, ...fields })), TradingError);
    assertEquals(error.messages, ["The drafted strategy wasn't in the expected format."]);
  }
  assertEquals(assertThrows(() => decodeDraft("Sure! I'd buy NVDA."), TradingError).messages, ["The reply didn't contain a strategy."]);
  const nullable = decodeDraft(JSON.stringify({ ...envelope, mode: null, budget: null, notes: null }));
  assertEquals([nullable.draft.mode, nullable.draft.budget, nullable.understood], ["paper", 10_000, []]);
});


Deno.test("explicit rules preserve comparisons, grouping, direction and draft settings", () => {
  const parsed = parse("Buy ETH when RSI(7) drops below 28.5 and price is above its 20-day EMA, or RSI(7) crosses above 35. Sell when RSI rises above 65, with a $5,000 budget, 8% per position and an 18% max drawdown.");
  const { spec } = parsed.draft;
  assertEquals(spec.universe.map((asset) => asset.symbol), ["ETH"]);
  assertEquals(spec.entry, {
    op: "any", conditions: [{
      op: "all", conditions: [
        { op: "below", left: { kind: "rsi", period: 7 }, right: { kind: "constant", value: 28.5 } },
        { op: "above", left: { kind: "price", field: "close" }, right: { kind: "ema", period: 20 } },
      ],
    }, { op: "crossesAbove", left: { kind: "rsi", period: 7 }, right: { kind: "constant", value: 35 } }],
  });
  assertEquals(spec.exit, { op: "above", left: { kind: "rsi", period: 14 }, right: { kind: "constant", value: 65 } });
  assertEquals(parsed.draft.budget, 5000);
  assertEquals(parsed.draft.maxPositionPct, 8);
  assertEquals(parsed.draft.riskPolicy?.maxDrawdownPct, 18);
  assertEquals(parsed.assumptions.includes("Used 14 bars wherever the RSI period was omitted."), true);

  const directed = parse("Buy BTC when its 50-day average crosses below its 20-day average, and sell on the opposite crossover");
  assertEquals(directed.draft.spec.entry?.op, "crossesBelow");
  assertEquals(directed.draft.spec.entry?.left?.period, 50);
  assertEquals(directed.draft.spec.exit?.op, "crossesAbove");
});

Deno.test("explicit incomplete and unsupported rules need review", () => {
  const missingExit = parse("Buy ETH when RSI drops below 30");
  assertEquals(missingExit.draft.spec.entry?.right?.value, 30);
  assertEquals(missingExit.draft.spec.exit, undefined);
  const unsupported = parse("Buy ETH when RSI is below 30 and sell when RSI is above 60 and sentiment improves, with a 5% stop loss");
  assertEquals(unsupported.draft.spec.protections.stopLossPct, 5);
  assertEquals(unsupported.draft.spec.exit, { op: "all", conditions: [] });
  assertEquals(parse("Buy ETH when RSI is below or equal to 30 and sell when RSI is above 65").draft.spec.entry, undefined);
});

Deno.test("monthly investing parses the total amount, allocation, drift and capital", () => {
  const { draft } = parse("Invest $150 each month in 60% VTI, 20% VXUS and 20% BND. Rebalance when allocations drift by 5 points, with a $5,000 budget.");
  assertEquals(draft.spec.monthlyInvestment, {
    amount: 150, allocation: { targets: { "us:VTI": 60, "us:VXUS": 20, "us:BND": 20 }, driftThresholdPct: 5 },
  });
  assertEquals(draft.spec.rebalance, undefined);
  assertEquals(draft.budget, 5_000);
  assertEquals(StrategyValidator.validate(draft.spec).filter((issue) => issue.severity === "error"), []);
  const incomplete = parse("Invest a fixed amount every month into a diversified ETF portfolio and rebalance when allocations drift beyond my threshold.").draft.spec;
  assertEquals(incomplete.monthlyInvestment?.amount, 0);
  assertEquals(incomplete.monthlyInvestment?.allocation.driftThresholdPct, 0);
  assertEquals(StrategyValidator.validate(incomplete).filter((issue) => issue.severity === "error").length, 2);
});
