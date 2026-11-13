// The engine end to end, two ways:
//
//  1. Parity: every story recorded from the Swift engine (TradingCore/Tests/Vectors/engine.json)
//     is replayed here and must end in the same state — ledgers, orders, fills, proposals,
//     run traces, notices and audit events, word for word and number for number.
//  2. Behaviour: the same checks EngineTests.swift makes, asserted directly, so a reader
//     can see what the pipeline promises without opening a vector file.
//
// Run: npx -y deno test --allow-read supabase/functions/tests/engine.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import { verifyAudit } from "../_shared/trading/audit.ts";
import { TradingEngine } from "../_shared/trading/engine.ts";
import * as Ledgers from "../_shared/trading/ledger.ts";
import { instrumentID } from "../_shared/trading/market.ts";
import { fillGross } from "../_shared/trading/orders.ts";
import { reportFailures } from "../_shared/trading/risk.ts";
import * as Rounding from "../_shared/trading/rounding.ts";
import { firstDifference, Fx, loadVectors } from "./fixtures.ts";
import { play, Recorder, scenarios } from "./scenarios.ts";

const aapl = instrumentID(Fx.aapl);
const kinds = (engine: TradingEngine) => engine.state.audit.events.map((event) => event.kind);

Deno.test("every Swift engine story ends in the same state here", async () => {
  const vectors = await loadVectors("engine");
  assertEquals(vectors.fixtureNow, Fx.now);
  const mine = new Map(scenarios().map((scenario) => [scenario.name, scenario]));
  const problems: string[] = [];
  for (const expected of vectors.scenarios) {
    const scenario = mine.get(expected.name);
    if (!scenario) {
      problems.push(`"${expected.name}" has no TypeScript replay`);
      continue;
    }
    assertEquals(scenario.fixtures, expected.allowFixtureData, expected.name);
    const engine = scenario.fixtures ? Fx.engine() : new TradingEngine();
    const recorder = new Recorder();
    scenario.run(engine, recorder);
    const difference = firstDifference(recorder.dump(engine), expected.end);
    if (difference) problems.push(`"${expected.name}" → ${difference}`);
  }
  for (const name of mine.keys()) {
    if (!vectors.scenarios.some((s: { name: string }) => s.name === name)) problems.push(`"${name}" has no Swift vector`);
  }
  if (problems.length > 0) throw new Error(`${problems.length} of ${vectors.scenarios.length} stories differ:\n  ${problems.join("\n  ")}`);
  assert(vectors.scenarios.length >= 40);
});

// MARK: - The vertical slice

Deno.test("signal → proposal → approval → fill → ledger → audit", () => {
  const { engine } = play("signal to approval to fill");
  const state = engine.state;
  const agent = state.agents[0];
  const ledger = engine.ledger(agent.ledgerID)!;

  const run = state.runs[0];
  assertEquals(run.status, "completed");
  assertEquals(run.steps.map((step) => step.kind), ["signal", "sizing", "risk", "proposal"]);
  const signal = state.signals[0];
  assertEquals([signal.action, signal.strategyVersion], ["buy", 1]);
  assert(signal.evidence.length > 0);

  const proposal = state.proposals[0];
  assertEquals([proposal.status, proposal.side, proposal.mode], ["submitted", "buy", "paper"]);
  assert(proposal.notional <= 500 && proposal.notional > 499, "10% of $5,000");

  assertEquals(state.orders.length, 1, "approving twice places one order");
  const order = state.orders[0];
  assertEquals([order.status, order.mode, proposal.orderID], ["filled", "paper", order.id]);
  assertEquals(order.clientOrderID, `proposal-${proposal.id.toUpperCase()}`);
  const fill = state.fills[0];
  assertEquals(fill.price, state.quotes[aapl].ask);

  const held = Ledgers.position(ledger, aapl)!;
  assertEquals(held.quantity, proposal.quantity);
  assertEquals(ledger.cash, Rounding.money(5_000 - fillGross(fill)));

  assertEquals(kinds(engine), ["agentCreated", "signalGenerated", "proposalCreated", "proposalApproved", "orderSubmitted", "orderFilled"]);
  assert(verifyAudit(state.audit).isIntact);
  const last = state.audit.events[state.audit.events.length - 1];
  assertEquals([last.orderID, last.proposalID, last.agentID, last.mode], [order.id, proposal.id, agent.id, "paper"]);
});

