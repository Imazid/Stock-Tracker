// The server as the app's backend: the `state` read, `includeState` on changes, and
// agents on exchanges outside the US priced through the ui-test fixture. Runs against the
// local stack with the functions served with TRADING_ALLOW_FIXTURE_DATA=1 (see api.test.ts).
//
// The contract scenario's `state` answer is written to TradingCore/Tests/Vectors/server-state.json
// when WRITE_SERVER_STATE=1, for the Swift test ServerStateContractTests to decode with
// TradingCodec.decoder():
//
//   WRITE_SERVER_STATE=1 npx -y deno test --allow-net --allow-env --allow-read \
//     --allow-write=TradingCore/Tests/Vectors/server-state.json supabase/functions/tests/integration/state.test.ts
//   cd TradingCore && swift test --filter ServerStateContractTests

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type AuditEvent, verifyEvents } from "../../_shared/trading/audit.ts";
import { Fx } from "../fixtures.ts";
import { AAPL, api, BTC, connect, removePeople, schedule, seedAgent, signUp, type Sql, type Tx } from "./stack.ts";

const ETH = { symbol: "ETH", name: "Ethereum", assetClass: "crypto", venue: "crypto", currency: "USD" };
const BHP = { symbol: "BHP", name: "BHP Group", assetClass: "equity", venue: "asx", currency: "AUD" };
const VOD = { symbol: "VOD", name: "Vodafone", assetClass: "equity", venue: "lse", currency: "GBP" };

function stateTest(name: string, body: (sql: Sql) => Promise<void>): void {
  Deno.test({
    name, sanitizeResources: false, sanitizeOps: false,
    fn: async () => {
      const sql = connect();
      try {
        await body(sql);
      } finally {
        await removePeople(sql);
        await sql.end({ timeout: 5 });
      }
    },
  });
}

/** Sixty days of a flat-then-rising coin, and a quote for now (the trend rule fires on the last bar). */
function prices(coins: { instrument: typeof BTC; id: string; last: number }[] = [{ instrument: BTC, id: "crypto:BTC", last: 123 }]) {
  const at = Date.now();
  const closes = Fx.risingCloses();
  const series: Record<string, unknown> = {}, quotes: Record<string, unknown> = {};
  for (const coin of coins) {
    series[coin.id] = { timeframe: "day", bars: Fx.dailyBars(closes, Fx.cryptoDays(closes.length, at), 5_000_000) };
    const quote = Fx.quote(Fx.btc, coin.last, { time: at });
    quotes[coin.id] = { last: quote.last, bid: quote.bid, ask: quote.ask, time: quote.time };
  }
  return { series, quotes };
}
const twoCoins = () => prices([{ instrument: BTC, id: "crypto:BTC", last: 123 }, { instrument: ETH, id: "crypto:ETH", last: 123 }]);

const trendDraft = (universe: unknown[], fields: Record<string, unknown> = {}) => ({
  name: "Trend", mode: "paper", spec: { ...Fx.aboveAverageSpec([Fx.btc]), universe }, budget: 5_000, maxPositionPct: 10,
  reviewEachPaperTrade: true, schedule: { intervalMinutes: 60 }, ...fields,
});

// deno-lint-ignore no-explicit-any
type State = Record<string, any>;

