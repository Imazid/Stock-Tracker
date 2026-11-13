// What the database enforces by itself — whatever the code above it does.
// Runs against the local stack (supabase start, supabase db reset):
//
//   set -a; eval "$(supabase status -o env)"; set +a
//   npx -y deno test --allow-net --allow-env --allow-read supabase/functions/tests/integration/database.test.ts

import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { canTransition, ORDER_STATUSES, type OrderStatus } from "../../_shared/trading/orders.ts";
import { type AuditEvent, verifyEvents } from "../../_shared/trading/audit.ts";
import { postgresVolumeStore, pruneIdempotencyKeys } from "../../_shared/server/upkeep.ts";
import { loadVectors } from "../fixtures.ts";
import {
  AAPL, connect, refused, removePeople, rest, scratch, seedAccount, seedAgent, seedAudit, seedOrder, signUp, type Sql, type Tx,
} from "./stack.ts";

function dbTest(name: string, body: (sql: Sql) => Promise<void>): void {
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

const TABLES = ["risk_policies", "broker_connections", "trading_accounts", "positions", "trading_portfolio_snapshots", "trading_agents",
  "agent_strategy_versions", "agent_runs", "trading_signals", "trade_proposals", "orders", "order_fills", "agent_events", "audit_events"];

/** One row in every table for a person, written the way the functions write (as the service role). */
async function seedEverything(sql: Sql, userID: string): Promise<{ ledger: string; agent: string; order: string }> {
  return await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    await tx`insert into public.risk_policies (user_id) values (${userID}) on conflict do nothing`;
    await tx`insert into public.broker_connections ${tx({ user_id: userID, adapter_id: "snaptrade", name: "CommSec", environment: "live", permissions: ["read"] })}`;
    const ledger = await seedAccount(tx as unknown as Tx, userID, { cash: 9_000 });
    await tx`insert into public.positions ${tx({ user_id: userID, ledger_id: ledger, instrument_id: "us:AAPL", instrument: tx.json(AAPL), quantity: 10, cost_basis: 1_000, opened_at: new Date(), last_price: 100 })}`;
    await tx`insert into public.trading_portfolio_snapshots ${tx({ user_id: userID, ledger_id: ledger, time: new Date(), equity: 10_000, cash: 9_000 })}`;
    const agent = await seedAgent(tx as unknown as Tx, userID);
    await tx`insert into public.agent_runs ${tx({ id: crypto.randomUUID(), user_id: userID, agent_id: agent, strategy_version: 1, trigger: "manual", started_at: new Date(), finished_at: new Date(), status: "completed" })}`;
    const signal = crypto.randomUUID();
    await tx`insert into public.trading_signals ${tx({ id: signal, user_id: userID, agent_id: agent, strategy_version: 1, instrument_id: "us:AAPL", instrument: tx.json(AAPL), action: "buy", headline: "Buy", bar_time: new Date("2026-11-09T05:00:00Z"), close: 100, created_at: new Date(), provenance: tx.json({ kind: "fixture", source: "test", delaySeconds: 0 }) })}`;
    await tx`insert into public.trade_proposals ${tx({ id: crypto.randomUUID(), user_id: userID, agent_id: agent, signal_id: signal, strategy_version: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: tx.json(AAPL), side: "buy", quantity: 1, reference_price: 100, notional: 100, status: "pending", risk: tx.json({ checks: [] }), headline: "Buy", signal_bar_time: new Date("2026-11-09T05:00:00Z"), created_at: new Date(), expires_at: new Date(Date.now() + 86_400_000), client_order_id: `proposal-${crypto.randomUUID()}` })}`;
    const order = await seedOrder(tx as unknown as Tx, userID, ledger);
    await tx`insert into public.order_fills ${tx({ id: crypto.randomUUID(), user_id: userID, order_id: order, fill_no: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: tx.json(AAPL), side: "buy", quantity: 10, price: 100, time: new Date(), source_kind: "manual", mode: "paper" })}`;
    await tx`update public.orders set status = 'filled', filled_quantity = 10, average_fill_price = 100 where id = ${order}`;
    await tx`insert into public.agent_events ${tx({ user_id: userID, kind: "orderFilled", title: "Filled", body: "Bought 10 AAPL.", created_at: new Date() })}`;
    await seedAudit(tx as unknown as Tx, userID);
    return { ledger, agent, order };
  });
}

// MARK: - Row-level security

dbTest("a signed-in person reads their own rows and nobody else's", async (sql) => {
  const [alice, bob] = await Promise.all([signUp("alice"), signUp("bob")]);
  await seedEverything(sql, alice.id);
  for (const table of TABLES) {
    const mine = await rest(alice.token, `${table}?select=*`);
    assertEquals(mine.status, 200, `${table}: ${JSON.stringify(mine.body)}`);
    assert((mine.body as unknown[]).length >= 1, `${table}: the owner should see their row`);
    assert((mine.body as { user_id: string }[]).every((row) => row.user_id === alice.id), `${table}: only the owner's rows`);
    const theirs = await rest(bob.token, `${table}?select=*`);
    assertEquals(theirs.body, [], `${table}: another person must see nothing`);
    const direct = await rest(bob.token, `${table}?select=*&user_id=eq.${alice.id}`);
    assertEquals(direct.body, [], `${table}: asking for someone's rows by id must return nothing`);
  }
  // The idempotency table is not readable by anyone signed in.
  assertEquals((await rest(alice.token, "trading_idempotency_keys?select=*")).status, 403);
  // Without signing in at all there is nothing to see.
  const anonymous = await fetch(`${Deno.env.get("API_URL")}/rest/v1/orders?select=*`, { headers: { apikey: Deno.env.get("ANON_KEY")! } });
  assert(anonymous.status === 401 || anonymous.status === 403, `anon got ${anonymous.status}`);
  await anonymous.body?.cancel();
});

