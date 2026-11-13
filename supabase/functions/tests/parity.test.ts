// Parity with the Swift core. Each test loads one file of shared vectors from
// TradingCore/Tests/Vectors (written by ParityVectorTests.swift from the Swift
// implementation) and must reproduce every case exactly: same doubles, same text.
//
// Run: npx -y deno test --allow-read supabase/functions/tests/parity.test.ts

import { agentModeDisplayName, AGENT_MODES, modeIsLive, modePlacesOrders, modeProducesSignals, scheduleDisplayName } from "../_shared/trading/agent.ts";
import { appendAudit, AUDIT_KINDS, auditKindTitle, canonical, genesisHash, lastHash, makeAuditLog, nextSequence, verifyAudit } from "../_shared/trading/audit.ts";
import { LiveVenues, PaperBroker, type PaperBrokerConfig } from "../_shared/trading/broker.ts";
import * as Calendar from "../_shared/trading/calendar.ts";
import { catalogInstruments } from "../_shared/trading/catalog.ts";
import { manualPolicy } from "../_shared/trading/engine.ts";
import { decideAt, decideDCA, PreparedSeries, rebalanceTrades, researchFacts } from "../_shared/trading/evaluator.ts";
import * as Ledgers from "../_shared/trading/ledger.ts";
import { Currencies } from "../_shared/trading/currencies.ts";
import {
  type Bar, decodeInstrument, fixtureProvenance, hasTwoSidedMarket, instrumentID, listed, makeBarSeries, measureStats, parseYahooSymbol,
  type Quote, quoteMid, quoteSpreadBps, regionDisplayName, venueCountry, venueCurrency, venueDisplayName, venueRegion, VENUES,
  venueShortName, venueYahooSuffix, yahooSymbol,
} from "../_shared/trading/market.ts";
import {
  canTransition, type Fill, fillGross, isOpenStatus, isTerminalStatus, type Order, ORDER_STATUSES, orderStatusDisplayName,
} from "../_shared/trading/orders.ts";
import {
  evaluate, intentNotional, isApproved, type OrderIntent, policyIssues, quantityText, reportSummary, RISK_CHECK_IDS,
  type RiskContext, riskCheckTitle, standardPolicy,
} from "../_shared/trading/risk.ts";
import * as Rounding from "../_shared/trading/rounding.ts";
import {
  barsToFetch, decodeStrategySpec, isValid, maxPeriod, maxUniverse, operandWarmup, ruleLines, type StrategySpec, validate, warmupBars,
} from "../_shared/trading/strategy.ts";
import { capitalized, compactText, durationText, NumberText, percentText, swiftDouble, trimNumber } from "../_shared/trading/text.ts";
import { Fx, loadVectors, Mismatches } from "./fixtures.ts";

Deno.test("rounding matches the Swift core", async () => {
  const v = await loadVectors("rounding");
  const m = new Mismatches();
  for (const [x, places, out] of v.round) m.check(`round(${x}, ${places})`, Rounding.round(x, places), out);
  for (const [x, out] of v.money) m.check(`money(${x})`, Rounding.money(x), out);
  for (const [increment, out] of v.decimals) m.check(`decimals(${increment})`, Rounding.decimals(increment), out);
  for (const [x, increment, out] of v.floor) m.check(`floor(${x}, ${increment})`, Rounding.floor(x, increment), out);
  for (const [x, increment, out] of v.nearest) m.check(`nearest(${x}, ${increment})`, Rounding.nearest(x, increment), out);
  for (const [x, increment, out] of v.isMultiple) m.check(`isMultiple(${x}, ${increment})`, Rounding.isMultiple(x, increment), out);
  for (const [x, increment, out] of v.string) m.check(`string(${x}, ${increment})`, Rounding.string(x, increment), out);
  m.assertNone(2_000);
});