/** Every promise a `state` answer makes to Swift's decoder and to AuditLog.verify(). */
function assertWellFormed(state: State): void {
  for (const key of ["schemaVersion", "accountPolicy", "paperConfig", "connections", "ledgers", "agents", "signals", "proposals", "orders", "fills",
    "runs", "audit", "knownClientOrderIDs", "quotes", "stats", "dailyLossNotified"]) {
    assert(key in state, `state.${key} is missing`);
  }
  assertEquals(state.schemaVersion, 1);
  assertEquals(state.accountPolicy.live, { manualOrdersEnabled: false, approvalAgentsEnabled: false, autonomousAgentsEnabled: false });
  assertEquals(state.accountPolicy.allowFixtureData, true, "the functions are served with the fixture flag on");
  assert(Array.isArray(state.knownClientOrderIDs), "a Set<String> is an array");
  assertEquals([...state.knownClientOrderIDs].sort(), state.orders.map((o: State) => o.clientOrderID).sort());
  // Audit: ascending, contiguous, continuing from baseSequence/baseHash, and verifiable.
  const events = state.audit.events as AuditEvent[];
  events.forEach((event, i) => assertEquals(event.sequence, state.audit.baseSequence + i + 1, "audit events ascend by sequence"));
  if (events.length > 0) assertEquals(state.audit.baseHash, events[0].previousHash);
  else assertEquals([state.audit.baseHash, state.audit.baseSequence], ["0".repeat(64), 0]);
  const verification = verifyEvents(events, state.audit.baseHash, state.audit.baseSequence);
  assert(verification.isIntact, `audit window verifies (${JSON.stringify(verification)})`);
  // Histories come back oldest first.
  for (const [list, field] of [["orders", "createdAt"], ["fills", "time"], ["runs", "startedAt"], ["signals", "createdAt"]] as const) {
    const times = (state[list] as State[]).map((item) => item[field] as number);
    assert(times.every((t, i) => i === 0 || t >= times[i - 1]), `${list} are oldest first`);
  }
  // Nothing a person shouldn't see in their own state.
  const text = JSON.stringify(state);
  for (const leak of ["user_id", "locked_by", "seq\"", "deleted_at", "previous_hash"]) assert(!text.includes(leak), `state carries ${leak}`);
}

// MARK: - The contract scenario

stateTest("contract: a realistic account's state, as the app will decode it", async (sql) => {
  const person = await signUp("contract");
  const call = async (body: Record<string, unknown>) => {
    const answer = await api(person.token, body);
    assertEquals(answer.status, 200, `${body.action}: ${JSON.stringify(answer.error)}`);
    return answer.data;
  };

  const ledgerID: string = (await call({ action: "createPortfolio", name: "Practice", startingCash: 10_000 })).ledger.id;
  const bought = await call({ action: "placeOrder", order: { clientOrderID: `buy-${crypto.randomUUID()}`, ledgerID, instrument: BTC, side: "buy", notional: 500 }, fixture: prices() });
  assertEquals(bought.order.status, "filled");
  const resting = await call({ action: "placeOrder", order: { clientOrderID: `limit-${crypto.randomUUID()}`, ledgerID, instrument: BTC, side: "buy", type: "limit", limitPrice: 100, quantity: 1, timeInForce: "gtc" }, fixture: prices() });
  assertEquals((await call({ action: "cancelOrder", orderID: resting.order.id })).order.status, "canceled");
  await call({ action: "engageKillSwitch" });
  await call({ action: "releaseKillSwitch" });
  const agentID: string = (await call({ action: "createAgent", draft: trendDraft([BTC, ETH]), fixture: twoCoins() })).agent.id;
  const run = await call({ action: "runAgent", agentID, fixture: twoCoins() });
  assertEquals(run.run.status, "completed");
  const pending = await sql`select id, instrument_id from public.trade_proposals where agent_id = ${agentID} and status = 'pending' order by instrument_id`;
  assertEquals(pending.map((p) => p.instrument_id), ["crypto:BTC", "crypto:ETH"]);

  // Approving with includeState: the answer carries the state as saved.
  const approved = await call({ action: "approveProposal", proposalID: pending[0].id, fixture: twoCoins(), includeState: true });
  assertEquals([approved.accepted, approved.order.status], [true, "filled"]);
  const inline: State = approved.state;
  assertWellFormed(inline);
  assertEquals(inline.proposals.find((p: State) => p.id === pending[0].id).status, "submitted");

  // The `state` read.
  const read = await api(person.token, { action: "state" });
  assertEquals(read.status, 200, JSON.stringify(read.error));
  const { state, asOf, truncated } = read.data;
  assertWellFormed(state);
  assert(typeof asOf === "number" && Math.abs(asOf - Date.now()) < 60_000);
  assertEquals(truncated, { runs: false, signals: false, proposals: false, orders: false, fills: false, audit: false });
  // The same state either way (the read is just later).
  assertEquals(state, inline);

  assertEquals(state.ledgers.map((l: State) => l.kind).sort(), ["agentPaper", "manualPaper"]);
  assertEquals(state.agents.map((a: State) => [a.status, a.mode, a.versions.length]), [["active", "paper", 1]]);
  assertEquals(state.orders.map((o: State) => o.status).sort(), ["canceled", "filled", "filled"]);
  assertEquals(state.fills.length, 2);
  assertEquals(state.proposals.map((p: State) => p.status).sort(), ["pending", "submitted"]);
  assertEquals([state.signals.length, state.runs.length], [2, 1]);
  assertEquals(state.accountPolicy.killSwitchEngaged, false);
  assert(!("killSwitchAt" in state.accountPolicy));
  const kinds = state.audit.events.map((e: State) => e.kind);
  for (const kind of ["portfolioCreated", "orderFilled", "orderCanceled", "killSwitchEngaged", "killSwitchReleased", "agentCreated", "proposalApproved"]) {
    assert(kinds.includes(kind), `${kind} is in the audit window`);
  }
  assertEquals(state.audit.baseSequence, 0);
  const manual = state.ledgers.find((l: State) => l.kind === "manualPaper");
  assertEquals(manual.positions.map((p: State) => p.instrument.symbol), ["BTC"]);
  assert(manual.equityHistory.length >= 1);

  if (Deno.env.get("WRITE_SERVER_STATE") === "1") {
    await Deno.writeTextFile(new URL("../../../../TradingCore/Tests/Vectors/server-state.json", import.meta.url), JSON.stringify({ ok: true, data: read.data }, null, 1) + "\n");
  }
});