dbTest("a signed-in person cannot write to any trading table", async (sql) => {
  const alice = await signUp("alice");
  const { ledger, order } = await seedEverything(sql, alice.id);
  const before = await sql`select cash from public.trading_accounts where id = ${ledger}`;

  const attempts: [string, string, RequestInit][] = [
    ["insert an order", "orders", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), user_id: alice.id, client_order_id: "mine", ledger_id: ledger, instrument_id: "us:AAPL", instrument: AAPL, side: "buy", type: "market", quantity: 1_000_000, time_in_force: "day", source_kind: "manual", status: "filled", reference_price: 1, created_at: new Date().toISOString(), updated_at: new Date().toISOString() }) }],
    ["mark an order filled", `orders?id=eq.${order}`, { method: "PATCH", body: JSON.stringify({ status_note: "edited" }) }],
    ["edit a position", `positions?ledger_id=eq.${ledger}`, { method: "PATCH", body: JSON.stringify({ quantity: 1_000_000 }) }],
    ["delete a position", `positions?ledger_id=eq.${ledger}`, { method: "DELETE" }],
    ["give themselves cash", `trading_accounts?id=eq.${ledger}`, { method: "PATCH", body: JSON.stringify({ cash: 1_000_000_000 }) }],
    ["turn on live trading", `risk_policies?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ live_manual_orders_enabled: true }) }],
    ["turn on autonomous live trading", `risk_policies?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ live_autonomous_agents_enabled: true }) }],
    ["flip the kill switch", `risk_policies?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ kill_switch_engaged: true }) }],
    ["insert a fill", "order_fills", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), user_id: alice.id, order_id: order, fill_no: 2, ledger_id: ledger, instrument_id: "us:AAPL", instrument: AAPL, side: "buy", quantity: 5, price: 1, time: new Date().toISOString(), source_kind: "manual" }) }],
    ["write an audit event", "audit_events", { method: "POST", body: JSON.stringify({ user_id: alice.id, time: new Date().toISOString(), actor: "user", kind: "orderFilled", summary: "forged" }) }],
    ["edit the audit trail", `audit_events?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ summary: "rewritten" }) }],
    ["delete the audit trail", `audit_events?user_id=eq.${alice.id}`, { method: "DELETE" }],
    ["create an agent", "trading_agents", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), user_id: alice.id, name: "x", mode: "autonomousLive", risk_policy: {}, budget: 1, schedule_interval_minutes: 5, created_at: new Date().toISOString() }) }],
    ["grant a trading connection", `broker_connections?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ permissions: ["read", "trade"] }) }],
    ["approve a proposal", `trade_proposals?user_id=eq.${alice.id}`, { method: "PATCH", body: JSON.stringify({ status: "submitted" }) }],
  ];
  for (const [what, path, init] of attempts) {
    const answer = await rest(alice.token, path, init);
    assertEquals(answer.status, 403, `${what}: expected to be refused, got ${answer.status} ${JSON.stringify(answer.body)}`);
    assertEquals((answer.body as { code: string }).code, "42501", what);
  }
  // The functions the scheduler uses are not callable by a person either.
  for (const rpc of ["claim_due_agents", "release_agent_lease", "trading_schedule_cron", "trading_invoke_scheduler"]) {
    const answer = await rest(alice.token, `rpc/${rpc}`, { method: "POST", body: JSON.stringify(rpc === "claim_due_agents" ? { p_max: 10 } : rpc === "release_agent_lease" ? { p_agent: crypto.randomUUID(), p_worker: crypto.randomUUID() } : {}) });
    assert(answer.status === 403 || answer.status === 404, `${rpc}: got ${answer.status}`);
  }
  // Nothing moved.
  assertEquals(await sql`select cash from public.trading_accounts where id = ${ledger}`, before);
  assertEquals((await sql`select kill_switch_engaged, live_manual_orders_enabled from public.risk_policies where user_id = ${alice.id}`)[0], { kill_switch_engaged: false, live_manual_orders_enabled: false });
  assertEquals(Number((await sql`select count(*) from public.audit_events where user_id = ${alice.id}`)[0].count), 1);
  // A person may check their own audit trail, and learns nothing about anyone else's.
  const own = await rest(alice.token, "rpc/verify_audit_chain", { method: "POST", body: JSON.stringify({ p_user: alice.id }) });
  assertEquals(own.body, [{ is_intact: true, broken_at_sequence: null, event_count: 1 }]);
  const bob = await signUp("bob");
  const other = await rest(bob.token, "rpc/verify_audit_chain", { method: "POST", body: JSON.stringify({ p_user: alice.id }) });
  assertEquals(other.body, [{ is_intact: true, broken_at_sequence: null, event_count: 0 }]);
});

// MARK: - Constraints

dbTest("constraints refuse impossible rows even from the service role", async (sql) => {
  const person = await signUp("constraints");
  await scratch(sql, async (tx) => {
    await tx`set local role service_role`;
    await tx`insert into public.risk_policies (user_id) values (${person.id}) on conflict do nothing`;
    const ledger = await seedAccount(tx, person.id);
    const agent = await seedAgent(tx, person.id);
    const order = await seedOrder(tx, person.id, ledger, { client_order_id: "once" });

    // Enumerations.
    assertMatch(await refused(tx, "an unknown side", (sp) => seedOrder(sp, person.id, ledger, { side: "short" })), /orders_side_check/);
    assertMatch(await refused(tx, "an unknown order type", (sp) => seedOrder(sp, person.id, ledger, { type: "iceberg" })), /orders_type_check/);
    assertMatch(await refused(tx, "an unknown status", (sp) => seedOrder(sp, person.id, ledger, { status: "done" })), /orders_status_check|cannot start/);
    assertMatch(await refused(tx, "an unknown mode", (sp) => seedOrder(sp, person.id, ledger, { mode: "margin" })), /orders_mode_check|cannot be booked/);
    assertMatch(await refused(tx, "an unknown currency", (sp) => seedAccount(sp, person.id, { currency: "XYZ" })), /currency_check/);
    assertMatch(await refused(tx, "an unknown account kind", (sp) => seedAccount(sp, person.id, { kind: "margin" })), /kind_check/);
    assertMatch(await refused(tx, "an unknown agent mode", (sp) => seedAgent(sp, person.id, { mode: "yolo" })), /mode_check/);

    // Sizes and prices.
    assertMatch(await refused(tx, "a working order for nothing", (sp) => seedOrder(sp, person.id, ledger, { quantity: 0 })), /orders_quantity_positive/);
    assertMatch(await refused(tx, "a negative quantity", (sp) => seedOrder(sp, person.id, ledger, { quantity: -5, status: "rejected" })), /orders_quantity_positive|orders_filled_within_quantity/);
    assertMatch(await refused(tx, "a zero reference price", (sp) => seedOrder(sp, person.id, ledger, { reference_price: 0 })), /orders_reference_price_positive/);
    assertMatch(await refused(tx, "a zero limit price", (sp) => seedOrder(sp, person.id, ledger, { type: "limit", limit_price: 0 })), /limit_price_check/);
    await seedOrder(tx, person.id, ledger, { quantity: 0, reference_price: 0, status: "rejected", status_note: "The quantity must be above zero." });
    assertMatch(await refused(tx, "more filled than ordered", (sp) => sp`update public.orders set status = 'partiallyFilled', filled_quantity = 10.5 where id = ${order}`), /orders_filled_within_quantity/);
    assertMatch(await refused(tx, "filled with nothing filled", (sp) => sp`update public.orders set status = 'filled' where id = ${order}`), /orders_filled_means_filled/);
    const fill = { user_id: person.id, order_id: order, ledger_id: ledger, instrument_id: "us:AAPL", instrument: tx.json(AAPL), side: "buy", time: new Date(), source_kind: "manual" };
    assertMatch(await refused(tx, "a fill of nothing", (sp) => sp`insert into public.order_fills ${sp({ ...fill, id: crypto.randomUUID(), fill_no: 1, quantity: 0, price: 100 })}`), /quantity_check/);
    assertMatch(await refused(tx, "a free fill", (sp) => sp`insert into public.order_fills ${sp({ ...fill, id: crypto.randomUUID(), fill_no: 1, quantity: 1, price: 0 })}`), /price_check/);

    // No short selling, no borrowing.
    const position = { user_id: person.id, ledger_id: ledger, instrument_id: "us:AAPL", instrument: tx.json(AAPL), cost_basis: 0, opened_at: new Date(), last_price: 100 };
    assertMatch(await refused(tx, "a negative holding", (sp) => sp`insert into public.positions ${sp({ ...position, quantity: -1 })}`), /quantity_check/);
    await tx`insert into public.positions ${tx({ ...position, quantity: 3 })}`;
    assertMatch(await refused(tx, "selling into a short", (sp) => sp`update public.positions set quantity = -0.5 where ledger_id = ${ledger}`), /quantity_check/);
    assertMatch(await refused(tx, "negative paper cash", (sp) => sp`update public.trading_accounts set cash = -0.01 where id = ${ledger}`), /trading_accounts_cash_not_negative/);
    assertMatch(await refused(tx, "a book that starts overdrawn", (sp) => seedAccount(sp, person.id, { cash: -1 })), /trading_accounts_cash_not_negative/);

    // Idempotency: one client order id per person.
    assertMatch(await refused(tx, "the same client order id twice", (sp) => seedOrder(sp, person.id, ledger, { client_order_id: "once" })), /orders_user_id_client_order_id_key/);
    assertMatch(await refused(tx, "the same id again as a refused order", (sp) => seedOrder(sp, person.id, ledger, { client_order_id: "once", status: "rejected" })), /orders_user_id_client_order_id_key/);

    // Proposals: one waiting per agent, instrument and side; one order per proposal.
    const signal = crypto.randomUUID();
    await tx`insert into public.trading_signals ${tx({ id: signal, user_id: person.id, agent_id: agent, strategy_version: 1, instrument_id: "us:AAPL", instrument: tx.json(AAPL), action: "buy", headline: "Buy", bar_time: new Date("2026-11-09T05:00:00Z"), close: 100, created_at: new Date(), provenance: tx.json({ kind: "market", source: "test", delaySeconds: 0 }) })}`;
    const proposal = (side: string, status = "pending", extra: Record<string, unknown> = {}) => ({
      id: crypto.randomUUID(), user_id: person.id, agent_id: agent, signal_id: signal, strategy_version: 1, ledger_id: ledger, instrument_id: "us:AAPL",
      instrument: tx.json(AAPL), side, quantity: 1, reference_price: 100, notional: 100, status, risk: tx.json({ checks: [] }), headline: "x",
      signal_bar_time: new Date("2026-11-09T05:00:00Z"), created_at: new Date(), expires_at: new Date(Date.now() + 86_400_000),
      resolved_at: status === "pending" ? null : new Date(), client_order_id: `proposal-${crypto.randomUUID()}`, ...extra,
    });
    const first = proposal("buy");
    await tx`insert into public.trade_proposals ${tx(first)}`;
    assertMatch(await refused(tx, "a second waiting buy for the same asset", (sp) => sp`insert into public.trade_proposals ${sp(proposal("buy"))}`), /trade_proposals_one_pending_idx/);
    await tx`insert into public.trade_proposals ${tx(proposal("sell"))}`;                     // the other side is a different proposal
    await tx`insert into public.trade_proposals ${tx(proposal("buy", "blocked"))}`;           // a resolved one doesn't count
    assertMatch(await refused(tx, "the same signal twice", (sp) => sp`insert into public.trading_signals ${sp({ id: crypto.randomUUID(), user_id: person.id, agent_id: agent, strategy_version: 1, instrument_id: "us:AAPL", instrument: sp.json(AAPL), action: "buy", headline: "Buy", bar_time: new Date("2026-11-09T05:00:00Z"), close: 100, created_at: new Date(), provenance: sp.json({ kind: "market", source: "test", delaySeconds: 0 }) })}`), /trading_signals_agent_id_instrument_id_bar_time_action_stra/);
    assertMatch(await refused(tx, "a synthetic signal", (sp) => sp`insert into public.trading_signals ${sp({ id: crypto.randomUUID(), user_id: person.id, agent_id: agent, strategy_version: 1, instrument_id: "us:MSFT", instrument: sp.json({ ...AAPL, symbol: "MSFT" }), action: "buy", headline: "Buy", bar_time: new Date(), close: 100, created_at: new Date(), provenance: sp.json({ kind: "synthetic", source: "synthetic", delaySeconds: 0 }) })}`), /provenance_check/);
    const forProposal = await seedOrder(tx, person.id, ledger, { source_kind: "agent", agent_id: agent, proposal_id: first.id });
    assertMatch(await refused(tx, "a second order for one proposal", (sp) => seedOrder(sp, person.id, ledger, { source_kind: "agent", agent_id: agent, proposal_id: first.id })), /orders_one_per_proposal_idx/);
    await tx`update public.trade_proposals set status = 'submitted', resolved_at = now(), order_id = ${forProposal} where id = ${first.id}`;
    assertMatch(await refused(tx, "one order claimed by two proposals", (sp) => sp`insert into public.trade_proposals ${sp(proposal("buy", "submitted", { order_id: forProposal }))}`), /trade_proposals_order_id_key/);
    assertMatch(await refused(tx, "a resolved proposal changing its mind", (sp) => sp`update public.trade_proposals set status = 'rejected' where id = ${first.id}`), /already submitted/);
    assertMatch(await refused(tx, "re-pointing a proposal at another order", (sp) => sp`update public.trade_proposals set order_id = ${order} where id = ${first.id}`), /at most one order/);
    assertMatch(await refused(tx, "an agent order without an agent", (sp) => seedOrder(sp, person.id, ledger, { source_kind: "agent" })), /orders_agent_source/);

    // Rows can't be attached to someone else's book.
    const stranger = crypto.randomUUID();
    assertMatch(await refused(tx, "an order in another person's name", (sp) => seedOrder(sp, stranger, ledger)), /foreign key|violates/);
  });
});

// MARK: - The order state machine

dbTest("orders move only as OrderStatus.canTransition allows", async (sql) => {
  // The SQL rule, the TypeScript rule and the Swift rule (from the shared vectors) agree on all 49 pairs.
  const vectors = await loadVectors("broker");
  for (const [from, to, expected] of vectors.transitions as [OrderStatus, OrderStatus, boolean][]) {
    const [row] = await sql`select public.trading_order_can_transition(${from}, ${to}) as allowed`;
    assertEquals(row.allowed, expected, `SQL: ${from} → ${to}`);
    assertEquals(canTransition(from, to), expected, `TypeScript: ${from} → ${to}`);
  }

  const person = await signUp("machine");
  const reach = async (tx: Tx, ledger: string, status: OrderStatus): Promise<string> => {
    if (status === "pendingSubmit" || status === "accepted" || status === "rejected") return await seedOrder(tx, person.id, ledger, { status });
    const id = await seedOrder(tx, person.id, ledger);
    const filled = status === "filled" ? 10 : status === "partiallyFilled" ? 4 : 0;
    await tx`update public.orders set status = ${status}, filled_quantity = ${filled}, average_fill_price = ${filled > 0 ? 100 : 0} where id = ${id}`;
    return id;
  };
  await scratch(sql, async (tx) => {
    await tx`set local role service_role`;
    const ledger = await seedAccount(tx, person.id);
    let checked = 0;
    for (const from of ORDER_STATUSES) {
      for (const to of ORDER_STATUSES) {
        if (from === to && from !== "partiallyFilled" && canTransition(from, to) === false && (from === "pendingSubmit" || from === "accepted")) {
          // Staying "working" isn't a move: a note or a triggered stop may still be recorded.
          const id = await reach(tx, ledger, from);
          await tx`update public.orders set status_note = 'Waiting for the market to open.' where id = ${id}`;
          continue;
        }
        const id = await reach(tx, ledger, from);
        const filled = to === "filled" ? 10 : to === "partiallyFilled" ? 6 : from === "partiallyFilled" ? 4 : 0;
        let moved = true;
        try {
          await tx.savepoint((sp) => sp`update public.orders set status = ${to}, filled_quantity = ${filled}, average_fill_price = ${filled > 0 ? 100 : 0}, updated_at = now() where id = ${id}`);
        } catch {
          moved = false;
        }
        assertEquals(moved, canTransition(from, to), `trigger: ${from} → ${to}`);
        checked += 1;
      }
    }
    assertEquals(checked, 47);

    // An order can't be born filled, and what it asked for can't be changed afterwards.
    assertMatch(await refused(tx, "an order born filled", (sp) => seedOrder(sp, person.id, ledger, { status: "filled", filled_quantity: 10 })), /cannot start as filled/);
    assertMatch(await refused(tx, "an order born with fills", (sp) => seedOrder(sp, person.id, ledger, { filled_quantity: 1 })), /cannot already have fills/);
    const working = await seedOrder(tx, person.id, ledger);
    assertMatch(await refused(tx, "changing the quantity", (sp) => sp`update public.orders set quantity = 1000 where id = ${working}`), /cannot be changed after it is placed/);
    assertMatch(await refused(tx, "changing the side", (sp) => sp`update public.orders set side = 'sell' where id = ${working}`), /cannot be changed after it is placed/);
    await tx`update public.orders set status = 'partiallyFilled', filled_quantity = 5, average_fill_price = 100 where id = ${working}`;
    assertMatch(await refused(tx, "taking a fill back", (sp) => sp`update public.orders set filled_quantity = 2 where id = ${working}`), /cannot be taken back/);
    const done = await reach(tx, ledger, "canceled");
    assertMatch(await refused(tx, "touching a finished order", (sp) => sp`update public.orders set status_note = 'reopened' where id = ${done}`), /can no longer change/);
  });

  // At commit, an order's filled quantity must be what its fills add up to.
  const ledger = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    return await seedAccount(tx as unknown as Tx, person.id);
  });
  let committed = true;
  try {
    await sql.begin(async (tx) => {
      await tx`set local role service_role`;
      const id = await seedOrder(tx as unknown as Tx, person.id, ledger);
      await tx`update public.orders set status = 'filled', filled_quantity = 10, average_fill_price = 100 where id = ${id}`;   // no fill row
    });
  } catch (error) {
    committed = false;
    assertMatch(String(error), /its fills add up to 0/);
  }
  assertEquals(committed, false, "a fill-less 'filled' order must not commit");
});

// MARK: - Live trading does not exist

dbTest("live rows and live flags are refused for every role", async (sql) => {
  const person = await signUp("live");
  for (const role of ["service_role", "postgres"]) {
    await scratch(sql, async (tx) => {
      await tx.unsafe(`set local role ${role}`);
      await tx`insert into public.risk_policies (user_id) values (${person.id}) on conflict do nothing`;
      for (const flag of ["live_manual_orders_enabled", "live_approval_agents_enabled", "live_autonomous_agents_enabled"]) {
        assertMatch(await refused(tx, `${role} setting ${flag}`, (sp) => sp.unsafe(`update public.risk_policies set ${flag} = true where user_id = '${person.id}'`)),
          /live_trading_not_available_in_this_build/);
      }
      const ledger = await seedAccount(tx, person.id);
      const agent = await seedAgent(tx, person.id);
      assertMatch(await refused(tx, "a live account", (sp) => seedAccount(sp, person.id, { mode: "live" })), /live trading is not enabled/);
      assertMatch(await refused(tx, "making an account live", (sp) => sp`update public.trading_accounts set mode = 'live' where id = ${ledger}`), /live trading is not enabled/);
      assertMatch(await refused(tx, "a live order", (sp) => seedOrder(sp, person.id, ledger, { mode: "live" })), /live trading is not enabled|order cannot be booked to a paper account/);
      assertMatch(await refused(tx, "a refused live order", (sp) => seedOrder(sp, person.id, ledger, { mode: "live", status: "rejected" })), /live trading is not enabled|order cannot be booked to a paper account/);
      assertMatch(await refused(tx, "a live agent order", (sp) => seedOrder(sp, person.id, ledger, { mode: "live", source_kind: "agent", agent_id: agent })), /live trading is not enabled|order cannot be booked to a paper account/);
      for (const mode of ["approvalRequired", "autonomousLive"]) {
        assertMatch(await refused(tx, `an agent in ${mode} mode`, (sp) => seedAgent(sp, person.id, { mode })), /live trading is not enabled/);
        assertMatch(await refused(tx, `promoting an agent to ${mode}`, (sp) => sp`update public.trading_agents set mode = ${mode} where id = ${agent}`), /live trading is not enabled/);
      }
      if (role === "postgres") {
        // Two separate rules stand in the way of a live order. With the order rule switched off (only the owner
        // of the table can), the live rule alone still refuses it.
        await tx`alter table public.orders disable trigger orders_guard`;
        assertMatch(await refused(tx, "a live order with the order rule off", (sp) => seedOrder(sp, person.id, ledger, { mode: "live" })), /live trading is not enabled/);
        await tx`alter table public.orders enable trigger orders_guard`;
      }
      const order = await seedOrder(tx, person.id, ledger);
      assertMatch(await refused(tx, "a live fill", (sp) => sp`insert into public.order_fills ${sp({ id: crypto.randomUUID(), user_id: person.id, order_id: order, fill_no: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: sp.json(AAPL), side: "buy", quantity: 1, price: 100, time: new Date(), source_kind: "manual", mode: "live" })}`), /live trading is not enabled|must match its order/);
      const signal = crypto.randomUUID();
      await tx`insert into public.trading_signals ${tx({ id: signal, user_id: person.id, agent_id: agent, strategy_version: 1, instrument_id: "us:AAPL", instrument: tx.json(AAPL), action: "buy", headline: "Buy", bar_time: new Date(), close: 100, created_at: new Date(), provenance: tx.json({ kind: "market", source: "t", delaySeconds: 0 }) })}`;
      assertMatch(await refused(tx, "a live proposal", (sp) => sp`insert into public.trade_proposals ${sp({ id: crypto.randomUUID(), user_id: person.id, agent_id: agent, signal_id: signal, strategy_version: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: sp.json(AAPL), side: "buy", quantity: 1, reference_price: 100, notional: 100, mode: "live", status: "pending", risk: sp.json({}), headline: "x", signal_bar_time: new Date(), created_at: new Date(), expires_at: new Date(), client_order_id: "p" })}`), /live trading is not enabled/);
      // A read-only connection can be recorded; one that could trade real money cannot.
      await tx`insert into public.broker_connections ${tx({ user_id: person.id, adapter_id: "snaptrade", name: "CommSec", environment: "live", permissions: ["read"] })}`;
      assertMatch(await refused(tx, "a live connection with trade permission", (sp) => sp`insert into public.broker_connections ${sp({ user_id: person.id, adapter_id: "alpaca", name: "Alpaca", environment: "live", permissions: ["read", "trade"] })}`), /broker_connections_no_live_trade_in_this_build/);
      // Connection metadata contains a masked key hint. Sealed credentials live in their own table.
      const columns = await tx`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'broker_connections'`;
      assert(!columns.some((c) => c.column_name !== "key_hint" && /secret|token|credential|key|password/i.test(c.column_name)), "broker_connections must not have a credentials column");
    });
  }
});

// MARK: - Kill switch

dbTest("with the kill switch on, the database refuses agent orders, fills and waiting proposals", async (sql) => {
  const person = await signUp("kill");
  await scratch(sql, async (tx) => {
    await tx`set local role service_role`;
    await tx`insert into public.risk_policies (user_id) values (${person.id}) on conflict do nothing`;
    const ledger = await seedAccount(tx, person.id);
    const agent = await seedAgent(tx, person.id);
    const working = await seedOrder(tx, person.id, ledger, { source_kind: "agent", agent_id: agent });
    await tx`update public.risk_policies set kill_switch_engaged = true, kill_switch_at = now() where user_id = ${person.id}`;

    assertMatch(await refused(tx, "a new agent order", (sp) => seedOrder(sp, person.id, ledger, { source_kind: "agent", agent_id: agent })), /kill switch is on/);
    assertMatch(await refused(tx, "an agent fill", (sp) => sp`insert into public.order_fills ${sp({ id: crypto.randomUUID(), user_id: person.id, order_id: working, fill_no: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: sp.json(AAPL), side: "buy", quantity: 10, price: 100, time: new Date(), source_kind: "agent", agent_id: agent, mode: "paper" })}`), /kill switch is on/);
    const signal = crypto.randomUUID();
    await tx`insert into public.trading_signals ${tx({ id: signal, user_id: person.id, agent_id: agent, strategy_version: 1, instrument_id: "us:AAPL", instrument: tx.json(AAPL), action: "buy", headline: "Buy", bar_time: new Date(), close: 100, created_at: new Date(), provenance: tx.json({ kind: "market", source: "t", delaySeconds: 0 }) })}`;
    assertMatch(await refused(tx, "a waiting proposal", (sp) => sp`insert into public.trade_proposals ${sp({ id: crypto.randomUUID(), user_id: person.id, agent_id: agent, signal_id: signal, strategy_version: 1, ledger_id: ledger, instrument_id: "us:AAPL", instrument: sp.json(AAPL), side: "buy", quantity: 1, reference_price: 100, notional: 100, status: "pending", risk: sp.json({}), headline: "x", signal_bar_time: new Date(), created_at: new Date(), expires_at: new Date(), client_order_id: "p" })}`), /kill switch is on/);
    // A refusal can still be recorded, the agent's working order can be cancelled, and the person can trade by hand.
    await seedOrder(tx, person.id, ledger, { source_kind: "agent", agent_id: agent, status: "rejected", status_note: "The kill switch is on." });
    await tx`update public.orders set status = 'canceled', status_note = 'Kill switch.' where id = ${working}`;
    await seedOrder(tx, person.id, ledger);
    assertMatch(await refused(tx, "a kill switch time without the switch", (sp) => sp`update public.risk_policies set kill_switch_engaged = false where user_id = ${person.id}`), /risk_policies_kill_switch_time/);
  });
});

// MARK: - The audit trail

dbTest("the audit trail is chained by the database and cannot be rewritten", async (sql) => {
  const person = await signUp("audit");
  const genesis = "0".repeat(64);
  await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    // Whatever the writer supplies for the chain fields is ignored.
    const first = await seedAudit(tx as unknown as Tx, person.id, { sequence: 99, previous_hash: "f".repeat(64), hash: "e".repeat(64), summary: "One" });
    assertEquals([first.sequence, first.previous_hash], [1, genesis]);
    const second = await seedAudit(tx as unknown as Tx, person.id, { summary: "Two", details: tx.json({ b: "2", a: "1" }) });
    assertEquals([second.sequence, second.previous_hash], [2, first.hash]);
    await seedAudit(tx as unknown as Tx, person.id, { summary: "Three" });
    assertMatch(await refused(tx as unknown as Tx, "non-text audit details", (sp) => seedAudit(sp, person.id, { details: sp.json({ n: 1 }) })), /must be text values/);
  });
  assertEquals((await sql`select * from public.verify_audit_chain(${person.id})`)[0], { is_intact: true, broken_at_sequence: null, event_count: "3" });

  // The service role's ordinary queries are refused outright; the owner role is stopped by the triggers.
  await scratch(sql, async (tx) => {
    await tx`set local role service_role`;
    assertMatch(await refused(tx, "service role update", (sp) => sp`update public.audit_events set summary = 'x' where user_id = ${person.id}`), /permission denied/);
    assertMatch(await refused(tx, "service role delete", (sp) => sp`delete from public.audit_events where user_id = ${person.id}`), /permission denied/);
    assertMatch(await refused(tx, "service role truncate", (sp) => sp`truncate public.audit_events`), /permission denied/);
  });
  await scratch(sql, async (tx) => {
    assertMatch(await refused(tx, "owner update", (sp) => sp`update public.audit_events set summary = 'x' where user_id = ${person.id}`), /append-only/);
    assertMatch(await refused(tx, "owner delete", (sp) => sp`delete from public.audit_events where user_id = ${person.id}`), /append-only/);
    assertMatch(await refused(tx, "owner truncate", (sp) => sp`truncate public.audit_events`), /append-only/);
  });
  assertEquals(Number((await sql`select count(*) from public.audit_events where user_id = ${person.id}`)[0].count), 3);

  // If someone with the owner's rights switches the guard off and edits a row, verification says where.
  await scratch(sql, async (tx) => {
    await tx`alter table public.audit_events disable trigger audit_events_no_update`;
    await tx`update public.audit_events set summary = 'Two (edited)' where user_id = ${person.id} and sequence = 2`;
    assertEquals((await tx`select * from public.verify_audit_chain(${person.id})`)[0], { is_intact: false, broken_at_sequence: "2", event_count: "3" });
  });
  await scratch(sql, async (tx) => {
    await tx`alter table public.audit_events disable trigger audit_events_no_delete`;
    await tx`delete from public.audit_events where user_id = ${person.id} and sequence = 2`;
    assertEquals((await tx`select * from public.verify_audit_chain(${person.id})`)[0], { is_intact: false, broken_at_sequence: "3", event_count: "2" });
  });
  assertEquals((await sql`select * from public.verify_audit_chain(${person.id})`)[0].is_intact, true);

  // Fills and strategy versions are append-only too.
  const ids = await seedEverything(sql, person.id);
  await scratch(sql, async (tx) => {
    assertMatch(await refused(tx, "editing a fill", (sp) => sp`update public.order_fills set price = 1 where order_id = ${ids.order}`), /append-only/);
    assertMatch(await refused(tx, "deleting a fill", (sp) => sp`delete from public.order_fills where order_id = ${ids.order}`), /append-only/);
    assertMatch(await refused(tx, "rewriting a strategy version", (sp) => sp`update public.agent_strategy_versions set spec = '{}' where agent_id = ${ids.agent}`), /append-only/);
    assertMatch(await refused(tx, "deleting a strategy version", (sp) => sp`delete from public.agent_strategy_versions where agent_id = ${ids.agent}`), /append-only/);
    assertMatch(await refused(tx, "deleting a book that has history", (sp) => sp`delete from public.trading_accounts where id = ${ids.ledger}`), /append-only/);
  });
});

dbTest("the database hashes audit events exactly as the Swift core does", async (sql) => {
  const vectors = await loadVectors("audit");
  let compared = 0;
  for (const chain of vectors.chains) {
    if (chain.baseSequence !== 0) continue;        // an archived chain starts mid-way; the database always starts at the beginning
    const person = await signUp("hash");
    const stored = await sql.begin(async (tx) => {
      await tx`set local role service_role`;
      const out = [];
      for (const expected of chain.events) {
        const input = expected.input;
        const [row] = await tx`insert into public.audit_events ${tx({
          user_id: person.id, time: tx`to_timestamp(${input.timeMs}::double precision / 1000)` as never, actor: input.actor, kind: input.kind,
          summary: input.summary, mode: input.mode ?? null, agent_id: input.agentID ?? null, ledger_id: input.ledgerID ?? null,
          order_id: input.orderID ?? null, proposal_id: input.proposalID ?? null, instrument_id: input.instrumentID ?? null,
          details: tx.json(input.details),
        })} returning *, round(extract(epoch from time) * 1000)::float8 as time_ms`;
        out.push(row);
      }
      return out;
    });
    const events: AuditEvent[] = [];
    stored.forEach((row, index) => {
      const expected = chain.events[index];
      assertEquals(Number(row.sequence), expected.sequence, `${chain.name} #${index + 1} sequence`);
      assertEquals(row.previous_hash, expected.previousHash, `${chain.name} #${index + 1} previous hash`);
      assertEquals(row.hash, expected.hash, `${chain.name} #${index + 1}: database hash differs from Swift's for ${JSON.stringify(expected.canonical)}`);
      compared += 1;
      events.push({
        id: row.id, sequence: Number(row.sequence), time: row.time_ms, actor: row.actor, kind: row.kind, summary: row.summary,
        mode: row.mode ?? undefined, agentID: row.agent_id ?? undefined, ledgerID: row.ledger_id ?? undefined, orderID: row.order_id ?? undefined,
        proposalID: row.proposal_id ?? undefined, instrumentID: row.instrument_id ?? undefined, details: row.details,
        previousHash: row.previous_hash, hash: row.hash,
      });
    });
    // The TypeScript rule verifies the stored chain too. Ids read back in lower case; times are read to the
    // millisecond with the rounding the hash uses (a JavaScript Date would cut 999.5 ms down to 999).
    assertEquals(verifyEvents(events), { isIntact: true, eventCount: events.length }, chain.name);
    assertEquals((await sql`select is_intact from public.verify_audit_chain(${person.id})`)[0].is_intact, true);
  }
  assert(compared >= 40, `only ${compared} hashes compared`);
});