Deno.test("number text matches the Swift core", async () => {
  const v = await loadVectors("text");
  const m = new Mismatches();
  for (const [x, out] of v.doubleDescription) m.check(`String(${x})`, swiftDouble(x), out);
  for (const [x, out] of v.price) m.check(`price(${x})`, NumberText.price(x), out);
  for (const [x, out] of v.number) m.check(`number(${x})`, NumberText.number(x), out);
  for (const [x, out] of v.signedPercent) m.check(`signedPercent(${x})`, NumberText.signedPercent(x), out);
  for (const [x, currency, out] of v.money) m.check(`money(${x}, ${currency})`, NumberText.money(x, currency), out);
  for (const [x, out] of v.trim) m.check(`trim(${x})`, trimNumber(x), out);
  for (const [x, out] of v.percentText) m.check(`percentText(${x})`, percentText(x), out);
  for (const [x, out] of v.compactText) m.check(`compactText(${x})`, compactText(x), out);
  for (const [x, out] of v.durationText) m.check(`durationText(${x})`, durationText(x), out);
  for (const [x, rules, out] of v.quantityText) m.check(`quantityText(${x}, ${rules.quantityIncrement})`, quantityText(x, rules), out);
  for (const [word, out] of v.capitalized) m.check(`capitalized(${word})`, capitalized(word), out);
  for (const [x, currency, out] of v.compactMoney) m.check(`compactMoney(${x}, ${currency})`, NumberText.compactMoney(x, currency), out);
  m.check("supported currencies", Currencies.supported, v.supportedCurrencies);
  for (const c of v.currencies) {
    const range = Currencies.budgetRange(c.code);
    m.check(`currency ${c.code}`, {
      code: c.code, supported: Currencies.isSupported(c.code), symbol: Currencies.symbol(c.code), decimals: Currencies.decimals(c.code),
      timeZone: Currencies.timeZone(c.code), roughUnitsPerUSD: Currencies.roughUnitsPerUSD(c.code),
      budgetRange: [range.lowerBound, range.upperBound], defaultBudget: Currencies.defaultBudget(c.code),
      balanceChoices: Currencies.balanceChoices(c.code), liquidityFloor: Currencies.liquidityFloor(c.code),
    }, c);
  }
  m.assertNone(2_000);
});

Deno.test("venues, listings and snapshot liquidity match the Swift core", async () => {
  const v = await loadVectors("market");
  const m = new Mismatches();
  m.check("venue order", VENUES, v.venues.map((c: { venue: string }) => c.venue));
  for (const c of v.venues) {
    const region = venueRegion(c.venue);
    m.check(`venue ${c.venue}`, {
      venue: c.venue, currency: venueCurrency(c.venue), displayName: venueDisplayName(c.venue), shortName: venueShortName(c.venue),
      country: venueCountry(c.venue), region, regionName: regionDisplayName(region), yahooSuffix: venueYahooSuffix(c.venue),
    }, c);
  }
  for (const c of v.yahooSymbols) m.check(`parse ${c.input}`, { input: c.input, ...parseYahooSymbol(c.input) }, c);
  for (const c of v.listings) {
    m.check(`listing ${c.id}`, { id: instrumentID(c.instrument), yahooSymbol: yahooSymbol(c.instrument) }, { id: c.id, yahooSymbol: c.yahooSymbol });
  }
  m.check("listed()", [listed("vod", "lse", "Vodafone"), listed("7203", "tse"), listed("ISF", "lse", "", true)],
    v.listings.slice(0, 3).map((c: { instrument: unknown }) => c.instrument));
  for (const c of v.stats) {
    m.check(`stats: ${c.name}`, Calendar.snapshotStats({ series: c.series, quotes: {}, failures: {}, dollarVolume: c.dollarVolume }, c.now), c.out);
  }
  m.assertNone(40);
});