// MARK: - includeState

stateTest("agent activity pages tied runs and follows later approval to the actual fill", async (sql) => {
  const [person, other] = await Promise.all([signUp("activity"), signUp("activity-other")]);
  const call = async (body: Record<string, unknown>) => {
    const answer = await api(person.token, body);
    assertEquals(answer.status, 200, `${body.action}: ${JSON.stringify(answer.error)}`);
    return answer.data;
  };
  const agentID = (await call({ action: "createAgent", draft: trendDraft([BTC]), fixture: prices() })).agent.id;
  const { run } = await call({ action: "runAgent", agentID, fixture: prices() });
  const proposalID = run.proposalIDs[0];
  const { detail: pending } = await call({ action: "agentActivityDetail", runID: run.id });
  assertEquals(pending.proposals[0].status, "pending");
  assertEquals([pending.signals.length, pending.reviews.length, pending.orders.length], [1, 0, 0]);
  const approved = await call({ action: "approveProposal", proposalID, fixture: prices() });
  const { detail: executed } = await call({ action: "agentActivityDetail", runID: run.id });
  assertEquals(executed.run.orderIDs, [], "the original run recorded only the proposal");
  assertEquals(executed.reviews.map((e: AuditEvent) => e.kind), ["proposalApproved"]);
  assertEquals(executed.orders.map((o: State) => [o.id, o.status]), [[approved.order.id, "filled"]]);
  assertEquals(executed.fills.map((f: State) => f.orderID), [approved.order.id]);

  await sql`insert into public.agent_runs (id, user_id, agent_id, strategy_version, trigger, started_at, finished_at, status)
    select gen_random_uuid(), ${person.id}, ${agentID}, 1, 'schedule', now(), now(), 'completed' from generate_series(1,22)`;
  const { page: first } = await call({ action: "agentActivity", agentID });
  assertEquals(first.runs.length, 20);
  assert(first.nextCursor);
  const { page: second } = await call({ action: "agentActivity", agentID, before: first.nextCursor });
  assertEquals(second.runs.length, 3);
  assertEquals(second.runs.at(-1).id, run.id);
  assertEquals(new Set([...first.runs, ...second.runs].map((r: State) => r.id)).size, 23);
  assertEquals(second.nextCursor, undefined);
  assertEquals((await api(other.token, { action: "agentActivity", agentID })).data.page.runs, []);
  assertEquals((await api(other.token, { action: "agentActivityDetail", runID: run.id })).status, 404);
  assertEquals((await api(person.token, { action: "agentActivity", before: "9223372036854775808" })).status, 400);

  const fields = { action: "agentActivitySummary", period: "lastSevenDays", timeZone: "Australia/Sydney" };
  const { summary } = await call(fields);
  assertEquals([summary.runs, summary.proposals, summary.approvals, summary.fills], [23, 1, 1, 1]);
  assertEquals(summary.recent[0].id, run.id, "a trade decision stays discoverable among routine checks");
  assertEquals(summary.through - summary.from, 7 * 86_400_000);
  assertEquals((await api(other.token, fields)).data.summary.runs, 0);
  assertEquals((await api(person.token, { ...fields, timeZone: "Invalid/Zone" })).status, 400);
});