dbTest("concurrent writers can't take the same place in a person's chain", async (sql) => {
  const person = await signUp("race");
  const writers = Array.from({ length: 24 }, (_, i) => sql.begin(async (tx) => {
    await tx`set local role service_role`;
    await seedAudit(tx as unknown as Tx, person.id, { summary: `Writer ${i}` });
    await tx`select pg_sleep(0.02)`;
    await seedAudit(tx as unknown as Tx, person.id, { summary: `Writer ${i} again` });
  }));
  await Promise.all(writers);
  const [check] = await sql`select * from public.verify_audit_chain(${person.id})`;
  assertEquals(check, { is_intact: true, broken_at_sequence: null, event_count: "48" });
  const sequences = (await sql`select sequence from public.audit_events where user_id = ${person.id} order by sequence`).map((r) => Number(r.sequence));
  assertEquals(sequences, Array.from({ length: 48 }, (_, i) => i + 1));
});

dbTest("deleting an account takes its history with it, and nothing else can", async (sql) => {
  const person = await signUp("leaving");
  await seedEverything(sql, person.id);
  await sql`delete from auth.users where id = ${person.id}`;
  for (const table of TABLES) {
    const [row] = await sql.unsafe(`select count(*)::int as n from public.${table} where user_id = '${person.id}'`);
    assertEquals(row.n, 0, table);
  }
});