Deno.test("market calendar matches the Swift core", async () => {
  const v = await loadVectors("calendar");
  const m = new Mismatches();
  for (const c of v.cases) {
    const label = `${c.venue} @ ${new Date(c.t).toISOString()}`;
    const session = Calendar.session(c.venue, c.t);
    m.check(`${label} dayKey`, Calendar.dayKey(c.venue, c.t), c.dayKey);
    m.check(`${label} coversDate`, Calendar.coversDate(c.venue, c.t), c.coversDate);
    m.check(`${label} isTradingDay`, Calendar.isTradingDay(c.venue, c.t), c.isTradingDay);
    m.check(`${label} segments`, Calendar.segments(c.venue, c.t).map((part) => [part.start, part.end]), c.segments);
    m.check(`${label} sessionStart`, session?.start, c.sessionStart);
    m.check(`${label} sessionEnd`, session?.end, c.sessionEnd);
    m.check(`${label} isOpen`, Calendar.isOpen(c.venue, c.t), c.isOpen);
    m.check(`${label} nextOpen`, Calendar.nextOpen(c.venue, c.t), c.nextOpen);
    m.check(`${label} nextClose`, Calendar.nextClose(c.venue, c.t), c.nextClose);
  }
  for (const [venue, timeframe, barTime, now, out] of v.barComplete) {
    const bar: Bar = { time: barTime, open: 1, high: 1, low: 1, close: 1, volume: 1 };
    m.check(`isBarComplete ${venue} ${timeframe} ${new Date(barTime).toISOString()} at ${new Date(now).toISOString()}`,
      Calendar.isBarComplete(bar, timeframe, venue, now), out);
  }
  for (const [venue, from, to, out] of v.tradingDays) {
    m.check(`tradingDays ${venue} ${new Date(from).toISOString()} → ${new Date(to).toISOString()}`, Calendar.tradingDays(venue, from, to), out);
  }
  for (const c of v.completedBars) {
    m.check(`completedBars ${c.series.instrument.symbol} at ${new Date(c.now).toISOString()}`,
      Calendar.completedBars(c.series, c.now).map((bar) => bar.close), c.closes);
  }
  for (const [t, currency, out] of v.ledgerDayKey) m.check(`ledger day ${currency} ${new Date(t).toISOString()}`, Ledgers.ledgerDayKey(t, currency), out);

  // A series built from unsorted and invalid bars is tidied the same way.
  const days = [...Fx.usTradingDays(3), Fx.date("2026-11-10T05:00:00Z")];
  const flat = (time: number, price: number, patch: Partial<Bar> = {}): Bar => ({ time, open: price, high: price, low: price, close: price, volume: 1, ...patch });
  const messy = makeBarSeries(Fx.aapl, "day", [
    flat(days[2], 3), flat(days[0], 1), flat(days[1], 2, { high: 1 }), flat(days[1], 2, { close: 0 }), flat(days[1], 2, { volume: -1 }),
  ], fixtureProvenance("messy"), Fx.now);
  m.check("tidied series", { times: messy.bars.map((bar) => bar.time), closes: messy.bars.map((bar) => bar.close) }, v.tidiedSeries);
  m.check("covered years", [Calendar.coveredYears.lowerBound, Calendar.coveredYears.upperBound], v.coveredYears);
  for (const c of v.venues) {
    const covered = Calendar.coveredYearsFor(c.venue);
    m.check(`venue hours ${c.venue}`, {
      // Foundation names the UTC zone "GMT"; it is the same zone.
      venue: c.venue, timeZone: Calendar.timeZone(c.venue) === "UTC" ? "GMT" : Calendar.timeZone(c.venue), hasLunchBreak: Calendar.hasLunchBreak(c.venue),
      regularHours: Calendar.regularHours(c.venue), coveredYears: covered ? [covered.lowerBound, covered.upperBound] : undefined,
    }, c);
  }
  m.assertNone(15_000);
});

Deno.test("indicators match the Swift core bit for bit", async () => {
  const v = await loadVectors("indicators");
  const m = new Mismatches();
  const prepared = new Map<string, PreparedSeries>();
  for (const [name, bars] of Object.entries(v.series)) prepared.set(name, new PreparedSeries(bars as Bar[]));
  const kinds = new Set<string>();
  for (const c of v.values) {
    const series = prepared.get(c.series)!;
    kinds.add(c.operand.kind);
    const out = series.bars.map((_, index) => series.value(c.operand, index));
    m.check(`${c.series} ${JSON.stringify(c.operand)}`, out, c.values);
    m.check(`warmup ${JSON.stringify(c.operand)}`, operandWarmup(c.operand), c.warmup);
  }
  if (kinds.size !== 17) throw new Error(`expected vectors for all 17 operand kinds, saw ${kinds.size}`);
  for (const c of v.stats) {
    m.check(`stats ${c.count}/${c.lookback}`, measureStats((v.series[c.series] as Bar[]).slice(0, c.count), c.lookback), c.stats);
  }
  for (const c of v.indexContaining) m.check(`index containing ${c.t}`, prepared.get(c.series)!.indexContaining(c.t), c.index);
  m.assertNone(700);
});