Deno.test("a proposal is not an order: nothing moves until it is approved", () => {
  const { engine } = play("a waiting proposal is not duplicated");
  assertEquals(engine.state.orders.length, 0);
  assertEquals(engine.state.fills.length, 0);
  assertEquals(engine.state.proposals.filter((p) => p.status === "pending").length, 1);
  assertEquals(engine.state.signals.length, 1, "the same bar gives one signal");
  assertEquals(engine.ledger(engine.state.agents[0].ledgerID)!.cash, 5_000);
  assert(engine.state.runs[1].steps.some((step) => step.title.includes("waiting for your approval")));
});

Deno.test("an automatic paper agent trades once per signal", () => {
  const { engine } = play("automatic paper agent, then a second run");
  assertEquals(engine.state.orders.map((o) => o.status), ["filled"]);
  assertEquals(engine.state.proposals.map((p) => p.status), ["submitted"]);
  assertEquals(engine.state.runs[1].orderIDs, []);
  assertEquals(engine.state.agents[0].nextRunAt, Fx.now + 2 * 3_600_000);
});

Deno.test("a stop loss sells the position and books the loss", () => {
  const { engine } = play("stop loss exit");
  const [entry, exit] = engine.state.fills;
  const ledger = engine.ledger(engine.state.agents[0].ledgerID)!;
  assertEquals(engine.state.signals[1].exitReason, "stopLoss");
  assertEquals([exit.side, exit.quantity], ["sell", entry.quantity]);
  assertEquals(ledger.positions, []);
  assertEquals(exit.realizedPnL, Rounding.money(fillGross(exit) - fillGross(entry)));
  assertEquals(ledger.cash, Rounding.money(5_000 + exit.realizedPnL!));
  assert(ledger.realizedPnL < 0);
});

// MARK: - Risk

Deno.test("a risk-blocked trade is recorded and never becomes an order", () => {
  const { engine } = play("risk-blocked trade");
  const proposal = engine.state.proposals[0];
  assertEquals(proposal.status, "blocked");
  assertEquals(reportFailures(proposal.risk).map((check) => check.id), ["dailyNotional"]);
  assertEquals(engine.state.orders, []);
  assertEquals(engine.ledger(engine.state.agents[0].ledgerID)!.cash, 5_000);
  assert(kinds(engine).includes("proposalBlocked") && !kinds(engine).includes("orderSubmitted"));
  assertEquals(engine.drainNotices().map((n) => n.kind), ["proposalBlocked"]);
});

Deno.test("the kill switch stops every agent until it is released and each is resumed", () => {
  const { engine } = play("kill switch");
  const [a, b] = engine.state.agents;
  assertEquals(engine.state.orders.map((o) => [o.status, o.statusNote]), [["canceled", "Kill switch."]]);
  assertEquals(engine.state.runs[1].status, "skipped", "nothing runs while the switch is on");
  assertEquals([a.status, b.status, b.pauseReason], ["active", "paused", "killSwitch"], "release restarts nothing by itself");
  assert(kinds(engine).includes("killSwitchEngaged") && kinds(engine).includes("killSwitchReleased"));
  assert(verifyAudit(engine.state.audit).isIntact);

  // While it is on, an agent's order is refused by the risk engine and a waiting proposal is gone.
  const other = play("kill switch with a waiting proposal and a manual order").engine;
  assertEquals(other.state.proposals[0].status, "expired");
  assertEquals(other.state.accountPolicy.killSwitchEngaged, true);
  const manual = other.state.orders.find((o) => o.clientOrderID === "m-2")!;
  assertEquals(manual.status, "filled", "a person can still trade by hand");
  assertEquals(other.state.orders.find((o) => o.clientOrderID === "m-1")!.status, "accepted", "a person's own order is left alone");
});