stateTest("includeState: every change can return the saved state; replays get a fresh one; the stored answer never holds it", async (sql) => {
  const person = await signUp("include");
  const created = await api(person.token, { action: "createPortfolio", name: "Practice", startingCash: 10_000, includeState: true });
  assertEquals(created.status, 200);
  assertWellFormed(created.data.state);
  assertEquals(created.data.state.ledgers.map((l: State) => l.id), [created.data.ledger.id]);
  const ledgerID: string = created.data.ledger.id;

  // Without the flag, no state.
  const plain = await api(person.token, { action: "engageKillSwitch" });
  assertEquals("state" in plain.data, false);
  // A read-only action ignores it; a bad value is refused.
  assertEquals("state" in (await api(person.token, { action: "capabilities", includeState: true })).data, false);
  assertEquals((await api(person.token, { action: "releaseKillSwitch", includeState: "yes" })).status, 400);

  // An idempotent order with includeState; then a later change; then the replay.
  const order = { clientOrderID: `idem-${crypto.randomUUID()}`, ledgerID, instrument: BTC, side: "buy", notional: 300 };
  const key = order.clientOrderID;
  const first = await api(person.token, { action: "placeOrder", order, fixture: prices(), includeState: true }, { "idempotency-key": key });
  assertEquals([first.status, first.data.order.status], [200, "filled"]);
  const headAfterOrder = first.data.state.audit.events.at(-1).sequence;
  await api(person.token, { action: "releaseKillSwitch" });
  const replay = await api(person.token, { action: "placeOrder", order, fixture: prices(), includeState: true }, { "idempotency-key": key });
  assertEquals([replay.status, replay.headers.get("idempotent-replay"), replay.data.order.id], [200, "true", first.data.order.id]);
  assert(replay.data.state.audit.events.at(-1).sequence > headAfterOrder, "the replay's state is read now, not the one stored with the first answer");
  assertEquals(replay.data.state.accountPolicy.killSwitchEngaged, false);
  const replayWithout = await api(person.token, { action: "placeOrder", order, fixture: prices() }, { "idempotency-key": key });
  assertEquals("state" in replayWithout.data, false);
  const [stored] = await sql`select response from public.trading_idempotency_keys where user_id = ${person.id} and key = ${key}`;
  assertEquals("state" in stored.response.data, false, "the idempotency record keeps the action's answer only");
  assert(JSON.stringify(stored.response).length < 20_000);

  // A refusal carries no state; the state read after it shows what it recorded.
  const refused = await api(person.token, { action: "placeOrder", order: { ...order, clientOrderID: `live-${crypto.randomUUID()}`, mode: "live" }, includeState: true });
  assertEquals([refused.status, refused.data], [403, undefined]);
  const after = await api(person.token, { action: "state" });
  assertEquals(after.data.state.audit.events.at(-1).kind, "liveRequestRefused");

  // Someone else's state is their own.
  const stranger = await signUp("other");
  const theirs = await api(stranger.token, { action: "state" });
  assertWellFormed(theirs.data.state);
  assertEquals([theirs.data.state.ledgers.length, theirs.data.state.orders.length, theirs.data.state.audit.events.length], [0, 0, 0]);
  assertEquals((await api(undefined, { action: "state" })).status, 401);
});

stateTest("state: long histories come back as the newest window, and the audit window still verifies", async (sql) => {
  const person = await signUp("history");
  const agentID = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    const id = await seedAgent(tx as unknown as Tx, person.id);
    const base = Date.parse("2026-11-01T00:00:00Z");
    for (let i = 0; i < 205; i++) {
      await tx`insert into public.agent_runs ${tx({ id: crypto.randomUUID(), user_id: person.id, agent_id: id, strategy_version: 1, trigger: "schedule",
        started_at: new Date(base + Math.floor(i / 2) * 60_000), finished_at: new Date(base + Math.floor(i / 2) * 60_000), status: "skipped", summary: `Run ${i}` })}`;
    }
    for (let i = 0; i < 504; i++) {
      await tx`insert into public.audit_events ${tx({ user_id: person.id, time: new Date(base + i * 1_000 + 0.5), actor: "system", kind: "signalGenerated", summary: `Event ${i}`, details: tx.json({ n: String(i) }) })}`;
    }
    return id;
  });
  const read = await api(person.token, { action: "state" });
  assertEquals(read.status, 200, JSON.stringify(read.error));
  const { state, truncated } = read.data;
  assertWellFormed(state);
  assertEquals([truncated.runs, truncated.audit, truncated.orders], [true, true, false]);
  // The newest 200 runs, in the order they were written (two share each minute).
  assertEquals(state.runs.length, 200);
  assertEquals([state.runs[0].summary, state.runs[199].summary], ["Run 5", "Run 204"]);
  assertEquals(state.runs[0].agentID, agentID);
  // The newest 500 events (5 … 504), continuing from event 4's hash.
  assertEquals([state.audit.events.length, state.audit.baseSequence, state.audit.events[0].sequence, state.audit.events[499].sequence], [500, 4, 5, 504]);
  const [fourth] = await sql`select hash from public.audit_events where user_id = ${person.id} and sequence = 4`;
  assertEquals(state.audit.baseHash, fourth.hash);
});