Deno.test("strategy decisions match the Swift core", async () => {
  const v = await loadVectors("strategy");
  const m = new Mismatches();
  const prepared = new Map<string, PreparedSeries>();
  for (const [name, bars] of Object.entries(v.series)) prepared.set(name, new PreparedSeries(bars as Bar[]));
  const specs = v.specs as Record<string, StrategySpec>;

  for (const c of v.warmup) {
    const spec = specs[c.spec];
    m.check(`warmupBars ${c.spec}`, warmupBars(spec), c.warmupBars);
    m.check(`barsToFetch ${c.spec}`, barsToFetch(spec), c.barsToFetch);
    m.check(`ruleLines ${c.spec}`, ruleLines(spec), c.ruleLines);
  }
  const actions = new Set<string>(), exits = new Set<string>();
  for (const c of v.decide) {
    const decision = decideAt(specs[c.spec], prepared.get(c.series)!, c.index, c.position, c.lastExitTime);
    actions.add(decision.action);
    if (decision.exitReason) exits.add(decision.exitReason);
    m.check(`decide ${c.name}`, decision, c.out);
  }
  for (const needed of ["buy", "sell", "hold"]) if (!actions.has(needed)) throw new Error(`no ${needed} decision in the vectors`);
  for (const needed of ["rule", "stopLoss", "takeProfit", "trailingStop", "timeLimit"]) {
    if (!exits.has(needed)) throw new Error(`no ${needed} exit in the vectors`);
  }
  for (const c of v.dca) {
    const bars = (v.series[c.series] as Bar[]).slice(0, c.count);
    m.check(`dca ${c.name}`, decideDCA(specs[c.spec], bars, c.lastBuyTime), c.out);
  }
  for (const c of v.rebalance) m.check(`rebalance ${JSON.stringify(c.values)}`, rebalanceTrades(c.config, c.values, c.equity), c.out);
  for (const c of v.research) {
    m.check(`research ${c.series} ${c.timeframe} ${c.count}`, researchFacts((v.series[c.series] as Bar[]).slice(0, c.count), c.timeframe), c.out);
  }
  m.assertNone(500);
});

Deno.test("the strategy validator matches the Swift core", async () => {
  const v = await loadVectors("validator");
  const m = new Mismatches();
  for (const c of v.cases) {
    m.check(`validate ${c.name}`, validate(c.spec), c.issues);
    m.check(`isValid ${c.name}`, isValid(c.spec), c.isValid);
    // Anything Swift can encode must survive the server's strict decoder unchanged.
    m.check(`decode ${c.name}`, decodeStrategySpec(c.spec), c.spec);
  }
  m.check("lenient instruments", (v.lenientInstruments.input as unknown[]).map(decodeInstrument), v.lenientInstruments.out);
  m.check("catalog", catalogInstruments, v.catalog);
  m.check("limits", { maxUniverse, maxPeriod }, v.limits);
  m.assertNone(150);
});

Deno.test("the strict decoder refuses shapes Swift's decoder would refuse", () => {
  const good = JSON.parse(JSON.stringify(Fx.aboveAverageSpec([Fx.aapl])));
  decodeStrategySpec(good);
  const broken: [string, (spec: Record<string, unknown>) => void][] = [
    ["unknown kind", (s) => { s.kind = "wire-money"; }],
    ["missing title", (s) => { delete s.title; }],
    ["text for a number", (s) => { (s.sizing as Record<string, unknown>).value = "10"; }],
    ["fractional bars", (s) => { s.reentryCooldownBars = 1.5; }],
    ["unknown operator", (s) => { (s.entry as Record<string, unknown>).op = "exceeds"; }],
    ["unknown operand", (s) => { ((s.entry as Record<string, unknown>).left as Record<string, unknown>).kind = "vibes"; }],
    ["universe not a list", (s) => { s.universe = "AAPL"; }],
    ["asset without a symbol", (s) => { s.universe = [{ name: "Apple" }]; }],
    ["unknown venue", (s) => { s.universe = [{ symbol: "AAPL", venue: "moon" }]; }],
    ["non-finite number", (s) => { (s.protections as Record<string, unknown>).stopLossPct = Infinity; }],
    ["missing protections", (s) => { delete s.protections; }],
  ];
  for (const [name, change] of broken) {
    const spec = JSON.parse(JSON.stringify(good));
    change(spec);
    let threw = false;
    try { decodeStrategySpec(spec); } catch { threw = true; }
    if (!threw) throw new Error(`"${name}" was accepted`);
  }
});