Deno.test("live trading is refused everywhere, with the reason, and audited", () => {
  const { engine, recorder } = play("live modes are refused");
  const log = recorder.dump(engine).log as { step: string; value: Record<string, unknown> }[];
  const find = (step: string) => log.find((entry) => entry.step === step)!.value;
  assertEquals(find("create live agent").kind, "liveNotAvailable");
  assert((find("create live agent").messages as string[]).includes("No trading account is connected."));
  assertEquals(find("promote to live").kind, "liveNotAvailable");
  assertEquals(engine.state.agents.map((agent) => agent.mode), ["paper"]);
  assertEquals(kinds(engine).filter((kind) => kind === "liveRequestRefused").length, 2);
  // A read-only broker connection changes the reason, not the answer.
  assert(engine.liveBlockers().some((reason) => reason.includes("read-only")));
  assertEquals(find("preview live").canSubmit, false);
  const live = engine.state.orders.filter((o) => o.mode === "live");
  assertEquals(live.map((o) => o.status), ["rejected", "rejected"]);
  assertEquals(engine.state.fills, []);
  assertEquals(engine.state.ledgers.find((l) => l.name === "Mine")!.cash, 10_000);
});

// MARK: - Data honesty

Deno.test("nothing trades on missing, synthetic, fixture or stale data", () => {
  const missing = play("missing data").engine;
  assertEquals(missing.state.runs[0].status, "failed");
  assert(missing.state.runs[0].steps[0].detail.includes("HTTP 500"));
  assertEquals([missing.state.signals.length, missing.state.orders.length], [0, 0]);
  assertEquals(missing.state.agents[0].consecutiveErrors, 1);

  const synthetic = play("synthetic data").engine;
  assertEquals(synthetic.state.runs[0].status, "failed");
  assert(synthetic.state.runs[0].steps[0].detail.includes("isn't real market data"));

  const production = play("fixture data with the production setting").engine;
  assertEquals(production.state.runs[0].status, "failed");
  assertEquals(production.state.quotes, {}, "the fixture quote wasn't even stored");

  const stale = play("stale history").engine;
  assertEquals(stale.state.runs[0].status, "failed");
  assert(stale.state.runs[0].steps[0].detail.includes("out of date"));

  const noQuote = play("a signal without a live quote").engine;
  assertEquals([noQuote.state.signals.length, noQuote.state.proposals.length], [1, 0]);

  const forming = play("today's unfinished bar is ignored").engine;
  assertEquals([forming.state.signals.length, forming.state.orders.length], [0, 0]);
});

Deno.test("five failed runs in a row pause the agent", () => {
  const { engine } = play("repeated data failures pause the agent");
  const agent = engine.state.agents[0];
  assertEquals([agent.status, agent.pauseReason, agent.consecutiveErrors], ["paused", "repeatedErrors", 5]);
  assertEquals(engine.state.runs.map((run) => run.status), ["failed", "failed", "failed", "failed", "failed", "skipped"]);
  assertEquals(engine.drainNotices().map((n) => n.kind), ["dataUnavailable", "agentPaused"]);
});

Deno.test("a drawdown past the limit pauses the agent", () => {
  const { engine } = play("drawdown limit pauses the agent");
  const agent = engine.state.agents[0];
  assertEquals([agent.status, agent.pauseReason], ["paused", "drawdownLimit"]);
  assert(engine.drainNotices().some((n) => n.kind === "agentPaused" && n.body.includes("still holds 1 position")));
});

// MARK: - Orders

Deno.test("an order placed while the market is shut fills at the open", () => {
  const { engine } = play("an order placed while shut fills at the open");
  assertEquals(engine.state.orders[0].status, "filled");
  assertEquals(engine.state.fills[0].price, engine.state.quotes[aapl].ask);
  assertEquals(engine.state.fills[0].time, Fx.date("2026-11-16T14:31:00Z"));
});