// MARK: - Exchanges outside the US, through the app's UI-test prices

stateTest("an ASX agent is accepted, and runs on the ui-test prices (the same numbers as the app's offline fixture)", async (sql) => {
  const person = await signUp("asx");
  // No up-front refusal any more: Yahoo prices the ASX. (No prices are fetched to create an agent.)
  const dca = {
    kind: "dca", title: "BHP monthly", summary: "Buys BHP regularly", universe: [BHP], timeframe: "day", protections: {},
    sizing: { mode: "fixedNotional", value: 400 }, reentryCooldownBars: 0, followsLedgerPositions: false, dca: { amountPerBuy: 400, intervalBars: 20 },
  };
  const made = await api(person.token, { action: "createAgent", draft: trendDraft([BHP], { name: "BHP saver", spec: dca }), fixture: "ui-test", includeState: true });
  assertEquals(made.status, 200, JSON.stringify(made.error));
  const agentID: string = made.data.agent.id;
  assertEquals(made.data.ledger.currency, "AUD");

  const ran = await api(person.token, { action: "runAgent", agentID, fixture: "ui-test", includeState: true });
  assertEquals(ran.status, 200, JSON.stringify(ran.error));
  assertEquals(ran.data.run.status, "completed", JSON.stringify(ran.data.run.steps.map((s: State) => [s.kind, s.outcome, s.title])));
  assert(!ran.data.run.steps.some((s: State) => s.outcome === "failed"), "no data step failed");
  const proposals = ran.data.state.proposals as State[];
  assertEquals(proposals.map((p) => [p.instrument.symbol, p.status, p.mode]), [["BHP", "pending", "paper"]]);
  // Priced from the app's fixture: the 260th close, at the ask (1 bp above).
  const signal = ran.data.state.signals[0];
  assertEquals(signal.provenance, { kind: "fixture", source: "ui-test", delaySeconds: 0 });
  assertEquals((await sql`select provenance->>'source' as source from public.trading_signals where agent_id = ${agentID}`)[0].source, "ui-test");

  // The scheduler takes the same prices; and a London agent is accepted too.
  await sql`update public.trading_agents set next_run_at = now() - interval '1 minute' where id = ${agentID}`;
  const scheduled = await schedule({ fixture: "ui-test" });
  assertEquals(scheduled.status, 200);
  assert(scheduled.data.claimed >= 1);
  const london = await api(person.token, { action: "createAgent", draft: trendDraft([VOD], { name: "London trend" }), fixture: "ui-test" });
  assertEquals(london.status, 200, JSON.stringify(london.error));
  assertEquals(london.data.ledger.currency, "GBP");

  // A manual order on a US share is priced by the same fixture (every market is).
  const ledger = await api(person.token, { action: "createPortfolio", name: "US", startingCash: 10_000 });
  const order = await api(person.token, {
    action: "placeOrder", fixture: "ui-test",
    order: { clientOrderID: `ui-${crypto.randomUUID()}`, ledgerID: ledger.data.ledger.id, instrument: AAPL, side: "buy", quantity: 1 },
  });
  assertEquals(order.status, 200);
  assertEquals(order.data.accepted, true, JSON.stringify(order.data.summary));
  if (order.data.order.status === "filled") {
    // At the ask: the 260th close plus 1 bp, exactly as the app's offline fixture prices it.
    const closes = (await import("../../_shared/market/ui_test_fixture.ts")).uiTestCloses(AAPL as never, 260);
    assertEquals(order.data.fills[0].price, closes[259] * 1.0001);
  }
});
