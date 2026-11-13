// Whole stories run through the engine. Each one mirrors a scenario in
// TradingCore/Tests/TradingCoreTests/ParityVectorTests.swift step for step (which in turn
// follow EngineTests.swift), so the state it ends in can be compared with what the Swift
// engine ended in: same numbers, same wording, same audit trail.

import { agentSpec, type TradingAgent } from "../_shared/trading/agent.ts";
import { verifyAudit } from "../_shared/trading/audit.ts";
import { TradingEngine } from "../_shared/trading/engine.ts";
import {
  emptySnapshot, type Instrument, instrumentID, makeBarSeries, type MarketSnapshot, fixtureProvenance, syntheticProvenance,
} from "../_shared/trading/market.ts";
import { agentSource, makeRequest } from "../_shared/trading/orders.ts";
import { makePolicy, reportSummary, type RiskPolicy, standardPolicy } from "../_shared/trading/risk.ts";
import {
  type AgentDraft, clone, makeDraft, type OrderPreview, type OrderResult, stateToJSON, TradingError,
} from "../_shared/trading/state.ts";
import * as Templates from "../_shared/trading/templates.ts";
import { UniverseCatalog } from "../_shared/trading/catalog.ts";
import type { AgentMode } from "../_shared/trading/agent.ts";
import { position } from "../_shared/trading/ledger.ts";
import { Fx } from "./fixtures.ts";

/**
 * Records what a story did. Generated UUIDs are replaced with labels ("agent-0",
 * "order-1") in the order records first appear, and audit hashes are left out (they
 * cover the UUIDs; the audit vectors pin the hash rule itself).
 */
export class Recorder {
  private labels: [string, string][] = [];
  private seen = new Set<string>();
  private counters: Record<string, number> = {};
  private log: unknown[] = [];

  private mark(id: string, kind: string): void {
    const key = id.toLowerCase();
    if (this.seen.has(key)) return;
    this.seen.add(key);
    const n = this.counters[kind] ?? 0;
    this.counters[kind] = n + 1;
    this.labels.push([key, `${kind}-${n}`]);
  }

  sync(engine: TradingEngine): void {
    const state = engine.state;
    state.ledgers.forEach((x) => this.mark(x.id, "ledger"));
    state.agents.forEach((x) => this.mark(x.id, "agent"));
    state.connections.forEach((x) => this.mark(x.id, "connection"));
    state.signals.forEach((x) => this.mark(x.id, "signal"));
    state.proposals.forEach((x) => this.mark(x.id, "proposal"));
    state.orders.forEach((x) => this.mark(x.id, "order"));
    state.fills.forEach((x) => this.mark(x.id, "fill"));
    for (const run of state.runs) {
      this.mark(run.id, "run");
      run.steps.forEach((step) => this.mark(step.id, "step"));
    }
    state.audit.events.forEach((x) => this.mark(x.id, "audit"));
  }

  /** Values are copied when noted, as Swift's value types are. */
  note(step: string, value: unknown): void {
    this.log.push({ step, value: value === undefined ? null : JSON.parse(JSON.stringify(value)) });
  }

  result(step: string, result: OrderResult): void {
    const value: Record<string, unknown> = { accepted: result.accepted, risk: result.risk, summary: reportSummary(result.risk) };
    if (result.order) value.order = result.order;
    if (result.accepted) value.fills = result.fills;
    this.note(step, value);
  }

  error(step: string, error: unknown): void {
    if (!(error instanceof TradingError)) throw error;
    this.note(step, { kind: error.kind, messages: error.messages, description: error.description });
  }

  /** Runs something that is expected to be refused, and records the refusal. */
  refused(step: string, body: () => void): void {
    try {
      body();
    } catch (error) {
      this.error(step, error);
    }
  }

  preview(step: string, preview: OrderPreview | undefined): void {
    this.note(step, preview ?? null);
  }

  dump(engine: TradingEngine): Record<string, unknown> {
    this.sync(engine);
    const state = stateToJSON(engine.state) as Record<string, unknown>;
    const audit = state.audit as { events: Record<string, unknown>[] };
    audit.events = audit.events.map((event) => {
      const { hash: _hash, previousHash: _previous, ...rest } = event;
      return rest;
    });
    const verification = verifyAudit(engine.state.audit);
    const root = {
      state, notices: engine.drainNotices(), log: this.log,
      auditIntact: verification.isIntact, auditCount: verification.eventCount,
      dueAgents: engine.dueAgents(Fx.now + 30 * 86_400_000).map((agent) => agent.id),
      instrumentsNeedingQuotes: engine.instrumentsNeedingQuotes().map(instrumentID),
    };
    let text = JSON.stringify(root);
    for (const [uuid, label] of this.labels) text = text.replace(new RegExp(uuid, "gi"), label);
    const normalized = JSON.parse(text);
    normalized.state.knownClientOrderIDs = (normalized.state.knownClientOrderIDs as string[]).slice().sort();
    return normalized;
  }
}