Deno.test("…and is cancelled, not filled, when the price has gapped", () => {
  const { engine } = play("an order placed while shut is cancelled on a gap");
  const order = engine.state.orders[0];
  assertEquals(order.status, "canceled");
  assert(order.statusNote!.includes("price moved"));
  assertEquals(engine.state.fills, []);
  assertEquals(engine.state.ledgers[0].cash, 10_000);
});

Deno.test("the same client order id is never placed twice", () => {
  const { engine, recorder } = play("the same order is never placed twice");
  const log = recorder.dump(engine).log as { step: string; value: Record<string, unknown> }[];
  const again = log.find((entry) => entry.step === "again")!.value;
  assertEquals(again.accepted, false);
  assertEquals(again.order, undefined, "no second record");
  assertEquals(engine.state.orders.length, 1);
  assertEquals(Ledgers.position(engine.state.ledgers[0], aapl)!.quantity, 2);
});

Deno.test("a large order fills in parts and is tracked across them", () => {
  const { engine } = play("a large order fills in parts");
  const order = engine.state.orders[0];
  assertEquals([order.status, order.filledQuantity], ["filled", 250]);
  assertEquals(engine.state.fills.map((fill) => fill.quantity), [100, 100, 50]);
  const expected = engine.state.fills.reduce((sum, fill) => sum + fill.price * fill.quantity, 0) / 250;
  assert(Math.abs(order.averageFillPrice - expected) < 1e-9);
  assertEquals(kinds(engine).filter((kind) => kind === "orderPartiallyFilled").length, 2);
  assertEquals(kinds(engine).filter((kind) => kind === "orderFilled").length, 1);
});

Deno.test("refused orders are recorded as rejected and move no money", () => {
  const { engine } = play("refused orders are recorded");
  const [tooBig, short, noQuote, reused] = engine.state.orders;
  assertEquals([tooBig.status, short.status, noQuote.status], ["rejected", "rejected", "rejected"]);
  assert(tooBig.statusNote!.includes("only $1000.00 is available"));
  assertEquals(kinds(engine).filter((kind) => kind === "orderRejected").length, 3);
  // As in the Swift core, a refused order's id is not remembered, so the same id can be
  // sent again and accepted — leaving two records with one client order id. The engine is
  // kept identical to Swift here; the server closes the gap by treating every recorded
  // order's id as used (see persistence), which the database's unique key also demands.
  assertEquals([reused.clientOrderID, reused.status], [tooBig.clientOrderID, "filled"]);
  assertEquals(engine.state.fills.length, 1);
  assertEquals(engine.state.ledgers[0].cash, Rounding.money(1_000 - fillGross(engine.state.fills[0])));
});

Deno.test("no position can go negative and cash can't either", () => {
  for (const scenario of scenarios()) {
    const { engine } = play(scenario.name);
    for (const ledger of engine.state.ledgers) {
      assert(ledger.cash >= 0, `${scenario.name}: cash ${ledger.cash}`);
      for (const held of ledger.positions) assert(held.quantity > 0, `${scenario.name}: ${held.instrument.symbol} ${held.quantity}`);
    }
    for (const order of engine.state.orders) assert(order.filledQuantity <= order.quantity + 1e-9, scenario.name);
    assert(verifyAudit(engine.state.audit).isIntact, `${scenario.name}: audit chain`);
  }
});

Deno.test("strategy changes are versioned and void old proposals", () => {
  const { engine } = play("strategy changes are versioned");
  const agent = engine.state.agents[0];
  assertEquals(agent.versions.map((v) => v.version), [1, 2]);
  assertEquals([agent.versions[0].spec.protections.stopLossPct, agent.versions[1].spec.protections.stopLossPct], [8, 5]);
  assertEquals(agent.versions[1].author, "copilot");
  assertEquals(engine.state.proposals[0].status, "expired");
});