// MARK: - The scheduler's lease

dbTest("two schedulers never get the same agent", async (sql) => {
  const [alice, bob] = await Promise.all([signUp("lease-a"), signUp("lease-b")]);
  // A moment before any other test's agents were due, so only the ones seeded here can be claimed.
  const now = new Date("2020-01-07T15:00:00Z");
  const due = new Date(now.getTime() - 60_000);
  const seeded = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    const t = tx as unknown as Tx;
    await tx`insert into public.risk_policies (user_id, kill_switch_engaged, kill_switch_at) values (${bob.id}, true, now())`;
    return {
      a: await seedAgent(t, alice.id, { next_run_at: due }),
      b: await seedAgent(t, alice.id, { next_run_at: new Date(due.getTime() - 1_000) }),
      c: await seedAgent(t, alice.id, { next_run_at: null }),
      paused: await seedAgent(t, alice.id, { next_run_at: due, status: "paused", pause_reason: "user" }),
      later: await seedAgent(t, alice.id, { next_run_at: new Date(now.getTime() + 3_600_000) }),
      deleted: await seedAgent(t, alice.id, { next_run_at: due, deleted_at: new Date() }),
      killed: await seedAgent(t, bob.id, { next_run_at: due }),
    };
  });
  const mine = [seeded.a, seeded.b, seeded.c];
  const only = (rows: { agent_id: string }[]) => rows.map((r) => r.agent_id).filter((id) => Object.values(seeded).includes(id));
  const claim = (tx: Sql | Tx, max: number, at: Date, worker: string) =>
    tx`select agent_id from public.claim_due_agents(${max}, 120, ${at}, ${worker})` as unknown as Promise<{ agent_id: string }[]>;

  const one = connect(1), two = connect(1);
  const workerOne = crypto.randomUUID(), workerTwo = crypto.randomUUID();
  try {
    let firstClaim: string[] = [], secondClaim: string[] = [];
    let release!: () => void;
    const hold = new Promise<void>((resolve) => { release = resolve; });
    // The first scheduler claims two and keeps its transaction open…
    const first = one.begin(async (tx) => {
      await tx`set local role service_role`;
      firstClaim = only(await claim(tx as unknown as Tx, 2, now, workerOne));
      await hold;
    });
    while (firstClaim.length === 0) await new Promise((resolve) => setTimeout(resolve, 20));
    // …and a second one, at the same moment, is not made to wait and gets only what is left.
    await two.begin(async (tx) => {
      await tx`set local role service_role`;
      await tx`set local lock_timeout = '2s'`;
      secondClaim = only(await claim(tx as unknown as Tx, 10, now, workerTwo));
    });
    release();
    await first;
    assertEquals(firstClaim.length, 2);
    assertEquals(secondClaim.length, 1);
    assertEquals([...firstClaim, ...secondClaim].sort(), [...mine].sort(), "every due agent exactly once; paused, later, deleted and kill-switched ones never");
    assertEquals([...firstClaim].sort(), [seeded.b, seeded.c].sort(), "the one that never ran and the longest overdue go first");

    // While the leases are held, nobody else gets them — even after both transactions have committed.
    assertEquals(only(await claim(sql, 10, new Date(now.getTime() + 60_000), crypto.randomUUID())), []);
    // A late worker can't free someone else's lease; the holder can.
    assertEquals((await sql`select public.release_agent_lease(${seeded.a}, ${crypto.randomUUID()}) as ok`)[0].ok, false);
    const holder = firstClaim.includes(seeded.a) ? workerOne : workerTwo;
    assertEquals((await sql`select public.release_agent_lease(${seeded.a}, ${holder}) as ok`)[0].ok, true);
    assertEquals(only(await claim(sql, 10, new Date(now.getTime() + 60_000), crypto.randomUUID())), [seeded.a]);
    // A lease that is never released (a crashed run) simply runs out.
    assertEquals(only(await claim(sql, 10, new Date(now.getTime() + 121_000), crypto.randomUUID())).sort(), [seeded.b, seeded.c].sort());
    assertEquals(only(await claim(sql, 0, new Date(now.getTime() + 10 * 60_000), crypto.randomUUID())), [], "a limit of zero claims nothing");
  } finally {
    await one.end({ timeout: 5 });
    await two.end({ timeout: 5 });
    await sql`update public.trading_agents set deleted_at = now() where id in ${sql(Object.values(seeded))}`;
  }
});