// MARK: - Shared helpers (the same as the Swift tests' private helpers)

export function draft(options: { review?: boolean; mode?: AgentMode; universe?: Instrument[]; budget?: number; policy?: RiskPolicy } = {}): AgentDraft {
  return makeDraft({
    name: "Momo", mode: options.mode ?? "paper", spec: Fx.aboveAverageSpec(options.universe ?? [Fx.aapl]),
    budget: options.budget ?? 5_000, maxPositionPct: 10, riskPolicy: options.policy, reviewEachPaperTrade: options.review ?? false,
  });
}

/** A snapshot in which the instrument closed well above its 20-day average. */
export function bullish(instrument: Instrument = Fx.aapl, now: number = Fx.now): MarketSnapshot {
  const closes = Fx.risingCloses();
  const snapshot = emptySnapshot();
  snapshot.series[instrumentID(instrument)] = makeBarSeries(instrument, "day",
    Fx.dailyBars(closes, Fx.usTradingDays(closes.length, now)), fixtureProvenance("test"), now);
  snapshot.quotes[instrumentID(instrument)] = Fx.quote(instrument, closes[closes.length - 1], { time: now });
  return snapshot;
}

function portfolio(e: TradingEngine, r: Recorder, options: { cash?: number; last?: number; dayVolume?: number } = {}) {
  const ledger = e.createPaperPortfolio("Practice", options.cash ?? 10_000, "USD", Fx.now);
  e.ingest([Fx.quote(Fx.aapl, options.last ?? 100, { dayVolume: options.dayVolume })],
    { [instrumentID(Fx.aapl)]: { averageDollarVolume: 1e9, dailyVolatilityPct: 2 } }, Fx.now);
  r.sync(e);
  return ledger;
}

const aapl = instrumentID(Fx.aapl), msft = instrumentID(Fx.msft), btc = instrumentID(Fx.btc), spy = instrumentID(Fx.spy);
const minutes = (n: number) => n * 60_000;
const seconds = (n: number) => n * 1_000;
const hours = (n: number) => n * 3_600_000;
const days = (n: number) => n * 86_400_000;
const flat = (value: number, count: number) => new Array<number>(count).fill(value);

export interface Scenario {
  name: string;
  fixtures: boolean;
  run: (e: TradingEngine, r: Recorder) => void;
}