Deno.test("all 24 risk checks match the Swift core", async () => {
  const v = await loadVectors("risk");
  const m = new Mismatches();
  const failed = new Set<string>();
  for (const c of v.cases) {
    const context: RiskContext = { ...c.context, knownClientOrderIDs: new Set<string>(c.context.knownClientOrderIDs) };
    const intent: OrderIntent = c.intent;
    const report = evaluate(intent, context);
    for (const check of report.checks) if (check.status === "failed") failed.add(check.id);
    m.check(`risk ${c.name}`, report, c.report);
    m.check(`risk summary ${c.name}`, reportSummary(report), c.summary);
    m.check(`risk approved ${c.name}`, isApproved(report), c.isApproved);
    m.check(`risk notional ${c.name}`, intentNotional(intent), c.intent.notional);
    if (report.checks.length !== 24) throw new Error(`${c.name}: ${report.checks.length} checks reported, expected 24`);
  }
  for (const id of RISK_CHECK_IDS) if (!failed.has(id)) throw new Error(`no failing case for ${id}`);
  for (const c of v.standardPolicy) {
    m.check(`standardPolicy ${c.budget} ${c.currency}`, standardPolicy(c.budget, c.maxPositionPct, c.crypto, c.currency), c.out);
  }
  for (const c of v.policyIssues) m.check("policyIssues", policyIssues(c.policy), c.issues);
  for (const c of v.manualPolicy) m.check(`manualPolicy ${c.equity}`, manualPolicy(c.equity), c.out);
  m.check("titles", RISK_CHECK_IDS.map((id) => [id, riskCheckTitle(id)]), v.titles);
  m.assertNone(400);
});

Deno.test("the paper broker matches the Swift core", async () => {
  const v = await loadVectors("broker");
  const m = new Mismatches();
  const configs = v.configs as Record<string, PaperBrokerConfig>;
  for (const c of v.rules) {
    m.check(`rules ${c.instrument.venue}:${c.instrument.symbol}`, PaperBroker.rules(c.instrument), c.rules);
    for (const [amount, out] of c.quantityText) m.check(`quantityText ${amount} ${c.instrument.venue}`, PaperBroker.quantityText(amount, c.instrument), out);
  }
  m.check("paper capabilities", PaperBroker.capabilities, v.capabilities.paper);
  m.check("live venues", LiveVenues.all, v.capabilities.live);
  for (const venue of LiveVenues.all) if (venue.isExecutionEnabled) throw new Error(`${venue.adapterID} must not be able to execute`);
  for (const [instrument, notional, first, config, out] of v.fee) {
    m.check(`fee ${instrument.symbol} ${notional} ${first} ${config}`, PaperBroker.fee(instrument, notional, first, configs[config]), out);
  }
  for (const c of v.executionPrice) {
    const quote: Quote = c.quote;
    const result = PaperBroker.executionPrice(c.side, quote, c.instrument, configs[c.config]);
    m.check(`executionPrice ${c.instrument.symbol} ${c.side} ${JSON.stringify(c.quote)}`,
      { price: result.price, modelled: result.modelled, mid: quoteMid(quote), spreadBps: quoteSpreadBps(quote), hasTwoSidedMarket: hasTwoSidedMarket(quote) },
      { price: c.price, modelled: c.modelled, mid: c.mid, spreadBps: c.spreadBps, hasTwoSidedMarket: c.hasTwoSidedMarket });
  }
  const statuses = new Set<string>();
  for (const c of v.match) {
    const order: Order = c.order;
    const out = PaperBroker.match(order, c.quote, c.marketOpen, c.now, configs[c.config]);
    if (out) statuses.add(out.newStatus);
    m.check(`match ${c.name}`, out, c.out);
  }
  for (const needed of ["filled", "partiallyFilled", "canceled", "accepted"]) if (!statuses.has(needed)) throw new Error(`no ${needed} match in the vectors`);
  for (const [tif, venue, placedAt, out] of v.expiry) m.check(`expiry ${tif} ${venue} ${placedAt}`, PaperBroker.expiry(tif, venue, placedAt), out);
  for (const [from, to, out] of v.transitions) m.check(`transition ${from} → ${to}`, canTransition(from, to), out);
  m.check("statuses", ORDER_STATUSES.map((s) => [s, isOpenStatus(s), isTerminalStatus(s), orderStatusDisplayName(s)]), v.statuses);
  m.check("modes", AGENT_MODES.map((mode) => [mode, agentModeDisplayName(mode), modeIsLive(mode), modePlacesOrders(mode), modeProducesSignals(mode)]), v.modes);
  for (const [minutes, out] of v.schedules) m.check(`schedule ${minutes}`, scheduleDisplayName({ intervalMinutes: minutes }), out);
  m.assertNone(500);
});

