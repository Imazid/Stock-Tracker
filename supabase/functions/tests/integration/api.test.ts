// The two edge functions against the real local stack: a real signed-in person, the real
// database, the engine running inside the function. Only the prices are canned (the
// functions are served with TRADING_ALLOW_FIXTURE_DATA=1), and the instrument is Bitcoin
// so the market is open whenever the test runs.
//
//   supabase start && supabase db reset
//   supabase functions serve --env-file <file with TRADING_ALLOW_FIXTURE_DATA=1 and TRADING_SCHEDULER_SECRET>
//   set -a; eval "$(supabase status -o env)"; . <that file>; set +a
//   npx -y deno test --allow-net --allow-env --allow-read --allow-write supabase/functions/tests/integration/api.test.ts
//
// With TRADING_AUDIT_EXPORT=<path> the first test writes the audit trail the server
// produced to that file, for the Swift package to verify with its own rule:
//
//   SERVER_AUDIT_CHAIN=<path> swift test --filter ParityVectorTests/testServerAuditChainVerifies

import { assert, assertAlmostEquals, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { type AuditEvent, verifyEvents } from "../../_shared/trading/audit.ts";
import { standardPolicy } from "../../_shared/trading/risk.ts";
import { Fx } from "../fixtures.ts";
import {
  anonKey, api, apiURL, BTC, connect, type Person, removePeople, rest, schedule, schedulerSecret, seedAgent, signIn, signUp, type Sql, totp,
  type Tx,
} from "./stack.ts";

const BTC_ID = "crypto:BTC";

function apiTest(name: string, body: (sql: Sql) => Promise<void>): void {
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

/** Sixty real-looking days of Bitcoin, flat then climbing, and a quote for this moment. */
function prices(last = 123, options: { age?: number; closes?: number[] } = {}) {
  const at = Date.now();
  const closes = options.closes ?? Fx.risingCloses();
  const bars = Fx.dailyBars(closes, Fx.cryptoDays(closes.length, at), 5_000_000);
  const quote = Fx.quote(Fx.btc, last, { time: at - (options.age ?? 0) });
  return {
    series: { [BTC_ID]: { timeframe: "day", bars } },
    quotes: { [BTC_ID]: { last: quote.last, bid: quote.bid, ask: quote.ask, time: quote.time } },
  };
}

const draft = (fields: Record<string, unknown> = {}) => ({
  name: "Momo", mode: "paper", spec: Fx.aboveAverageSpec([Fx.btc]), budget: 5_000, maxPositionPct: 10,
  reviewEachPaperTrade: true, schedule: { intervalMinutes: 60 }, ...fields,
});

async function count(sql: Sql, table: string, userID: string, where = "true"): Promise<number> {
  const [row] = await sql.unsafe(`select count(*)::int as n from public.${table} where user_id = '${userID}' and ${where}`);
  return row.n;
}

async function auditKinds(sql: Sql, userID: string): Promise<string[]> {
  return (await sql`select kind from public.audit_events where user_id = ${userID} order by sequence`).map((row) => row.kind as string);
}

async function chainIntact(sql: Sql, userID: string): Promise<boolean> {
  return (await sql`select is_intact from public.verify_audit_chain(${userID})`)[0].is_intact;
}

async function makeDue(sql: Sql, agentID: string): Promise<void> {
  await sql`update public.trading_agents set next_run_at = now() - interval '1 minute' where id = ${agentID}`;
}

async function newPortfolio(person: Person, startingCash = 10_000): Promise<string> {
  const made = await api(person.token, { action: "createPortfolio", name: "Practice", startingCash });
  assertEquals(made.status, 200, JSON.stringify(made.error));
  return made.data.ledger.id;
}

const order = (ledgerID: string, fields: Record<string, unknown> = {}) => ({
  clientOrderID: `test-${crypto.randomUUID()}`, ledgerID, instrument: BTC, side: "buy", type: "market", notional: 500, ...fields,
});

// MARK: - The whole journey

apiTest("end to end: a paper agent proposes a trade on schedule, the person approves it, and it fills", async (sql) => {
  const [person, stranger] = await Promise.all([signUp("e2e"), signUp("stranger")]);

  // 1. Create the agent through the API. An id in the body is ignored: the token says who is asking.
  const made = await api(person.token, { action: "createAgent", draft: draft(), fixture: prices(), userID: stranger.id, user_id: stranger.id });
  assertEquals(made.status, 200, JSON.stringify(made.error));
  const agentID: string = made.data.agent.id, ledgerID: string = made.data.ledger.id;
  assertEquals([made.data.agent.mode, made.data.agent.status, made.data.ledger.mode, made.data.ledger.cash], ["paper", "active", "paper", 5_000]);
  assertEquals(await count(sql, "trading_agents", person.id), 1);
  assertEquals(await count(sql, "trading_agents", stranger.id), 0);
  assertEquals((await sql`select spec->>'title' as title, version, author from public.agent_strategy_versions where agent_id = ${agentID}`)[0],
    { title: "Above average", version: 1, author: "user" });

  // 2. The scheduler runs it — nobody is signed in, the phone is "closed".
  const ran = await schedule({ fixture: prices() });
  assertEquals(ran.status, 200, JSON.stringify(ran.error));
  assert(ran.data.claimed >= 1 && ran.data.runs.completed >= 1, JSON.stringify(ran.data));
  assertEquals(ran.data.marketData, "fixture");

  const runs = await sql`select status, trigger, strategy_version, steps from public.agent_runs where agent_id = ${agentID}`;
  assertEquals(runs.map((run) => [run.status, run.trigger, run.strategy_version]), [["completed", "schedule", 1]]);
  assertEquals(runs[0].steps.map((step: { kind: string }) => step.kind), ["signal", "sizing", "risk", "proposal"]);
  const [proposal] = await sql`select * from public.trade_proposals where agent_id = ${agentID}`;
  assertEquals([proposal.status, proposal.side, proposal.mode, proposal.instrument_id, proposal.order_id], ["pending", "buy", "paper", BTC_ID, null]);
  assert(proposal.notional <= 500 && proposal.notional > 499, `10% of $5,000, got ${proposal.notional}`);
  assert(proposal.risk.checks.length >= 20 && proposal.risk.checks.every((check: { outcome: string }) => check.outcome !== "fail"), "the risk report is stored with the proposal");
  // A proposal is not an order: nothing has moved.
  assertEquals([await count(sql, "orders", person.id), await count(sql, "order_fills", person.id), await count(sql, "positions", person.id)], [0, 0, 0]);
  assertEquals((await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash, 5_000);
  // The lease is given back and the next run is an hour away.
  const [agentRow] = await sql`select locked_until, locked_by, last_run_at, next_run_at, consecutive_errors from public.trading_agents where id = ${agentID}`;
  assertEquals([agentRow.locked_until, agentRow.locked_by, agentRow.consecutive_errors], [null, null, 0]);
  assertEquals(agentRow.next_run_at.getTime() - agentRow.last_run_at.getTime(), 3_600_000);
  // The person sees it through the data API (row-level security), the stranger doesn't.
  assertEquals(((await rest(person.token, "trade_proposals?select=id,status")).body as unknown[]).length, 1);
  assertEquals((await rest(stranger.token, "trade_proposals?select=id,status")).body, []);

  // 3. Running again changes nothing: not due on schedule, and a manual run finds the proposal already waiting.
  await schedule({ fixture: prices() });
  assertEquals(await count(sql, "agent_runs", person.id), 1);
  const again = await api(person.token, { action: "runAgent", agentID, fixture: prices() });
  assertEquals(again.status, 200, JSON.stringify(again.error));
  assertEquals([await count(sql, "agent_runs", person.id), await count(sql, "trading_signals", person.id), await count(sql, "trade_proposals", person.id)], [2, 1, 1]);

  // 4. A stranger can't approve it; the person can.
  const notTheirs = await api(stranger.token, { action: "approveProposal", proposalID: proposal.id, fixture: prices() });
  assertEquals([notTheirs.status, notTheirs.error?.code], [404, "not_found"]);
  assertEquals(await count(sql, "orders", person.id), 0);

  const approved = await api(person.token, { action: "approveProposal", proposalID: proposal.id, fixture: prices() });
  assertEquals(approved.status, 200, JSON.stringify(approved.error));
  assertEquals([approved.data.accepted, approved.data.order.status, approved.data.order.mode, approved.data.fills.length], [true, "filled", "paper", 1]);

  // 5. The rows: one filled paper order, one fill at the ask, the position, the cash, the proposal tied to its order.
  const orders = await sql`select * from public.orders where user_id = ${person.id}`;
  assertEquals(orders.length, 1);
  const placed = orders[0];
  assertEquals([placed.status, placed.mode, placed.source_kind, placed.agent_id, placed.proposal_id, placed.side, placed.instrument_id],
    ["filled", "paper", "agent", agentID, proposal.id, "buy", BTC_ID]);
  assertEquals(placed.client_order_id, `proposal-${String(proposal.id).toUpperCase()}`);
  assertEquals(placed.filled_quantity, placed.quantity);
  const fills = await sql`select * from public.order_fills where user_id = ${person.id}`;
  assertEquals(fills.length, 1);
  const fill = fills[0];
  assertEquals([fill.order_id, fill.fill_no, fill.mode, fill.quantity, fill.side], [placed.id, 1, "paper", placed.quantity, "buy"]);
  assertEquals(fill.price, Fx.quote(Fx.btc, 123).ask, "a market buy fills at the ask");
  const positions = await sql`select * from public.positions where user_id = ${person.id}`;
  assertEquals(positions.map((p) => [p.ledger_id, p.instrument_id, p.quantity]), [[ledgerID, BTC_ID, fill.quantity]]);
  const [book] = await sql`select cash, fees_paid, realized_pnl from public.trading_accounts where id = ${ledgerID}`;
  assertAlmostEquals(book.cash, 5_000 - fill.quantity * fill.price - fill.fee, 0.005);
  assert(book.cash < 4_510 && book.cash > 4_490, `about $500 spent, cash is ${book.cash}`);
  assertEquals(book.fees_paid, fill.fee);
  const [after] = await sql`select status, order_id, resolved_at from public.trade_proposals where id = ${proposal.id}`;
  assertEquals([after.status, after.order_id, after.resolved_at !== null], ["submitted", placed.id, true]);

  // 6. Approving twice places one order.
  const twice = await api(person.token, { action: "approveProposal", proposalID: proposal.id, fixture: prices() });
  assert(twice.status === 200 || twice.status === 409, `second approval answered ${twice.status}`);
  assertEquals([await count(sql, "orders", person.id), await count(sql, "order_fills", person.id)], [1, 1]);
  assertEquals((await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash, book.cash);

  // 7. The audit trail tells the story in order, and the chain holds three ways: the database's check,
  //    the API's, and the engine's own rule over the rows as stored.
  assertEquals(await auditKinds(sql, person.id), ["agentCreated", "signalGenerated", "proposalCreated", "proposalApproved", "orderSubmitted", "orderFilled"]);
  assertEquals((await sql`select * from public.verify_audit_chain(${person.id})`)[0], { is_intact: true, broken_at_sequence: null, event_count: "6" });
  const status = await api(person.token, { action: "auditStatus" });
  assertEquals(status.data, { isIntact: true, brokenAtSequence: null, eventCount: 6 });
  const rows = await sql`select *, round(extract(epoch from time) * 1000)::float8 as time_ms from public.audit_events where user_id = ${person.id} order by sequence`;
  const events: AuditEvent[] = rows.map((row) => {
    const event: AuditEvent = {
      id: row.id, sequence: Number(row.sequence), time: row.time_ms, actor: row.actor, kind: row.kind, summary: row.summary,
      details: row.details, previousHash: row.previous_hash, hash: row.hash,
    };
    if (row.mode !== null) event.mode = row.mode;
    if (row.agent_id !== null) event.agentID = row.agent_id;
    if (row.ledger_id !== null) event.ledgerID = row.ledger_id;
    if (row.order_id !== null) event.orderID = row.order_id;
    if (row.proposal_id !== null) event.proposalID = row.proposal_id;
    if (row.instrument_id !== null) event.instrumentID = row.instrument_id;
    return event;
  });
  assertEquals(verifyEvents(events), { isIntact: true, eventCount: 6 });
  const last = events[events.length - 1];
  assertEquals([last.orderID, last.proposalID, last.agentID, last.mode], [placed.id, proposal.id, agentID, "paper"]);

  // For the Swift package: the same chain in the shape its AuditLog decodes.
  const exportPath = Deno.env.get("TRADING_AUDIT_EXPORT");
  if (exportPath) {
    await Deno.writeTextFile(exportPath, JSON.stringify({ baseHash: "0".repeat(64), baseSequence: 0, events }, null, 1));
  }
});

// MARK: - Who may call

apiTest("the API needs a signed-in person, and the scheduler its secret", async (sql) => {
  const nobody = await api(undefined, { action: "capabilities" });
  assertEquals(nobody.status, 401);
  const garbage = await api("not-a-token", { action: "capabilities" });
  assertEquals(garbage.status, 401);
  // The public (anon) key is a validly signed token, but it isn't a person.
  const anonymous = await api(anonKey(), { action: "capabilities" });
  assertEquals(anonymous.status, 401);

  const person = await signUp("caller");
  const known = await api(person.token, { action: "capabilities" });
  assertEquals(known.status, 200, JSON.stringify(known.error));
  assertEquals([known.data.liveTradingAvailable, known.data.paper.environment, known.data.killSwitchEngaged], [false, "paper", false]);
  assert(known.data.liveBlockers.manual.length > 0 && known.data.liveBlockers.autonomousLive.length > 0, "the reasons live trading is off are stated");
  assert(known.data.live.length > 0 && known.data.live.every((venue: { isExecutionEnabled: boolean; disabledReason?: string }) => venue.isExecutionEnabled === false && (venue.disabledReason ?? "") !== ""),
    "every real-money venue is described as switched off, with the reason");
  assertEquals((await api(person.token, { action: "transferFunds" })).error?.code, "unknown_action");
  assertEquals((await api(person.token, { action: "constructor" })).error?.code, "unknown_action");
  const get = await fetch(`${apiURL()}/functions/v1/trading-api`, { headers: { authorization: `Bearer ${person.token}` } });
  assertEquals(get.status, 405);
  await get.body?.cancel();
  // A deleted account's token stops working at once (it is checked with the auth server on every call).
  await sql`delete from auth.users where id = ${person.id}`;
  assertEquals((await api(person.token, { action: "capabilities" })).status, 401);

  assertEquals((await schedule({}, null)).status, 401);
  assertEquals((await schedule({}, "")).status, 401);
  assertEquals((await schedule({}, "x".repeat(48))).status, 401);
  // Almost right is still wrong.
  assertEquals((await schedule({}, schedulerSecret().slice(0, -1))).status, 401);
  assertEquals((await schedule({}, `${schedulerSecret()}0`)).status, 401);
  // A signed-in person's token is no use to the scheduler either.
  const other = await signUp("not-cron");
  const asPerson = await fetch(`${apiURL()}/functions/v1/agent-scheduler`, { method: "POST", headers: { authorization: `Bearer ${other.token}`, "content-type": "application/json" }, body: "{}" });
  assertEquals(asPerson.status, 401);
  await asPerson.body?.cancel();
});

// MARK: - Live trading

apiTest("every live request is refused with the reasons and written to the audit trail", async (sql) => {
  const person = await signUp("live");
  const made = await api(person.token, { action: "createAgent", draft: draft(), fixture: prices() });
  const agentID: string = made.data.agent.id, ledgerID: string = made.data.ledger.id;

  for (const mode of ["approvalRequired", "autonomousLive"]) {
    const answer = await api(person.token, { action: "setMode", agentID, mode });
    assertEquals([answer.status, answer.error?.code], [403, "live_not_available"], mode);
    assert(answer.error!.details.reasons.length > 0, "the reasons are given");
    const born = await api(person.token, { action: "createAgent", draft: draft({ name: `Live ${mode}`, mode }), fixture: prices() });
    assertEquals([born.status, born.error?.code], [403, "live_not_available"], mode);
  }
  const liveOrder = await api(person.token, { action: "placeOrder", order: order(ledgerID, { mode: "live" }), fixture: prices() });
  assertEquals([liveOrder.status, liveOrder.error?.code], [403, "live_not_available"]);
  const livePreview = await api(person.token, { action: "previewOrder", order: order(ledgerID, { mode: "live" }), fixture: prices() });
  assertEquals([livePreview.status, livePreview.error?.code], [403, "live_not_available"]);

  // Nothing live exists afterwards: the agent is still a paper agent, no second agent, no order of any kind.
  assertEquals((await sql`select mode from public.trading_agents where user_id = ${person.id}`).map((row) => row.mode), ["paper"]);
  assertEquals([await count(sql, "orders", person.id), await count(sql, "order_fills", person.id), await count(sql, "trade_proposals", person.id)], [0, 0, 0]);
  assertEquals((await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash, 5_000);
  assertEquals(await count(sql, "trading_accounts", person.id, "mode <> 'paper'"), 0);
  // Each refusal that asked for a change is on the record (a preview never is).
  assertEquals(await auditKinds(sql, person.id), ["agentCreated", "liveRequestRefused", "liveRequestRefused", "liveRequestRefused", "liveRequestRefused", "liveRequestRefused"]);
  const refusals = await sql`select mode, details from public.audit_events where user_id = ${person.id} and kind = 'liveRequestRefused' order by sequence`;
  assert(refusals.every((row) => String(row.details.reasons).length > 0));
  assertEquals(refusals[4].mode, "live");
  assert(await chainIntact(sql, person.id));
});

// MARK: - Manual paper orders

apiTest("manual paper orders: priced, checked by the risk engine, filled once", async (sql) => {
  const person = await signUp("manual");
  const ledgerID = await newPortfolio(person);

  const preview = await api(person.token, { action: "previewOrder", order: order(ledgerID), fixture: prices() });
  assertEquals(preview.status, 200, JSON.stringify(preview.error));
  assert(preview.data.preview.risk.checks.length >= 20, "a preview shows every check");
  assertEquals([await count(sql, "orders", person.id), await count(sql, "audit_events", person.id)], [0, 1], "a preview records nothing");

  // A market buy fills at the ask.
  const request = order(ledgerID);
  const bought = await api(person.token, { action: "placeOrder", order: request, fixture: prices() }, { "idempotency-key": "buy-once-0001" });
  assertEquals(bought.status, 200, JSON.stringify(bought.error));
  assertEquals([bought.data.accepted, bought.data.order.status, bought.data.order.mode, bought.data.order.source.kind], [true, "filled", "paper", "manual"]);
  const [cashAfter] = await sql`select cash from public.trading_accounts where id = ${ledgerID}`;
  assert(cashAfter.cash < 9_510 && cashAfter.cash > 9_490, `cash is ${cashAfter.cash}`);

  // The same request again — a retry after a lost answer — returns the first answer and places nothing.
  const replay = await api(person.token, { action: "placeOrder", order: request, fixture: prices() }, { "idempotency-key": "buy-once-0001" });
  assertEquals([replay.status, replay.headers.get("idempotent-replay"), replay.data.order.id], [200, "true", bought.data.order.id]);
  // The same client order id without the header is recognised too.
  const sameID = await api(person.token, { action: "placeOrder", order: request, fixture: prices() });
  assertEquals([sameID.status, sameID.data.alreadyPlaced, sameID.data.orderID], [200, true, bought.data.order.id]);
  // And the key can't be reused for something else.
  const reused = await api(person.token, { action: "engageKillSwitch" }, { "idempotency-key": "buy-once-0001" });
  assertEquals([reused.status, reused.error?.code], [409, "idempotency_key_reused"]);
  assertEquals([await count(sql, "orders", person.id), await count(sql, "order_fills", person.id)], [1, 1]);
  assertEquals((await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash, cashAfter.cash);

  // Ten at once with one client order id: still one order.
  const burst = order(ledgerID, { notional: 200 });
  const answers = await Promise.all(Array.from({ length: 10 }, () => api(person.token, { action: "placeOrder", order: burst, fixture: prices() })));
  assert(answers.every((answer) => answer.status === 200), JSON.stringify(answers.map((answer) => [answer.status, answer.error])));
  assertEquals(answers.filter((answer) => answer.data.alreadyPlaced !== true).length, 1);
  assertEquals([await count(sql, "orders", person.id), await count(sql, "order_fills", person.id)], [2, 2]);

  // The risk engine can't be talked round: too big, more than is held, or with no usable price → refused, recorded, no money moves.
  const before = (await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash;
  const tooBig = await api(person.token, { action: "placeOrder", order: order(ledgerID, { notional: 50_000 }), fixture: prices() });
  assertEquals([tooBig.status, tooBig.data.accepted, tooBig.data.order.status], [200, false, "rejected"]);
  const oversell = await api(person.token, { action: "placeOrder", order: order(ledgerID, { side: "sell", quantity: 1_000, notional: undefined }), fixture: prices() });
  assertEquals([oversell.data.accepted, oversell.data.order.status], [false, "rejected"]);
  // No price source at all (no fixture in the request, no market-data key on this server): no trade.
  const unpriced = await api(person.token, { action: "placeOrder", order: order(ledgerID) });
  assertEquals([unpriced.status, unpriced.data.accepted], [200, false]);
  // A price from two hours ago is not a price.
  const stale = await api(person.token, { action: "placeOrder", order: order(ledgerID), fixture: prices(123, { age: 2 * 3_600_000 }) });
  assertEquals([stale.status, stale.data.accepted], [200, false]);
  // Wild numbers are refused before they reach anything.
  for (const bad of [{ notional: -5 }, { notional: "500" }, { quantity: -1 }, { limitPrice: -3 }, { side: "short" }, { type: "iceberg" }, { ledgerID: "nope" }, { clientOrderID: "" }]) {
    const answer = await api(person.token, { action: "placeOrder", order: order(ledgerID, bad), fixture: prices() });
    assert(answer.status === 400 || answer.status === 422, `${JSON.stringify(bad)} answered ${answer.status}`);
  }
  // Someone else's portfolio isn't found.
  const stranger = await signUp("stranger");
  const theirs = await api(stranger.token, { action: "placeOrder", order: order(ledgerID), fixture: prices() });
  assert(theirs.status === 404 || theirs.data?.accepted === false, `a stranger's order answered ${theirs.status}`);
  assertEquals(await count(sql, "orders", stranger.id, "status <> 'rejected'"), 0);

  assertEquals((await sql`select cash from public.trading_accounts where id = ${ledgerID}`)[0].cash, before);
  assertEquals(await count(sql, "order_fills", person.id), 2);
  assertEquals(await count(sql, "orders", person.id, "status = 'rejected'"), 4);
  const reasons = await sql`select status_note from public.orders where user_id = ${person.id} and status = 'rejected'`;
  assert(reasons.every((row) => String(row.status_note).length > 0), "every refusal says why");

  // A limit order below the market waits; it can be cancelled once.
  const resting = await api(person.token, { action: "placeOrder", order: order(ledgerID, { type: "limit", limitPrice: 100, quantity: 1, notional: undefined, timeInForce: "gtc" }), fixture: prices() });
  assertEquals([resting.data.accepted, resting.data.order.status, resting.data.fills.length], [true, "accepted", 0]);
  const cancelled = await api(person.token, { action: "cancelOrder", orderID: resting.data.order.id });
  assertEquals([cancelled.status, cancelled.data.order.status], [200, "canceled"]);
  const cancelledAgain = await api(person.token, { action: "cancelOrder", orderID: resting.data.order.id });
  assertEquals([cancelledAgain.status, cancelledAgain.error?.code], [409, "not_allowed"]);
  assertEquals((await api(stranger.token, { action: "cancelOrder", orderID: bought.data.order.id })).status, 404);

  assert(await chainIntact(sql, person.id));
  assertEquals((await sql`select count(*)::int as n from public.orders where user_id = ${person.id} and mode <> 'paper'`)[0].n, 0);
});

// MARK: - The scheduler's other jobs

apiTest("the scheduler fills waiting paper orders when the price arrives, and never trades without data", async (sql) => {
  const person = await signUp("waiting");
  const ledgerID = await newPortfolio(person);
  const resting = await api(person.token, { action: "placeOrder", order: order(ledgerID, { type: "limit", limitPrice: 110, quantity: 2, notional: undefined, timeInForce: "gtc" }), fixture: prices() });
  assertEquals([resting.data.accepted, resting.data.order.status], [true, "accepted"]);
  const orderID: string = resting.data.order.id;

  // The price hasn't come down: still waiting.
  await schedule({ fixture: prices(123) });
  assertEquals((await sql`select status from public.orders where id = ${orderID}`)[0].status, "accepted");
  // No quote for it in this run (a data outage): still waiting, nothing invented.
  await schedule({ fixture: { series: {}, quotes: {} } });
  assertEquals((await sql`select status, filled_quantity from public.orders where id = ${orderID}`)[0], { status: "accepted", filled_quantity: 0 });
  // The market comes to it: filled at no worse than the limit, by the scheduler, with nobody signed in.
  const ran = await schedule({ fixture: prices(108) });
  assert(ran.data.fills >= 1, JSON.stringify(ran.data));
  const [filled] = await sql`select status, filled_quantity, average_fill_price from public.orders where id = ${orderID}`;
  assertEquals([filled.status, filled.filled_quantity], ["filled", 2]);
  assert(filled.average_fill_price <= 110, `filled at ${filled.average_fill_price}`);
  // Running again doesn't fill it again.
  await schedule({ fixture: prices(108) });
  assertEquals(await count(sql, "order_fills", person.id), 1);
  const [held] = await sql`select quantity, last_price from public.positions where ledger_id = ${ledgerID}`;
  assertEquals(held.quantity, 2);

  // The portfolio is marked to market by a later run.
  await sql`update public.trading_accounts set marked_at = now() - interval '1 hour' where id = ${ledgerID}`;
  await schedule({ fixture: prices(120) });
  assertEquals((await sql`select last_price from public.positions where ledger_id = ${ledgerID}`)[0].last_price, 120);

  // An agent whose data can't be fetched doesn't trade: the run is recorded as failed and counted.
  const made = await api(person.token, { action: "createAgent", draft: draft({ reviewEachPaperTrade: false }), fixture: prices() });
  const agentID: string = made.data.agent.id;
  const outage = await schedule({ fixture: { series: {}, quotes: {} } });
  assertEquals(outage.status, 200);
  const [failed] = await sql`select status, summary from public.agent_runs where agent_id = ${agentID}`;
  assertNotEquals(failed.status, "completed", failed.summary);
  assertEquals([await count(sql, "trade_proposals", person.id), await count(sql, "orders", person.id, `agent_id = '${agentID}'`)], [0, 0]);
  const [afterOutage] = await sql`select consecutive_errors, locked_until, status from public.trading_agents where id = ${agentID}`;
  assertEquals([afterOutage.consecutive_errors, afterOutage.locked_until, afterOutage.status], [1, null, "active"]);
  // Synthetic-looking data handed in as real is impossible here: whatever a fixture says, it is stamped "fixture".
  const provenance = await sql`select distinct provenance->>'kind' as kind from public.trading_signals where user_id = ${person.id}`;
  assert(provenance.every((row) => row.kind === "fixture"));

  // With data back, an automatic paper agent trades once — and two schedulers at the same moment don't make it twice.
  await makeDue(sql, agentID);
  const both = await Promise.all([schedule({ fixture: prices() }), schedule({ fixture: prices() })]);
  assert(both.every((answer) => answer.status === 200));
  assertEquals(await count(sql, "agent_runs", person.id, `agent_id = '${agentID}' and status = 'completed'`), 1);
  assertEquals((await sql`select status from public.orders where agent_id = ${agentID}`).map((row) => row.status), ["filled"]);
  assertEquals((await sql`select consecutive_errors from public.trading_agents where id = ${agentID}`)[0].consecutive_errors, 0);
  // Due again on the same bar: no second trade.
  await makeDue(sql, agentID);
  await schedule({ fixture: prices() });
  assertEquals(await count(sql, "orders", person.id, `agent_id = '${agentID}'`), 1);

  // A stored strategy this code can't read (possible only by writing the row directly, or after a format
  // change) is never guessed at: that agent is paused on the record, and the person's other agent still runs.
  const broken = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    return await seedAgent(tx as unknown as Tx, person.id, {
      name: "Unreadable", next_run_at: new Date(Date.now() - 60_000), risk_policy: tx.json(standardPolicy(5_000, 10, true) as never),
    });
  });
  await makeDue(sql, agentID);
  const runsBefore = await count(sql, "agent_runs", person.id, `agent_id = '${agentID}'`);
  const mixed = await schedule({ fixture: prices() });
  assertEquals([mixed.status, mixed.data.runs.unreadable >= 1], [200, true], JSON.stringify(mixed.data));
  assertEquals((await sql`select status, pause_reason, locked_until from public.trading_agents where id = ${broken}`)[0],
    { status: "paused", pause_reason: "repeatedErrors", locked_until: null });
  assertEquals([await count(sql, "agent_runs", person.id, `agent_id = '${broken}'`), await count(sql, "orders", person.id, `agent_id = '${broken}'`)], [0, 0]);
  assertEquals(await count(sql, "agent_runs", person.id, `agent_id = '${agentID}'`), runsBefore + 1, "the healthy agent ran in the same pass");
  assertEquals(await count(sql, "audit_events", person.id, `kind = 'agentPaused' and agent_id = '${broken}'`), 1);
  const manual = await api(person.token, { action: "runAgent", agentID: broken, fixture: prices() });
  assertEquals([manual.status, manual.error?.code], [409, "not_allowed"]);
  assert(await chainIntact(sql, person.id));
});

// MARK: - Kill switch and the stronger sign-in

apiTest("the kill switch stops agents at once; turning it off, loosening limits and live requests need the stronger sign-in", async (sql) => {
  const person = await signUp("careful");
  const made = await api(person.token, { action: "createAgent", draft: draft({ reviewEachPaperTrade: false }), fixture: prices() });
  const agentID: string = made.data.agent.id;
  const policy = made.data.agent.riskPolicy;

  const engaged = await api(person.token, { action: "engageKillSwitch" });
  assertEquals(engaged.status, 200, JSON.stringify(engaged.error));
  assertEquals((await sql`select kill_switch_engaged from public.risk_policies where user_id = ${person.id}`)[0].kill_switch_engaged, true);
  assertEquals((await sql`select status, pause_reason from public.trading_agents where id = ${agentID}`)[0], { status: "paused", pause_reason: "killSwitch" });
  // Nothing runs it now: not the schedule, not the person.
  await makeDue(sql, agentID);
  await schedule({ fixture: prices() });
  const forced = await api(person.token, { action: "runAgent", agentID, fixture: prices() });
  assert(forced.status === 200 || forced.status === 409, `run answered ${forced.status}`);
  assertEquals(await api(person.token, { action: "resumeAgent", agentID }).then((answer) => answer.status), 409);
  assertEquals([await count(sql, "orders", person.id), await count(sql, "trade_proposals", person.id, "status = 'pending'")], [0, 0]);

  // Add an authenticator app to the account. The session that proved the code is "aal2".
  const headers = { apikey: anonKey(), authorization: `Bearer ${person.token}`, "content-type": "application/json" };
  const enrolled = await (await fetch(`${apiURL()}/auth/v1/factors`, { method: "POST", headers, body: JSON.stringify({ factor_type: "totp", friendly_name: "test" }) })).json();
  assert(enrolled.id && enrolled.totp?.secret, `enrolment failed: ${JSON.stringify(enrolled).slice(0, 200)}`);
  const challenge = await (await fetch(`${apiURL()}/auth/v1/factors/${enrolled.id}/challenge`, { method: "POST", headers, body: "{}" })).json();
  const verified = await (await fetch(`${apiURL()}/auth/v1/factors/${enrolled.id}/verify`, { method: "POST", headers, body: JSON.stringify({ challenge_id: challenge.id, code: await totp(enrolled.totp.secret) }) })).json();
  assert(verified.access_token, `verification failed: ${JSON.stringify(verified).slice(0, 200)}`);
  const strong: string = verified.access_token;
  const weak = await signIn(person);     // password only

  // With only the password: the three sensitive things are refused, and nothing changes.
  const release = await api(weak, { action: "releaseKillSwitch" });
  assertEquals([release.status, release.error?.code], [403, "step_up_required"]);
  assertEquals((await sql`select kill_switch_engaged from public.risk_policies where user_id = ${person.id}`)[0].kill_switch_engaged, true);
  const looser = { ...policy, maxOrderNotional: policy.maxOrderNotional * 4, maxPositionPct: 40 };
  const loosen = await api(weak, { action: "updateRiskPolicy", agentID, policy: looser });
  assertEquals([loosen.status, loosen.error?.code], [403, "step_up_required"]);
  const live = await api(weak, { action: "setMode", agentID, mode: "autonomousLive" });
  assertEquals([live.status, live.error?.code], [403, "step_up_required"]);
  assertEquals((await sql`select risk_policy->>'maxOrderNotional' as n, mode from public.trading_agents where id = ${agentID}`)[0], { n: String(policy.maxOrderNotional), mode: "paper" });
  // Making limits tighter, and stopping things, never needs it.
  const tighter = { ...policy, maxOrderNotional: policy.maxOrderNotional / 2 };
  assertEquals((await api(weak, { action: "updateRiskPolicy", agentID, policy: tighter })).status, 200);
  assertEquals((await api(weak, { action: "pauseAgent", agentID })).status, 200);
  assertEquals((await api(weak, { action: "engageKillSwitch" })).status, 200);

  // With the authenticator code: allowed. Live is still refused — by the engine, with its reasons.
  assertEquals((await api(strong, { action: "updateRiskPolicy", agentID, policy: looser })).status, 200);
  const liveStrong = await api(strong, { action: "setMode", agentID, mode: "autonomousLive" });
  assertEquals([liveStrong.status, liveStrong.error?.code], [403, "live_not_available"]);
  const released = await api(strong, { action: "releaseKillSwitch" });
  assertEquals([released.status, released.data?.killSwitchEngaged], [200, false]);
  assertEquals((await sql`select kill_switch_engaged, kill_switch_at from public.risk_policies where user_id = ${person.id}`)[0], { kill_switch_engaged: false, kill_switch_at: null });
  // Turning the switch off doesn't restart anything: the agent stays paused until the person resumes it.
  assertEquals((await sql`select status from public.trading_agents where id = ${agentID}`)[0].status, "paused");
  assertEquals((await api(strong, { action: "resumeAgent", agentID })).status, 200);

  const kinds = await auditKinds(sql, person.id);
  for (const kind of ["killSwitchEngaged", "killSwitchReleased", "riskPolicyChanged", "liveRequestRefused", "agentResumed"]) assert(kinds.includes(kind), `${kind} is on the record`);
  assert(await chainIntact(sql, person.id));
});

apiTest("agent settings go through validation and are versioned", async (sql) => {
  const person = await signUp("settings");
  const made = await api(person.token, { action: "createAgent", draft: draft(), fixture: prices() });
  const agentID: string = made.data.agent.id;

  // A strategy that can't be read, or isn't sound, is refused with the reasons.
  const unreadable = await api(person.token, { action: "updateStrategy", agentID, spec: { kind: "rules", universe: "everything" } });
  assertEquals(unreadable.status, 422);
  const unsound = await api(person.token, { action: "updateStrategy", agentID, spec: { ...Fx.aboveAverageSpec([Fx.btc]), sizing: { mode: "percentOfEquity", value: 500 } } });
  assertEquals([unsound.status, unsound.error?.code], [422, "invalid"]);
  assert(unsound.error!.details.reasons.length > 0);
  const nameless = await api(person.token, { action: "createAgent", draft: draft({ name: "   " }) });
  assertEquals(nameless.status, 422);
  const reckless = await api(person.token, { action: "updateRiskPolicy", agentID, policy: { ...made.data.agent.riskPolicy, maxDailyLossPct: -1 } });
  assertEquals(reckless.status, 422);
  assertEquals(await count(sql, "agent_strategy_versions", person.id), 1);

  // A sound change becomes version 2; version 1 is kept as it was.
  const changed = await api(person.token, { action: "updateStrategy", agentID, spec: { ...Fx.aboveAverageSpec([Fx.btc]), title: "Above average, tighter stop", protections: { stopLossPct: 5 } }, note: "Tighter stop" });
  assertEquals(changed.status, 200, JSON.stringify(changed.error));
  assertEquals((await sql`select version, spec->>'title' as title from public.agent_strategy_versions where agent_id = ${agentID} order by version`).map((row) => [row.version, row.title]),
    [[1, "Above average"], [2, "Above average, tighter stop"]]);
  assertEquals((await sql`select strategy_version from public.trading_agents where id = ${agentID}`)[0].strategy_version, 2);

  assertEquals((await api(person.token, { action: "renameAgent", agentID, name: "Momo II" })).status, 200);
  assertEquals((await api(person.token, { action: "setSchedule", agentID, intervalMinutes: 1 })).status, 422);
  assertEquals((await api(person.token, { action: "setSchedule", agentID, intervalMinutes: 15 })).status, 200);
  assertEquals((await api(person.token, { action: "pauseAgent", agentID })).status, 200);
  assertEquals((await api(person.token, { action: "resumeAgent", agentID })).status, 200);
  assertEquals((await api(person.token, { action: "deleteAgent", agentID })).status, 200);
  assertEquals((await sql`select deleted_at is not null as gone from public.trading_agents where id = ${agentID}`)[0].gone, true);
  assertEquals((await api(person.token, { action: "pauseAgent", agentID })).status, 404);
  // Its history stays.
  assertEquals(await count(sql, "agent_strategy_versions", person.id), 2);
  const kinds = await auditKinds(sql, person.id);
  assertEquals(kinds.filter((kind) => kind === "strategyChanged").length, 1);
  assert(kinds.includes("agentDeleted") && kinds.includes("agentRenamed"));
  assert(await chainIntact(sql, person.id));
  // The agent's portfolio went with it.
  assertEquals((await api(person.token, { action: "resetPortfolio", ledgerID: made.data.ledger.id })).status, 404);

  // A practice portfolio of the person's own: made, traded in, reset to its starting cash, deleted.
  const ledgerID = await newPortfolio(person, 25_000);
  const bought = await api(person.token, { action: "placeOrder", order: order(ledgerID), fixture: prices() });
  assertEquals(bought.data.accepted, true, JSON.stringify(bought.data.summary));
  assertEquals((await api(person.token, { action: "resetPortfolio", ledgerID })).status, 200);
  assertEquals((await sql`select cash, starting_cash from public.trading_accounts where id = ${ledgerID}`)[0], { cash: 25_000, starting_cash: 25_000 });
  assertEquals(await count(sql, "positions", person.id), 0);
  assertEquals((await api(person.token, { action: "deletePortfolio", ledgerID })).status, 200);
  assertEquals((await api(person.token, { action: "resetPortfolio", ledgerID })).status, 404);
  for (const bad of [{ startingCash: -1 }, { startingCash: 1e15 }, { currency: "XYZ" }, { name: "" }]) {
    const answer = await api(person.token, { action: "createPortfolio", name: "Practice", startingCash: 10_000, ...bad });
    assertEquals(answer.status, 422, JSON.stringify(bad));
  }
  // What was traded before the reset is still on the record.
  assertEquals(await count(sql, "order_fills", person.id), 1);
  assert(await chainIntact(sql, person.id));
});