export function scenarios(): Scenario[] {
  const saturday = Fx.date("2026-11-14T16:00:00Z");
  const mondayOpen = Fx.date("2026-11-16T14:31:00Z");
  const list: Scenario[] = [];
  const scenario = (name: string, run: (e: TradingEngine, r: Recorder) => void, fixtures = true) => list.push({ name, fixtures, run });

  scenario("signal to approval to fill", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    const proposal = e.state.proposals[0];
    r.result("approve", e.approveProposal(proposal.id, Fx.now + seconds(60))); r.sync(e);
    r.refused("approve again", () => e.approveProposal(proposal.id, Fx.now + seconds(90)));
    r.sync(e);
  });
  scenario("automatic paper agent, then a second run", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    const later = Fx.now + hours(1);
    e.runAgent(agent.id, bullish(Fx.aapl, later), "schedule", later); r.sync(e);
  });
  scenario("a waiting proposal is not duplicated", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    const later = Fx.now + seconds(1_800);
    e.runAgent(agent.id, bullish(Fx.aapl, later), "schedule", later); r.sync(e);
  });
  scenario("stop loss exit", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    const tomorrow = Fx.now + days(1);
    const closes = [...Fx.risingCloses(), 105];
    const snapshot = emptySnapshot();
    snapshot.series[aapl] = makeBarSeries(Fx.aapl, "day", Fx.dailyBars(closes, Fx.usTradingDays(closes.length, tomorrow)), fixtureProvenance("test"), tomorrow);
    snapshot.quotes[aapl] = Fx.quote(Fx.aapl, 105, { time: tomorrow });
    e.runAgent(agent.id, snapshot, "schedule", tomorrow); r.sync(e);
  });
  scenario("risk-blocked trade", (e, r) => {
    const policy = standardPolicy(5_000);
    policy.maxDailyNotional = 100;
    const agent = e.createAgent(draft({ policy }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    r.refused("approve blocked", () => e.approveProposal(e.state.proposals[0].id, Fx.now));
    r.sync(e);
  });
  scenario("research and signal modes", (e, r) => {
    const research = e.createAgent(draft({ mode: "researchOnly" }), Fx.now); r.sync(e);
    e.runAgent(research.id, bullish(), "manual", Fx.now); r.sync(e);
    const signals = e.createAgent(draft({ mode: "signals" }), Fx.now); r.sync(e);
    e.runAgent(signals.id, bullish(), "manual", Fx.now); r.sync(e);
  });
  scenario("live modes are refused", (e, r) => {
    r.refused("create live agent", () => e.createAgent(draft({ mode: "approvalRequired" }), Fx.now));
    r.sync(e);
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    r.refused("promote to live", () => e.setMode(agent.id, "autonomousLive", Fx.now));
    r.sync(e);
    r.note("blockers before", { manual: e.liveBlockers(), approval: e.liveBlockers("approvalRequired"), autonomous: e.liveBlockers("autonomousLive") });
    e.state.connections.push({ id: crypto.randomUUID(), adapterID: "snaptrade", name: "CommSec", environment: "live", permissions: ["read"], createdAt: Fx.now });
    r.sync(e);
    r.note("blockers with a read-only connection", { manual: e.liveBlockers(), approval: e.liveBlockers("approvalRequired") });
    const book = e.createPaperPortfolio("Mine", 10_000, "USD", Fx.now); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 100)], {}, Fx.now); r.sync(e);
    const request = makeRequest({ clientOrderID: "live-1", ledgerID: book.id, instrument: Fx.aapl, side: "buy", quantity: 1, mode: "live" });
    r.preview("preview live", e.preview(request, Fx.now));
    r.result("submit live", e.submit(request, Fx.now)); r.sync(e);
    const agentLive = makeRequest({ clientOrderID: "live-2", ledgerID: book.id, instrument: Fx.aapl, side: "buy", quantity: 1, source: agentSource(agent.id), mode: "live" });
    r.result("submit live as an agent", e.submit(agentLive, Fx.now)); r.sync(e);
  });
  scenario("switching away from paper", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    e.setMode(agent.id, "signals", Fx.now); r.sync(e);
    e.setMode(agent.id, "paper", Fx.now + seconds(60)); r.sync(e);
    e.setMode(agent.id, "researchOnly", Fx.now + seconds(120)); r.sync(e);
  });
  scenario("missing data", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    e.runAgent(agent.id, { series: {}, quotes: {}, failures: { [aapl]: "HTTP 500" } }, "schedule", Fx.now); r.sync(e);
  });
  scenario("synthetic data", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    const snapshot = bullish();
    snapshot.series[aapl].provenance = syntheticProvenance;
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
  });
  scenario("fixture data with the production setting", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
  }, false);
  scenario("stale history", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    const stale = bullish(Fx.aapl, Fx.now - days(21));
    stale.quotes[aapl] = Fx.quote(Fx.aapl, 122.5);
    e.runAgent(agent.id, stale, "schedule", Fx.now); r.sync(e);
  });
  scenario("wrong timeframe and no bars", (e, r) => {
    const agent = e.createAgent(draft({ universe: [Fx.aapl, Fx.msft] }), Fx.now); r.sync(e);
    const snapshot = bullish();
    snapshot.series[aapl].timeframe = "hour";
    snapshot.series[msft] = makeBarSeries(Fx.msft, "day", [], fixtureProvenance("test"), Fx.now);
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
  });
  scenario("a signal without a live quote", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    const snapshot = bullish();
    snapshot.quotes = {};
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
  });
  scenario("today's unfinished bar is ignored", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    const barDays = [...Fx.usTradingDays(40), Fx.date("2026-11-10T05:00:00Z")];
    const snapshot = emptySnapshot();
    snapshot.series[aapl] = Fx.series(Fx.aapl, [...flat(100, 40), 150], { days: barDays });
    snapshot.quotes[aapl] = Fx.quote(Fx.aapl, 150);
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
  });
  scenario("repeated data failures pause the agent", (e, r) => {
    const agent = e.createAgent(draft(), Fx.now); r.sync(e);
    for (let i = 0; i < 6; i++) {
      e.runAgent(agent.id, emptySnapshot(), "schedule", Fx.now + hours(i)); r.sync(e);
    }
  });
  scenario("kill switch", (e, r) => {
    const a = e.createAgent(draft(), saturday); r.sync(e);
    const second = draft({ universe: [Fx.msft] });
    second.name = "Second";
    const b = e.createAgent(second, saturday); r.sync(e);
    e.runAgent(a.id, bullish(Fx.aapl, saturday), "manual", saturday); r.sync(e);
    r.note("cancelled", e.engageKillSwitch(saturday)); r.sync(e);
    r.note("cancelled again", e.engageKillSwitch(saturday + seconds(1))); r.sync(e);
    e.runAgent(b.id, bullish(Fx.msft, saturday), "manual", saturday); r.sync(e);
    r.refused("resume while engaged", () => e.resumeAgent(a.id, saturday));
    e.releaseKillSwitch(saturday); r.sync(e);
    e.resumeAgent(a.id, saturday); r.sync(e);
  });
  scenario("kill switch with a waiting proposal and a manual order", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    const ledger = e.createPaperPortfolio("Mine", 10_000, "USD", Fx.now); r.sync(e);
    r.result("resting limit", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", type: "limit", quantity: 1, limitPrice: 90, timeInForce: "gtc" }), Fx.now)); r.sync(e);
    r.note("cancelled", e.engageKillSwitch(Fx.now + seconds(60))); r.sync(e);
    r.result("manual order while engaged", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 1 }), Fx.now + seconds(120))); r.sync(e);
    r.refused("approve after the switch", () => e.approveProposal(e.state.proposals[0].id, Fx.now + seconds(180)));
    r.sync(e);
  });
  scenario("drawdown limit pauses the agent", (e, r) => {
    e.state.accountPolicy.maxSymbolExposurePct = 100;
    const big = draft();
    big.spec.sizing = { mode: "percentOfEquity", value: 90 };
    big.riskPolicy = makePolicy({ maxOrderNotional: 5_000, maxPositionPct: 100, maxDailyNotional: 10_000 });
    const agent = e.createAgent(big, Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 98, { time: Fx.now + seconds(600) })], {}, Fx.now + seconds(600)); r.sync(e);
  });
  scenario("daily loss notice", (e, r) => {
    e.state.accountPolicy.maxSymbolExposurePct = 100;
    const big = draft();
    big.spec.sizing = { mode: "percentOfEquity", value: 50 };
    big.riskPolicy = makePolicy({ maxOrderNotional: 5_000, maxPositionPct: 100, maxDailyNotional: 20_000, maxDrawdownPct: 50, cooldownSeconds: 0 });
    const agent = e.createAgent(big, Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "schedule", Fx.now); r.sync(e);
    const ledgerID = agent.ledgerID!;
    const held = position(e.ledger(ledgerID)!, aapl)!.quantity;
    const later = Fx.now + seconds(600);
    e.ingest([Fx.quote(Fx.aapl, 110, { time: later })], {}, later); r.sync(e);
    r.result("sell at a loss", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID, instrument: Fx.aapl, side: "sell", quantity: held }), later)); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 110, { time: later + seconds(60) })], {}, later + seconds(60)); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 110, { time: later + seconds(120) })], {}, later + seconds(120)); r.sync(e);
    e.runAgent(agent.id, bullish(Fx.aapl, later + seconds(180)), "schedule", later + seconds(180)); r.sync(e);
  });
  scenario("manual market order: preview and fill", (e, r) => {
    const ledger = portfolio(e, r);
    const request = makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", notional: 1_000 });
    r.preview("preview", e.preview(request, Fx.now));
    r.result("submit", e.submit(request, Fx.now)); r.sync(e);
    const sell = makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: "sell", quantity: 4 });
    r.preview("preview sell", e.preview(sell, Fx.now + seconds(30)));
    r.result("sell", e.submit(sell, Fx.now + seconds(30))); r.sync(e);
    const unknown = makeRequest({ clientOrderID: "m-3", ledgerID: "00000000-0000-4000-8000-000000000999", instrument: Fx.aapl, side: "buy", quantity: 1 });
    r.preview("preview unknown portfolio", e.preview(unknown, Fx.now));
    r.result("unknown portfolio", e.submit(unknown, Fx.now)); r.sync(e);
  });
  scenario("refused orders are recorded", (e, r) => {
    const ledger = portfolio(e, r, { cash: 1_000 });
    r.result("too big", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 20 }), Fx.now)); r.sync(e);
    r.result("short", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: "sell", quantity: 1 }), Fx.now)); r.sync(e);
    r.result("no quote", e.submit(makeRequest({ clientOrderID: "m-3", ledgerID: ledger.id, instrument: Fx.msft, side: "buy", notional: 100 }), Fx.now)); r.sync(e);
    r.result("same id after a refusal", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 2 }), Fx.now + seconds(5))); r.sync(e);
  });
  scenario("the same order is never placed twice", (e, r) => {
    const ledger = portfolio(e, r);
    const request = makeRequest({ clientOrderID: "tap-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 2 });
    r.result("first", e.submit(request, Fx.now)); r.sync(e);
    r.result("again", e.submit(request, Fx.now + seconds(1))); r.sync(e);
  });
  scenario("limit order rests then fills", (e, r) => {
    const ledger = portfolio(e, r);
    const result = e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", type: "limit", quantity: 5, limitPrice: 95, timeInForce: "gtc" }), Fx.now);
    r.result("place", result); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 97, { time: Fx.now + seconds(60) })], {}, Fx.now + seconds(60)); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 94.9, { time: Fx.now + seconds(120) })], {}, Fx.now + seconds(120)); r.sync(e);
    r.note("cancel after fill", e.cancelOrder(result.order!.id, Fx.now + seconds(180))); r.sync(e);
  });
  scenario("cancel and expire", (e, r) => {
    const ledger = portfolio(e, r);
    const first = e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", type: "limit", quantity: 1, limitPrice: 90 }), Fx.now);
    r.result("first", first); r.sync(e);
    r.note("cancel", e.cancelOrder(first.order!.id, Fx.now)); r.sync(e);
    r.note("cancel twice", e.cancelOrder(first.order!.id, Fx.now)); r.sync(e);
    r.result("second", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", type: "limit", quantity: 1, limitPrice: 90 }), Fx.now)); r.sync(e);
    e.ingest([], {}, Fx.date("2026-11-10T21:05:00Z")); r.sync(e);
  });
  scenario("a large order fills in parts", (e, r) => {
    const ledger = portfolio(e, r, { cash: 100_000, dayVolume: 10_000 });
    r.result("place", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 250, timeInForce: "gtc" }), Fx.now)); r.sync(e);
    for (let minute = 1; minute <= 2; minute++) {
      const time = Fx.now + minutes(minute);
      e.ingest([Fx.quote(Fx.aapl, 100 + minute, { time, dayVolume: 10_000 })], {}, time); r.sync(e);
    }
  });
  scenario("stops and immediate orders", (e, r) => {
    const ledger = portfolio(e, r, { cash: 100_000, dayVolume: 10_000 });
    const base = { ledgerID: ledger.id, instrument: Fx.aapl };
    r.result("buy", e.submit(makeRequest({ ...base, clientOrderID: "m-1", side: "buy", quantity: 50 }), Fx.now)); r.sync(e);
    r.result("stop", e.submit(makeRequest({ ...base, clientOrderID: "m-2", side: "sell", type: "stop", quantity: 20, stopPrice: 95, timeInForce: "gtc" }), Fx.now)); r.sync(e);
    r.result("stop limit", e.submit(makeRequest({ ...base, clientOrderID: "m-3", side: "buy", type: "stopLimit", quantity: 5, limitPrice: 104, stopPrice: 103, timeInForce: "gtc" }), Fx.now)); r.sync(e);
    r.result("immediate part fill", e.submit(makeRequest({ ...base, clientOrderID: "m-4", side: "buy", quantity: 250, timeInForce: "ioc" }), Fx.now)); r.sync(e);
    r.result("fill or kill too big", e.submit(makeRequest({ ...base, clientOrderID: "m-5", side: "buy", quantity: 250, timeInForce: "fok" }), Fx.now)); r.sync(e);
    const t1 = Fx.now + seconds(60);
    e.ingest([Fx.quote(Fx.aapl, 104.5, { time: t1, dayVolume: 10_000 })], {}, t1); r.sync(e);
    const t2 = Fx.now + seconds(120);
    e.ingest([Fx.quote(Fx.aapl, 103.5, { time: t2, dayVolume: 10_000 })], {}, t2); r.sync(e);
    const t3 = Fx.now + seconds(180);
    e.ingest([Fx.quote(Fx.aapl, 94, { time: t3, dayVolume: 10_000 })], {}, t3); r.sync(e);
  });
  scenario("an order placed while shut fills at the open", (e, r) => {
    const ledger = e.createPaperPortfolio("Practice", 10_000, "USD", saturday); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 100, { time: saturday })], {}, saturday); r.sync(e);
    const request = makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 10 });
    r.preview("preview", e.preview(request, saturday));
    r.result("place", e.submit(request, saturday)); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 101, { time: mondayOpen })], {}, mondayOpen); r.sync(e);
  });
  scenario("an order placed while shut is cancelled on a gap", (e, r) => {
    const ledger = e.createPaperPortfolio("Practice", 10_000, "USD", saturday); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 100, { time: saturday })], {}, saturday); r.sync(e);
    r.result("place", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 10 }), saturday)); r.sync(e);
    e.ingest([Fx.quote(Fx.aapl, 115, { time: mondayOpen })], {}, mondayOpen); r.sync(e);
  });
  scenario("crypto on a Saturday", (e, r) => {
    const ledger = e.createPaperPortfolio("Crypto practice", 5_000, "USD", saturday); r.sync(e);
    e.ingest([Fx.quote(Fx.btc, 64_000, { spreadBps: 4, time: saturday })], {}, saturday); r.sync(e);
    r.result("buy", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.btc, side: "buy", notional: 1_000 }), saturday)); r.sync(e);
    r.result("sell half", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.btc, side: "sell", quantity: 0.007 }), saturday + seconds(60))); r.sync(e);
  });
  scenario("an AUD portfolio and the ASX", (e, r) => {
    const sydneyOpen = Fx.date("2026-11-10T00:30:00Z");
    const ledger = e.createPaperPortfolio("Aussie", 20_000, "AUD", sydneyOpen); r.sync(e);
    e.ingest([Fx.quote(Fx.bhp, 45.12, { spreadBps: null, time: sydneyOpen }), Fx.quote(Fx.aapl, 100, { time: sydneyOpen })], {}, sydneyOpen); r.sync(e);
    r.result("whole shares", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.bhp, side: "buy", notional: 2_000 }), sydneyOpen)); r.sync(e);
    r.result("fraction refused", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.bhp, side: "buy", quantity: 1.5 }), sydneyOpen)); r.sync(e);
    r.result("wrong currency", e.submit(makeRequest({ clientOrderID: "m-3", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 1 }), sydneyOpen)); r.sync(e);
  });
  scenario("strategy changes are versioned", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    const original = clone(agentSpec(agent));
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    const proposal = e.state.proposals[0];
    const spec = clone(original);
    spec.protections.stopLossPct = 5;
    e.updateStrategy(agent.id, spec, "Tighter stop", Fx.now, "copilot"); r.sync(e);
    r.refused("approve the old proposal", () => e.approveProposal(proposal.id, Fx.now));
    e.updateStrategy(agent.id, spec, "No change", Fx.now); r.sync(e);
    delete spec.exit;
    spec.protections = {};
    r.refused("invalid strategy", () => e.updateStrategy(agent.id, spec, "", Fx.now));
    const aud = clone(original);
    aud.universe = [Fx.bhp];
    r.refused("other currency", () => e.updateStrategy(agent.id, aud, "", Fx.now));
    r.refused("research strategy", () => e.updateStrategy(agent.id, Templates.portfolioResearch([Fx.aapl]), "", Fx.now));
    r.sync(e);
  });
  scenario("proposals expire", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    r.refused("approve too late", () => e.approveProposal(e.state.proposals[0].id, Fx.now + days(1) + seconds(60)));
    r.sync(e);
  });
  scenario("rejecting a proposal", (e, r) => {
    const agent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    e.rejectProposal(e.state.proposals[0].id, Fx.now); r.sync(e);
    e.rejectProposal(e.state.proposals[0].id, Fx.now + seconds(5)); r.sync(e);
    r.refused("unknown proposal", () => e.rejectProposal("00000000-0000-4000-8000-000000000998", Fx.now));
  });
  scenario("creation validates everything", (e, r) => {
    const bad = draft();
    bad.name = " ";
    bad.budget = 5;
    bad.spec.universe = [];
    r.refused("bad agent", () => e.createAgent(bad, Fx.now));
    r.refused("tiny portfolio", () => e.createPaperPortfolio("x", 1, "USD", Fx.now));
    r.refused("euro portfolio", () => e.createPaperPortfolio("x", 1_000, "EUR", Fx.now));
    r.refused("long name", () => e.createPaperPortfolio("n".repeat(41), 1_000, "USD", Fx.now));
    const research = draft();
    research.spec = Templates.portfolioResearch([Fx.aapl]);
    r.refused("research strategy in paper mode", () => e.createAgent(research, Fx.now));
    const fast = draft();
    fast.schedule = { intervalMinutes: 1 };
    r.refused("too frequent", () => e.createAgent(fast, Fx.now));
    const guardian = makeDraft({ name: "Guard", mode: "paper", spec: Templates.riskManager(), budget: 10_000, maxPositionPct: 100 });
    r.refused("guardian without a portfolio", () => e.createAgent(guardian, Fx.now));
    guardian.attachToLedgerID = "00000000-0000-4000-8000-000000000997";
    r.refused("guardian with an unknown portfolio", () => e.createAgent(guardian, Fx.now));
    const limits = draft();
    limits.riskPolicy = makePolicy({ maxOrderNotional: 0, maxPositionPct: 10, maxDailyNotional: 100 });
    r.refused("bad limits", () => e.createAgent(limits, Fx.now));
    r.sync(e);
  });
  scenario("reset and delete", (e, r) => {
    const ledger = portfolio(e, r);
    r.result("buy", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 10 }), Fx.now)); r.sync(e);
    r.result("resting", e.submit(makeRequest({ clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", type: "limit", quantity: 1, limitPrice: 80, timeInForce: "gtc" }), Fx.now)); r.sync(e);
    e.resetPaperPortfolio(ledger.id, Fx.now + seconds(60)); r.sync(e);
    const agent = e.createAgent(draft(), Fx.now + seconds(120)); r.sync(e);
    const agentLedger = agent.ledgerID!;
    r.refused("delete an agent's portfolio", () => e.deletePaperPortfolio(agentLedger, Fx.now + seconds(180)));
    e.deleteAgent(agent.id, Fx.now + seconds(240)); r.sync(e);
    e.deletePaperPortfolio(ledger.id, Fx.now + seconds(300)); r.sync(e);
    r.refused("delete twice", () => e.deletePaperPortfolio(ledger.id, Fx.now + seconds(360)));
    r.refused("reset a deleted portfolio", () => e.resetPaperPortfolio(ledger.id, Fx.now + seconds(360)));
  });
  scenario("housekeeping: rename, schedule, review, limits, pause, resume, delete", (e, r) => {
    const agent: TradingAgent = e.createAgent(draft({ review: true }), Fx.now); r.sync(e);
    const policy = clone(agent.riskPolicy);
    e.runAgent(agent.id, bullish(), "manual", Fx.now); r.sync(e);
    e.renameAgent(agent.id, "  Momentum One ", Fx.now + seconds(10)); r.sync(e);
    r.refused("empty name", () => e.renameAgent(agent.id, "", Fx.now));
    e.setSchedule(agent.id, { intervalMinutes: 15 }, Fx.now + seconds(20)); r.sync(e);
    r.refused("too frequent", () => e.setSchedule(agent.id, { intervalMinutes: 2 }, Fx.now));
    e.setReviewEachPaperTrade(agent.id, false, Fx.now + seconds(30)); r.sync(e);
    e.setReviewEachPaperTrade(agent.id, true, Fx.now + seconds(40)); r.sync(e);
    policy.maxOrderNotional = 750;
    policy.maxPositionPct = 12.5;
    policy.maxDailyLossPct = 2;
    e.updateRiskPolicy(agent.id, policy, Fx.now + seconds(50)); r.sync(e);
    e.updateRiskPolicy(agent.id, policy, Fx.now + seconds(55)); r.sync(e);
    policy.maxDrawdownPct = 0;
    r.refused("bad limits", () => e.updateRiskPolicy(agent.id, policy, Fx.now));
    e.pauseAgent(agent.id, Fx.now + seconds(60)); r.sync(e);
    e.pauseAgent(agent.id, Fx.now + seconds(65)); r.sync(e);
    e.runAgent(agent.id, bullish(), "manual", Fx.now + seconds(70)); r.sync(e);
    e.resumeAgent(agent.id, Fx.now + seconds(80)); r.sync(e);
    e.resumeAgent(agent.id, Fx.now + seconds(85)); r.sync(e);
    e.runAgent(agent.id, bullish(Fx.aapl, Fx.now + seconds(90)), "manual", Fx.now + seconds(90)); r.sync(e);
    const id = agent.id;
    e.deleteAgent(id, Fx.now + seconds(100)); r.sync(e);
    r.refused("pause a deleted agent", () => e.pauseAgent(id, Fx.now));
    r.note("run a deleted agent", e.runAgent(id, bullish(), "manual", Fx.now) === undefined);
  });
  scenario("scheduled buys", (e, r) => {
    const dca = makeDraft({ name: "DCA", mode: "paper", spec: Templates.dollarCostAveraging([Fx.spy]), budget: 5_000, maxPositionPct: 60 });
    const agent = e.createAgent(dca, Fx.now); r.sync(e);
    e.runAgent(agent.id, Fx.snapshot([[Fx.spy, flat(400, 60), 400]]), "schedule", Fx.now); r.sync(e);
    const later = Fx.now + hours(1);
    const again = Fx.snapshot([[Fx.spy, flat(400, 60), 400]]);
    again.quotes[spy] = Fx.quote(Fx.spy, 400, { time: later });
    e.runAgent(agent.id, again, "schedule", later); r.sync(e);
  });
  scenario("rebalancing from cash", (e, r) => {
    e.state.accountPolicy.maxSymbolExposurePct = 100;
    const funds = UniverseCatalog.balancedETFs;
    const rebalance = makeDraft({ name: "Mix", mode: "paper", spec: Templates.etfRebalancing(funds), budget: 10_000, maxPositionPct: 70 });
    rebalance.riskPolicy = makePolicy({ maxOrderNotional: 10_000, maxPositionPct: 70, maxDailyNotional: 20_000 });
    const mix = e.createAgent(rebalance, Fx.now); r.sync(e);
    const make = () => Fx.snapshot(funds.map((fund) => [fund, flat(100, 60), 100] as [Instrument, number[], number]));
    e.runAgent(mix.id, make(), "schedule", Fx.now); r.sync(e);
    const later = Fx.now + hours(1);
    const onTarget = make();
    for (const fund of funds) onTarget.quotes[instrumentID(fund)] = Fx.quote(fund, 100, { time: later });
    e.runAgent(mix.id, onTarget, "schedule", later); r.sync(e);
    // One fund runs ahead: it is sold back and the laggards topped up.
    const muchLater = Fx.now + hours(2);
    const drifted = make();
    drifted.quotes[instrumentID(funds[0])] = Fx.quote(funds[0], 130, { time: muchLater });
    drifted.quotes[instrumentID(funds[1])] = Fx.quote(funds[1], 100, { time: muchLater });
    drifted.quotes[instrumentID(funds[2])] = Fx.quote(funds[2], 100, { time: muchLater });
    e.runAgent(mix.id, drifted, "schedule", muchLater); r.sync(e);
    const missing = make();
    delete missing.quotes[instrumentID(funds[2])];
    delete missing.series[instrumentID(funds[1])];
    e.runAgent(mix.id, missing, "schedule", muchLater + hours(1)); r.sync(e);
  });
  scenario("a risk manager guards a manual portfolio", (e, r) => {
    const ledger = portfolio(e, r);
    r.result("buy", e.submit(makeRequest({ clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: "buy", quantity: 10 }), Fx.now)); r.sync(e);
    const guardDraft = makeDraft({ name: "Guard", mode: "paper", spec: Templates.riskManager(), budget: 10_000, maxPositionPct: 100 });
    guardDraft.attachToLedgerID = ledger.id;
    const agent = e.createAgent(guardDraft, Fx.now); r.sync(e);
    const tomorrow = Fx.now + days(1);
    const closes = [...flat(100, 40), 88];
    const snapshot = emptySnapshot();
    snapshot.series[aapl] = Fx.series(Fx.aapl, closes, { days: Fx.usTradingDays(closes.length, tomorrow) });
    snapshot.quotes[aapl] = Fx.quote(Fx.aapl, 88, { time: tomorrow });
    e.runAgent(agent.id, snapshot, "schedule", tomorrow); r.sync(e);
    e.runAgent(agent.id, snapshot, "schedule", tomorrow + hours(1)); r.sync(e);
  });
  scenario("sizing is cut to the limits and the cash", (e, r) => {
    const big = draft({ universe: [Fx.aapl, Fx.msft], budget: 1_000 });
    big.spec.sizing = { mode: "fixedNotional", value: 5_000 };
    big.riskPolicy = makePolicy({ maxOrderNotional: 800, maxPositionPct: 60, maxDailyNotional: 5_000, cooldownSeconds: 0 });
    e.state.accountPolicy.maxSymbolExposurePct = 100;
    const agent = e.createAgent(big, Fx.now); r.sync(e);
    const snapshot = bullish();
    const other = bullish(Fx.msft);
    snapshot.series[msft] = other.series[msft];
    snapshot.quotes[msft] = other.quotes[msft];
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
  });
  scenario("a crypto agent on hourly bars", (e, r) => {
    const spec = Fx.aboveAverageSpec([Fx.btc]);
    spec.timeframe = "hour";
    const cryptoDraft = makeDraft({ name: "Coin", mode: "paper", spec, budget: 5_000, maxPositionPct: 20, reviewEachPaperTrade: true });
    const agent = e.createAgent(cryptoDraft, Fx.now); r.sync(e);
    const closes = Fx.risingCloses({ base: 60_000, step: 400 });
    const barHours: number[] = [];
    for (let back = closes.length; back >= 1; back--) barHours.push(Fx.now - hours(back));
    const snapshot = emptySnapshot();
    snapshot.series[btc] = makeBarSeries(Fx.btc, "hour", Fx.dailyBars(closes, barHours, 250), fixtureProvenance("test"), Fx.now);
    snapshot.quotes[btc] = Fx.quote(Fx.btc, closes[closes.length - 1], { spreadBps: 6, time: Fx.now });
    e.runAgent(agent.id, snapshot, "schedule", Fx.now); r.sync(e);
    // An hourly agent's liquidity figures come from daily bars the host supplies.
    e.ingest([], { [btc]: { averageDollarVolume: 2e9, dailyVolatilityPct: 3.5 } }, Fx.now + seconds(30)); r.sync(e);
    const later = Fx.now + seconds(60);
    snapshot.quotes[btc] = Fx.quote(Fx.btc, closes[closes.length - 1], { spreadBps: 6, time: later });
    e.runAgent(agent.id, snapshot, "schedule", later); r.sync(e);
    const waiting = e.state.proposals.find((p) => p.status === "pending");
    if (waiting) {
      r.result("approve", e.approveProposal(waiting.id, later + seconds(30))); r.sync(e);
    }
  });
  return list;
}

/** Runs one story by name and returns the engine it ended with (for direct assertions). */
export function play(name: string): { engine: TradingEngine; recorder: Recorder } {
  const scenario = scenarios().find((s) => s.name === name);
  if (!scenario) throw new Error(`no scenario called "${name}"`);
  const engine = scenario.fixtures ? Fx.engine() : new TradingEngine();
  const recorder = new Recorder();
  scenario.run(engine, recorder);
  return { engine, recorder };
}