Deno.test("the ledger matches the Swift core", async () => {
  const v = await loadVectors("ledger");
  const m = new Mismatches();
  const state = (ledger: Ledgers.Ledger) => ({
    ledger, equity: Ledgers.equity(ledger), positionsValue: Ledgers.positionsValue(ledger), unrealizedPnL: Ledgers.unrealizedPnL(ledger),
    totalReturn: Ledgers.totalReturn(ledger), totalReturnPct: Ledgers.totalReturnPct(ledger), drawdownPct: Ledgers.drawdownPct(ledger),
    dayChangePct: Ledgers.dayChangePct(ledger),
    positions: ledger.positions.map((p) => ({
      id: Ledgers.positionID(p), averageCost: Ledgers.averageCost(p), marketValue: Ledgers.marketValue(p),
      unrealizedPnL: Ledgers.positionUnrealizedPnL(p), unrealizedPct: Ledgers.positionUnrealizedPct(p),
    })),
  });
  for (const sequence of v.sequences) {
    // The starting ledger is rebuilt from its own fields, which also checks the initialiser.
    const start = sequence.start.ledger;
    const ledger = Ledgers.makeLedger({
      id: start.id, name: start.name, kind: start.kind, currency: start.currency, agentID: start.agentID,
      startingCash: start.startingCash, createdAt: start.createdAt,
    });
    m.check(`${sequence.name}: start`, state(ledger), sequence.start);
    sequence.steps.forEach((step: Record<string, unknown>, index: number) => {
      const label = `${sequence.name}: step ${index + 1} (${step.op})`;
      if (step.op === "apply") {
        const fill = step.fill as Fill;
        m.check(`${label} gross`, fillGross(fill), step.gross);
        m.check(`${label} booked`, Ledgers.applyFill(ledger, fill), step.booked);
      } else if (step.op === "mark") {
        Ledgers.mark(ledger, step.quotes as Record<string, Quote>, step.now as number);
      } else {
        Ledgers.rollDayIfNeeded(ledger, step.now as number);
      }
      m.check(label, state(ledger), step.after);
    });
  }
  m.assertNone(60);
});

Deno.test("audit hashes match the Swift core", async () => {
  const v = await loadVectors("audit");
  const m = new Mismatches();
  m.check("genesis", genesisHash, v.genesisHash);
  for (const chain of v.chains) {
    const first = chain.events[0];
    // A chain that was archived continues from its recorded base.
    const log = makeAuditLog(first ? first.previousHash : chain.baseHash, chain.baseSequence);
    chain.events.forEach((expected: Record<string, unknown>, index: number) => {
      const input = expected.input as Record<string, unknown>;
      const event = appendAudit(log, `event-${index}`, {
        time: input.timeMs as number, actor: input.actor as never, kind: input.kind as never, summary: input.summary as string,
        mode: input.mode as never, agentID: input.agentID as string | undefined, ledgerID: input.ledgerID as string | undefined,
        orderID: input.orderID as string | undefined, proposalID: input.proposalID as string | undefined,
        instrumentID: input.instrumentID as string | undefined, details: input.details as Record<string, string>,
      });
      const label = `${chain.name} #${expected.sequence}`;
      m.check(`${label} sequence`, event.sequence, expected.sequence);
      m.check(`${label} previousHash`, event.previousHash, expected.previousHash);
      m.check(`${label} canonical`, canonical(event), expected.canonical);
      m.check(`${label} hash`, event.hash, expected.hash);
      // Lower-case ids (as Postgres prints them) hash the same as Swift's upper-case ones.
      const lower = { ...event, agentID: event.agentID?.toLowerCase(), ledgerID: event.ledgerID?.toLowerCase(), orderID: event.orderID?.toLowerCase(), proposalID: event.proposalID?.toLowerCase() };
      m.check(`${label} canonical with lower-case ids`, canonical(lower), expected.canonical);
    });
    m.check(`${chain.name} lastHash`, lastHash(log), chain.lastHash);
    m.check(`${chain.name} nextSequence`, nextSequence(log), chain.nextSequence);
    m.check(`${chain.name} verifies`, verifyAudit(log).isIntact, chain.intact);
  }
  m.check("kinds", AUDIT_KINDS.map((kind) => [kind, auditKindTitle(kind)]), v.kinds);

  // Tampering is detected at the right place.
  const log = makeAuditLog();
  for (let i = 0; i < 4; i++) appendAudit(log, `e${i}`, { time: Fx.now, actor: "system", kind: "orderFilled", summary: `Fill ${i}`, details: { price: "100" } });
  log.events[1].summary = "Fill 9";
  m.check("edited event", verifyAudit(log), { isIntact: false, brokenAtSequence: 2, eventCount: 4 });
  log.events[1].summary = "Fill 1";
  log.events.splice(1, 1);
  m.check("removed event", verifyAudit(log), { isIntact: false, brokenAtSequence: 3, eventCount: 3 });
  m.assertNone(180);
});