dbTest("the every-minute schedule is skipped cleanly where pg_cron or pg_net is missing", async (sql) => {
  const installed = (await sql`select extname from pg_extension where extname in ('pg_cron', 'pg_net')`).map((r) => r.extname);
  const [scheduled] = await sql`select public.trading_schedule_cron() as result`;
  const [invoked] = await sql`select public.trading_invoke_scheduler() as result`;
  if (installed.includes("pg_cron") && installed.includes("pg_net")) {
    assertEquals(scheduled.result, "scheduled");
  } else {
    assertMatch(scheduled.result, /^skipped: pg_(cron|net) is not installed$/);
  }
  assertMatch(invoked.result, /^(skipped: .+|requested)$/);
  // The migration file itself carries no secret and no project address.
  const migration = await Deno.readTextFile(new URL("../../../migrations/20261113120000_trading_platform.sql", import.meta.url));
  assert(!/eyJ[A-Za-z0-9_-]{10,}|sb_secret_|supabase\.co\/functions\/v1\/agent-scheduler'\s*\)/.test(migration.replace(/<project>/g, "")), "no key or live address in the migration");
});

// MARK: - Scheduler upkeep

dbTest("the traded-value cache keeps only real figures for a day, newest wins, and only the functions can touch it", async (sql) => {
  const id = `crypto:T${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
  const store = postgresVolumeStore(sql);
  const t0 = Date.parse("2026-11-13T00:00:00Z");
  try {
    await store.write({ [id]: 4.2e10 }, t0, "CoinGecko");
    assertEquals(await store.read([id], t0 - 86_400_000), { [id]: 4.2e10 });
    assertEquals(await store.read([id], t0 + 1), {}, "older than asked for: not returned");
    // An older answer finishing late doesn't replace a newer one; a newer one does.
    await store.write({ [id]: 1 }, t0 - 60_000, "CoinGecko");
    assertEquals((await sql`select dollar_volume from public.trading_volume_cache where instrument_id = ${id}`)[0].dollar_volume, 4.2e10);
    await store.write({ [id]: 4.4e10 }, t0 + 60_000, "CoinGecko");
    assertEquals((await sql`select dollar_volume, source from public.trading_volume_cache where instrument_id = ${id}`)[0], { dollar_volume: 4.4e10, source: "CoinGecko" });

    // Unknown stays unknown: the table refuses anything that isn't a real positive figure.
    await scratch(sql, async (tx) => {
      await tx`set local role service_role`;
      for (const bad of [0, -5, Number.POSITIVE_INFINITY, Number.NaN]) {
        assertMatch(await refused(tx, `a figure of ${bad}`, (sp) => sp`insert into public.trading_volume_cache ${sp({ instrument_id: `crypto:BAD${String(bad).length}`, dollar_volume: bad, source: "x", fetched_at: new Date() })}`), /dollar_volume_check/);
      }
    });

    // Nobody signed in can read or write it, and the anonymous key can't either.
    const person = await signUp("cache");
    assertEquals((await rest(person.token, "trading_volume_cache?select=*")).status, 403);
    assertEquals((await rest(person.token, "trading_volume_cache", { method: "POST", body: JSON.stringify({ instrument_id: "crypto:BTC", dollar_volume: 1, source: "me", fetched_at: new Date().toISOString() }) })).status, 403);
    const anonymous = await fetch(`${Deno.env.get("API_URL")}/rest/v1/trading_volume_cache?select=*`, { headers: { apikey: Deno.env.get("ANON_KEY")! } });
    assert(anonymous.status === 401 || anonymous.status === 403, `anon got ${anonymous.status}`);
    await anonymous.body?.cancel();
  } finally {
    await sql`delete from public.trading_volume_cache where instrument_id = ${id}`;
  }
});

dbTest("idempotency keys older than 30 days are pruned; newer ones stay", async (sql) => {
  const person = await signUp("prune");
  const now = Date.now();
  const day = 86_400_000;
  await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    for (const [key, age] of [["old-key-0001", 31 * day], ["old-key-0002", 400 * day], ["edge-key-001", 30 * day - 60_000], ["new-key-0001", day], ["now-key-0001", 0]] as const) {
      await tx`insert into public.trading_idempotency_keys ${tx({ user_id: person.id, key, action: "placeOrder", status: 200, response: tx.json({ ok: true }), created_at: new Date(now - age) })}`;
    }
  });
  const pruned = await pruneIdempotencyKeys(sql, now);
  assert(pruned >= 2, `pruned ${pruned}`);
  assertEquals((await sql`select key from public.trading_idempotency_keys where user_id = ${person.id} order by key`).map((row) => row.key),
    ["edge-key-001", "new-key-0001", "now-key-0001"]);
  assertEquals(await pruneIdempotencyKeys(sql, now), 0, "nothing left to prune");
  // The prune can walk the created_at index (on a tiny local table the planner may still
  // prefer a scan, so a scan is ruled out to ask whether the index serves this query).
  const plan = await sql.begin(async (tx) => {
    await tx`set local enable_seqscan = off`;
    return (await tx`explain select user_id, key from public.trading_idempotency_keys where created_at < now() - interval '30 days' order by created_at limit 5000`)
      .map((row) => String(Object.values(row)[0])).join("\n");
  });
  assertMatch(plan, /trading_idempotency_keys_created_at_idx/);
});

dbTest("with pg_cron and pg_net present, one job calls the scheduler every minute with the secret from Vault", async (sql) => {
  // Everything here happens in a transaction that is rolled back: the extensions aren't left installed,
  // no job is left scheduled, and the queued request is never sent.
  let proven = false;
  await scratch(sql, async (tx) => {
    try {
      await tx.savepoint(async (sp) => {
        await sp`create extension if not exists pg_cron`;
        await sp`create extension if not exists pg_net`;
      });
    } catch (error) {
      console.log(`  (pg_cron / pg_net can't be installed on this stack, so only the skip path is proven: ${error instanceof Error ? error.message : error})`);
      return;
    }
    // No address or secret configured yet: scheduled, but each tick does nothing.
    assertEquals((await tx`select public.trading_schedule_cron() as result`)[0].result, "scheduled");
    assertEquals((await tx`select public.trading_schedule_cron() as result`)[0].result, "scheduled", "scheduling twice is harmless");
    const jobs = await tx`select jobname, schedule, command from cron.job where jobname like 'trading%'`;
    assertEquals(jobs.map((job) => [job.jobname, job.schedule, job.command]), [["trading-agent-scheduler", "* * * * *", "select public.trading_invoke_scheduler()"]]);
    assertEquals((await tx`select public.trading_invoke_scheduler() as result`)[0].result, "skipped: the scheduler address or secret is not set");

    // The address and the secret live in Vault (encrypted), not in the job, the migration or any table a person can read.
    const secret = `test-${crypto.randomUUID()}`;
    await tx`select vault.create_secret('http://127.0.0.1:9/functions/v1/agent-scheduler', 'trading_scheduler_url')`;
    await tx`select vault.create_secret(${secret}, 'trading_scheduler_secret')`;
    assertEquals((await tx`select public.trading_invoke_scheduler() as result`)[0].result, "requested");
    const queued = await tx`select method, url, headers, timeout_milliseconds from net.http_request_queue`;
    assertEquals(queued.length, 1);
    assertEquals([queued[0].method, queued[0].url, queued[0].headers["x-scheduler-secret"]], ["POST", "http://127.0.0.1:9/functions/v1/agent-scheduler", secret]);
    assert(!jobs.some((job) => String(job.command).includes(secret)));
    const stored = await tx`select secret from vault.secrets where name = 'trading_scheduler_secret'`;
    assert(stored.length === 1 && stored[0].secret !== secret, "Vault keeps it encrypted at rest");
    proven = true;
  });
  // Rolled back: nothing of it remains.
  assertEquals((await sql`select count(*)::int as n from pg_extension where extname in ('pg_cron', 'pg_net')`)[0].n, 0);
  assertEquals((await sql`select count(*)::int as n from vault.secrets where name like 'trading_scheduler%'`)[0].n, 0);
  if (!proven) console.log("  (the scheduled path was not exercised)");
});
