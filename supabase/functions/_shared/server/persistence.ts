// Between the engine and the database.
//
// The engine (../trading) is pure: it changes one in-memory `TradingState`. This module
// makes that durable and atomic. Every piece of work for one person follows the same path,
// inside ONE database transaction:
//
//   lock the person → load their state → run the engine → write what changed → commit
//
// so an order, its fill, the ledger change and the audit event are stored together or not
// at all, and two requests for the same person can never interleave. The transaction runs
// as `service_role`, which the migration deliberately does not let rewrite history.
//
// The audit chain is cross-checked on every write: the engine computes each event's hash,
// the database trigger computes it again from the stored row, and a difference aborts the
// transaction.

import postgres from "npm:postgres@3.4.5";
import {
  type AgentRun, agentSpec, strategyVersion, type TradeProposal, type TradingAgent, type TradingSignal,
} from "../trading/agent.ts";
import { type AuditEvent, makeAuditLog, uuidString } from "../trading/audit.ts";
import type { BrokerEnvironment, BrokerPermission } from "../trading/broker.ts";
import { TradingEngine } from "../trading/engine.ts";
import type { EquityPoint, Ledger, Position } from "../trading/ledger.ts";
import { instrumentID } from "../trading/market.ts";
import { type Fill, isOpenStatus, type Order, type OrderSource, type OrderStatus } from "../trading/orders.ts";
import { type EngineNotice, makeState, stateToJSON, TradingError, type TradingState } from "../trading/state.ts";

// deno-lint-ignore no-explicit-any
export type Sql = postgres.Sql<any>;
// deno-lint-ignore no-explicit-any
export type Tx = postgres.TransactionSql<any>;
// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

let shared: Sql | undefined;

/** One small pool per function instance. The address comes from the function's environment. */
export function database(url: string | undefined = Deno.env.get("SUPABASE_DB_URL")): Sql {
  if (shared) return shared;
  if (!url) throw new Error("The database address isn't configured.");
  shared = postgres(url, { max: 2, prepare: false, idle_timeout: 20, connect_timeout: 10, onnotice: () => {} });
  return shared;
}

/** What to load beyond the standing state (accounts, agents, open orders, waiting proposals). */
export interface LoadScope {
  /** Orders to load whatever their status (to cancel one, say). */
  orderIDs?: string[];
  /** Proposals to load whatever their status (to approve or reject one). */
  proposalIDs?: string[];
  /** Client order ids that are about to be used: loaded so a repeat is recognised. */
  clientOrderIDs?: string[];
  /** Agents about to run: their recent signals and fills are loaded so nothing is done twice. */
  agentIDs?: string[];
}

export interface EngineSession {
  engine: TradingEngine;
  tx: Tx;
  userID: string;
  now: number;
}

export interface SessionOutcome<T> {
  /** What the work returned, when it wasn't refused. */
  value?: T;
  /** A refusal the engine raised. What it changed before refusing (an audit event, say) is kept. */
  refusal?: TradingError;
  notices: EngineNotice[];
  auditEvents: AuditEvent[];
  /** The state as saved, when `includeState` was asked for and the work wasn't refused. */
  state?: StateRead;
}

const DEDUPE_WINDOW_MS = 21 * 86_400_000;
const OPEN_STATUSES: OrderStatus[] = ["pendingSubmit", "accepted", "partiallyFilled"];

const ms = (value: Date | null | undefined): number | undefined => value ? value.getTime() : undefined;
const at = (value: number | undefined): Date | null => value === undefined ? null : new Date(value);
const lock = (tx: Tx, userID: string) => tx`select pg_advisory_xact_lock(hashtextextended(${"trading-user:" + userID}, 0))`;
const uuidArray = (ids: string[]): string => `{${ids.join(",")}}`;

function setOptional<T extends object, K extends keyof T>(target: T, key: K, value: T[K] | null | undefined): void {
  if (value !== null && value !== undefined) target[key] = value;
}

function sourceOf(row: Row): OrderSource {
  const source: OrderSource = { kind: row.source_kind };
  setOptional(source, "agentID", row.agent_id);
  setOptional(source, "proposalID", row.proposal_id);
  return source;
}

function orderFromRow(row: Row): Order {
  const order: Order = {
    id: row.id, clientOrderID: row.client_order_id, ledgerID: row.ledger_id, instrument: row.instrument, side: row.side,
    type: row.type, quantity: row.quantity, timeInForce: row.time_in_force, source: sourceOf(row), mode: row.mode,
    status: row.status, filledQuantity: row.filled_quantity, averageFillPrice: row.average_fill_price, fees: row.fees,
    referencePrice: row.reference_price, createdAt: row.created_at.getTime(), updatedAt: row.updated_at.getTime(),
  };
  setOptional(order, "limitPrice", row.limit_price);
  setOptional(order, "stopPrice", row.stop_price);
  setOptional(order, "expiresAt", ms(row.expires_at));
  setOptional(order, "stopTriggeredAt", ms(row.stop_triggered_at));
  setOptional(order, "statusNote", row.status_note);
  setOptional(order, "signalBarTime", ms(row.signal_bar_time));
  setOptional(order, "brokerOrderID", row.broker_order_id);
  return order;
}

function fillFromRow(row: Row): Fill {
  const fill: Fill = {
    id: row.id, orderID: row.order_id, ledgerID: row.ledger_id, instrument: row.instrument, side: row.side,
    quantity: row.quantity, price: row.price, fee: row.fee, time: row.time.getTime(), source: sourceOf(row), mode: row.mode,
  };
  setOptional(fill, "realizedPnL", row.realized_pnl);
  setOptional(fill, "signalBarTime", ms(row.signal_bar_time));
  return fill;
}

function proposalFromRow(row: Row): TradeProposal {
  const proposal: TradeProposal = {
    id: row.id, agentID: row.agent_id, signalID: row.signal_id, strategyVersion: row.strategy_version, ledgerID: row.ledger_id,
    instrument: row.instrument, side: row.side, quantity: row.quantity, referencePrice: row.reference_price, notional: row.notional,
    estimatedFee: row.estimated_fee, mode: row.mode, status: row.status, risk: row.risk, headline: row.headline,
    signalBarTime: row.signal_bar_time.getTime(), createdAt: row.created_at.getTime(), expiresAt: row.expires_at.getTime(),
    clientOrderID: row.client_order_id,
  };
  setOptional(proposal, "sizingNote", row.sizing_note);
  setOptional(proposal, "resolvedAt", ms(row.resolved_at));
  setOptional(proposal, "resolutionNote", row.resolution_note);
  setOptional(proposal, "orderID", row.order_id);
  return proposal;
}

function signalFromRow(row: Row): TradingSignal {
  const signal: TradingSignal = {
    id: row.id, agentID: row.agent_id, strategyVersion: row.strategy_version, instrument: row.instrument, action: row.action,
    headline: row.headline, evidence: row.evidence, barTime: row.bar_time.getTime(), close: row.close,
    createdAt: row.created_at.getTime(), provenance: row.provenance,
  };
  setOptional(signal, "ruleMargin", row.rule_margin);
  setOptional(signal, "exitReason", row.exit_reason);
  return signal;
}

/** What was read, kept so the save can tell what changed. */
interface Loaded {
  ledgers: Map<string, string>;                 // id → JSON of the ledger without its equity history
  ledgerCreatedAt: Map<string, number>;
  positions: Map<string, Map<string, string>>;  // ledger id → instrument id → JSON
  snapshots: Map<string, { id: string; point: EquityPoint }[]>;
  agents: Map<string, string>;
  agentVersions: Map<string, number>;
  proposals: Map<string, string>;
  orders: Map<string, string>;
  fillCounts: Map<string, number>;
  fills: Set<string>;
  signals: Set<string>;
  policy: string;
  auditBase: number;
}

/** Everything about a book except its positions, plus when it was last priced. */
const ledgerJSON = (ledger: Ledger): string =>
  JSON.stringify({ ...ledger, positions: undefined, equityHistory: undefined, marked: ledger.equityHistory[ledger.equityHistory.length - 1]?.time });
const agentJSON = (agent: TradingAgent, notified: string | undefined): string => JSON.stringify({ ...agent, versions: agent.versions.length, notified });

async function load(tx: Tx, userID: string, now: number, allowFixtureData: boolean, scope: LoadScope): Promise<{ state: TradingState; loaded: Loaded }> {
  const state = makeState();
  const loaded: Loaded = {
    ledgers: new Map(), ledgerCreatedAt: new Map(), positions: new Map(), snapshots: new Map(), agents: new Map(),
    agentVersions: new Map(), proposals: new Map(), orders: new Map(), fillCounts: new Map(), fills: new Set(), signals: new Set(),
    policy: "", auditBase: 0,
  };

  await tx`insert into public.risk_policies (user_id) values (${userID}) on conflict (user_id) do nothing`;
  const [policy] = await tx`select * from public.risk_policies where user_id = ${userID}`;
  state.accountPolicy = {
    killSwitchEngaged: policy.kill_switch_engaged,
    maxSymbolExposurePct: policy.max_symbol_exposure_pct,
    maxTotalDailyNotional: policy.max_total_daily_notional,
    live: {
      manualOrdersEnabled: policy.live_manual_orders_enabled,
      approvalAgentsEnabled: policy.live_approval_agents_enabled,
      autonomousAgentsEnabled: policy.live_autonomous_agents_enabled,
    },
    // Never stored: fixtures are allowed only by the function's own test-only environment flag.
    allowFixtureData,
  };
  setOptional(state.accountPolicy, "killSwitchAt", ms(policy.kill_switch_at));
  loaded.policy = JSON.stringify(state.accountPolicy);

  for (const row of await tx`select * from public.broker_connections where user_id = ${userID} order by seq`) {
    state.connections.push({
      id: row.id, adapterID: row.adapter_id, name: row.name, environment: row.environment as BrokerEnvironment,
      permissions: row.permissions as BrokerPermission[], createdAt: row.created_at.getTime(),
    });
  }

  const positionRows = await tx`select * from public.positions where user_id = ${userID} order by seq`;
  const snapshotRows = await tx`
    select id, ledger_id, time, equity, cash from (
      select s.*, row_number() over (partition by ledger_id order by seq desc) as rn
      from public.trading_portfolio_snapshots s where user_id = ${userID}
    ) recent where rn <= 2 order by seq`;
  for (const row of await tx`select * from public.trading_accounts where user_id = ${userID} and deleted_at is null order by seq`) {
    const positions: Position[] = positionRows.filter((p) => p.ledger_id === row.id).map((p) => {
      const position: Position = {
        instrument: p.instrument, quantity: p.quantity, costBasis: p.cost_basis, openedAt: p.opened_at.getTime(), lastPrice: p.last_price,
      };
      setOptional(position, "lastPriceTime", ms(p.last_price_time));
      return position;
    });
    const tail = snapshotRows.filter((s) => s.ledger_id === row.id)
      .map((s) => ({ id: s.id as string, point: { time: s.time.getTime(), equity: s.equity, cash: s.cash } as EquityPoint }));
    const ledger: Ledger = {
      id: row.id, name: row.name, kind: row.kind, mode: row.mode, currency: row.currency, startingCash: row.starting_cash,
      cash: row.cash, positions, realizedPnL: row.realized_pnl, feesPaid: row.fees_paid, createdAt: row.created_at.getTime(),
      equityHistory: tail.map((entry) => entry.point), peakEquity: row.peak_equity, dayKey: row.day_key,
      dayStartEquity: row.day_start_equity, realizedToday: row.realized_today, notionalToday: row.notional_today,
      lastFillAt: row.last_fill_at, lastBuyAt: row.last_buy_at, lastExitAt: row.last_exit_at,
    };
    setOptional(ledger, "agentID", row.agent_id);
    state.ledgers.push(ledger);
    loaded.ledgers.set(ledger.id, ledgerJSON(ledger));
    loaded.ledgerCreatedAt.set(ledger.id, ledger.createdAt);
    loaded.positions.set(ledger.id, new Map(positions.map((p) => [instrumentID(p.instrument), JSON.stringify(p)])));
    loaded.snapshots.set(ledger.id, tail);
  }

  const versionRows = await tx`
    select v.* from public.agent_strategy_versions v
    join public.trading_agents a on a.id = v.agent_id and a.strategy_version = v.version
    where a.user_id = ${userID} and a.deleted_at is null`;
  for (const row of await tx`select * from public.trading_agents where user_id = ${userID} and deleted_at is null order by seq`) {
    const version = versionRows.find((v) => v.agent_id === row.id);
    if (!version) throw new Error(`Agent ${row.id} has no stored strategy version ${row.strategy_version}.`);
    const agent: TradingAgent = {
      id: row.id, name: row.name, mode: row.mode, status: row.status,
      versions: [{ version: version.version, spec: version.spec, createdAt: version.created_at.getTime(), note: version.note, author: version.author }],
      riskPolicy: row.risk_policy, budget: row.budget, reviewEachPaperTrade: row.review_each_paper_trade,
      schedule: { intervalMinutes: row.schedule_interval_minutes }, createdAt: row.created_at.getTime(), consecutiveErrors: row.consecutive_errors,
    };
    setOptional(agent, "templateID", row.template_id);
    setOptional(agent, "pauseReason", row.pause_reason);
    setOptional(agent, "ledgerID", row.ledger_id);
    setOptional(agent, "lastRunAt", ms(row.last_run_at));
    setOptional(agent, "nextRunAt", ms(row.next_run_at));
    setOptional(agent, "lastError", row.last_error);
    if (row.daily_loss_notified_day) state.dailyLossNotified[uuidString(agent.id)] = row.daily_loss_notified_day;
    state.agents.push(agent);
    loaded.agents.set(agent.id, agentJSON(agent, state.dailyLossNotified[uuidString(agent.id)]));
    loaded.agentVersions.set(agent.id, version.version);
  }

  const wantedOrders = scope.orderIDs ?? [];
  const orderRows = wantedOrders.length > 0
    ? await tx`select * from public.orders where user_id = ${userID} and (status in ${tx(OPEN_STATUSES)} or id in ${tx(wantedOrders)}) order by seq`
    : await tx`select * from public.orders where user_id = ${userID} and status in ${tx(OPEN_STATUSES)} order by seq`;
  for (const row of orderRows) {
    const order = orderFromRow(row);
    state.orders.push(order);
    loaded.orders.set(order.id, JSON.stringify(order));
  }
  if (orderRows.length > 0) {
    for (const row of await tx`select order_id, count(*)::int as n from public.order_fills where order_id in ${tx(orderRows.map((o) => o.id))} group by order_id`) {
      loaded.fillCounts.set(row.order_id, row.n);
    }
  }

  const wantedProposals = scope.proposalIDs ?? [];
  const proposalRows = wantedProposals.length > 0
    ? await tx`select * from public.trade_proposals where user_id = ${userID} and (status = 'pending' or id in ${tx(wantedProposals)}) order by seq`
    : await tx`select * from public.trade_proposals where user_id = ${userID} and status = 'pending' order by seq`;
  for (const row of proposalRows) {
    const proposal = proposalFromRow(row);
    state.proposals.push(proposal);
    loaded.proposals.set(proposal.id, JSON.stringify(proposal));
  }

  // What an agent has lately signalled and traded, so a re-run on the same bar repeats nothing.
  const agents = scope.agentIDs ?? [];
  if (agents.length > 0) {
    const since = new Date(now - DEDUPE_WINDOW_MS);
    for (const row of await tx`select * from public.trading_signals where user_id = ${userID} and agent_id in ${tx(agents)} and bar_time >= ${since} order by seq`) {
      state.signals.push(signalFromRow(row));
      loaded.signals.add(row.id);
    }
    for (const row of await tx`select * from public.order_fills where user_id = ${userID} and agent_id in ${tx(agents)} and signal_bar_time >= ${since} order by seq`) {
      state.fills.push(fillFromRow(row));
      loaded.fills.add(row.id);
    }
  }

  // Every recorded order's id counts as used — refused ones too. (The Swift core only
  // remembers accepted ids; the database's unique key, and the rule that an order is never
  // placed twice, need the stricter reading.)
  const candidates = [...(scope.clientOrderIDs ?? []), ...state.proposals.map((p) => p.clientOrderID)];
  if (candidates.length > 0) {
    for (const row of await tx`select client_order_id from public.orders where user_id = ${userID} and client_order_id in ${tx(candidates)}`) {
      state.knownClientOrderIDs.add(row.client_order_id);
    }
  }

  const [last] = await tx`select sequence, hash from public.audit_events where user_id = ${userID} order by sequence desc limit 1`;
  state.audit = last ? makeAuditLog(last.hash, Number(last.sequence)) : makeAuditLog();
  loaded.auditBase = state.audit.baseSequence;
  return { state, loaded };
}

// MARK: - The whole state, for the app

/**
 * How much history a `state` read returns. Open orders and waiting proposals always come
 * back whatever their age; equity history follows the core's own cap (Ledger.recordEquity).
 */
export const STATE_WINDOW = { runs: 200, signals: 400, proposals: 500, orders: 1_000, fills: 2_000, audit: 500, equityPoints: 3_000 } as const;

export interface StateRead {
  /** The person's trading state as Swift's `TradingCodec` writes `TradingState`. */
  state: Record<string, unknown>;
  /** When it was read (ms since 1970). */
  asOf: number;
  /** Which histories had more than the window returned. */
  truncated: { runs: boolean; signals: boolean; proposals: boolean; orders: boolean; fills: boolean; audit: boolean };
}

function runFromRow(row: Row): AgentRun {
  const ids = (value: unknown): string[] => Array.isArray(value)
    ? value.map(String)
    : String(value ?? "{}").replace(/^\{|\}$/g, "").split(",").filter((id) => id !== "");
  return {
    id: row.id, agentID: row.agent_id, strategyVersion: row.strategy_version, trigger: row.trigger, startedAt: row.started_at.getTime(),
    finishedAt: row.finished_at.getTime(), status: row.status, summary: row.summary, steps: row.steps,
    signalIDs: ids(row.signal_ids), proposalIDs: ids(row.proposal_ids), orderIDs: ids(row.order_ids),
  };
}

function auditFromRow(row: Row): AuditEvent {
  const event: AuditEvent = {
    // The hash covers the time to the millisecond, rounded; a JavaScript Date would truncate a stored half-millisecond.
    id: row.id, sequence: Number(row.sequence), time: Number(row.time_ms), actor: row.actor, kind: row.kind, summary: row.summary,
    details: row.details, previousHash: row.previous_hash, hash: row.hash,
  };
  setOptional(event, "mode", row.mode);
  setOptional(event, "agentID", row.agent_id);
  setOptional(event, "ledgerID", row.ledger_id);
  setOptional(event, "orderID", row.order_id);
  setOptional(event, "proposalID", row.proposal_id);
  setOptional(event, "instrumentID", row.instrument_id);
  return event;
}

/** The newest `limit` rows (fetching one more says whether there were more), oldest first. */
async function newest(rows: Promise<Row[]>, limit: number): Promise<{ rows: Row[]; truncated: boolean }> {
  const fetched = await rows;
  return { rows: fetched.slice(0, limit).reverse(), truncated: fetched.length > limit };
}

/**
 * A person's whole trading state, with bounded history, in the shape Swift's
 * `TradingCodec.decoder()` decodes into `TradingState`. Run it inside a transaction that
 * holds the person's lock (or that just saved), so every part comes from the same moment.
 */
export async function readState(tx: Tx, userID: string, now: number, allowFixtureData: boolean): Promise<StateRead> {
  const { state } = await load(tx, userID, now, allowFixtureData, {});
  // Live trading doesn't exist in this build, whatever a row says (the database refuses it too).
  state.accountPolicy.live = { manualOrdersEnabled: false, approvalAgentsEnabled: false, autonomousAgentsEnabled: false };
  state.accountPolicy.allowFixtureData = allowFixtureData;

  // Equity history up to the core's cap, and every strategy version of every agent.
  if (state.ledgers.length > 0) {
    const points = await tx`
      select ledger_id, time, equity, cash from (
        select s.*, row_number() over (partition by ledger_id order by seq desc) as rn
        from public.trading_portfolio_snapshots s where user_id = ${userID} and ledger_id in ${tx(state.ledgers.map((l) => l.id))}
      ) recent where rn <= ${STATE_WINDOW.equityPoints} order by seq`;
    for (const ledger of state.ledgers) {
      ledger.equityHistory = points.filter((p) => p.ledger_id === ledger.id).map((p) => ({ time: p.time.getTime(), equity: p.equity, cash: p.cash }));
    }
  }
  if (state.agents.length > 0) {
    const versions = await tx`select * from public.agent_strategy_versions where agent_id in ${tx(state.agents.map((a) => a.id))} order by agent_id, version`;
    for (const agent of state.agents) {
      const own = versions.filter((v) => v.agent_id === agent.id);
      if (own.length > 0) {
        agent.versions = own.map((v) => ({ version: v.version, spec: v.spec, createdAt: v.created_at.getTime(), note: v.note, author: v.author }));
      }
    }
  }

  // History, newest first in the query, oldest first in the state.
  const w = STATE_WINDOW;
  const orders = await newest(tx`select * from public.orders where user_id = ${userID} order by seq desc limit ${w.orders + 1}`, w.orders);
  const proposals = await newest(tx`select * from public.trade_proposals where user_id = ${userID} order by seq desc limit ${w.proposals + 1}`, w.proposals);
  const signals = await newest(tx`select * from public.trading_signals where user_id = ${userID} order by seq desc limit ${w.signals + 1}`, w.signals);
  const fills = await newest(tx`select * from public.order_fills where user_id = ${userID} order by seq desc limit ${w.fills + 1}`, w.fills);
  const runs = await newest(tx`select * from public.agent_runs where user_id = ${userID} order by seq desc limit ${w.runs + 1}`, w.runs);
  const audit = await newest(tx`
    select *, round(extract(epoch from time) * 1000)::float8 as time_ms
    from public.audit_events where user_id = ${userID} order by sequence desc limit ${w.audit + 1}`, w.audit);

  // Open orders and waiting proposals always come back, however old (the loader already has them).
  const openOrders = state.orders.filter((o) => !orders.rows.some((row) => row.id === o.id));
  const pendingProposals = state.proposals.filter((p) => !proposals.rows.some((row) => row.id === p.id));
  state.orders = [...openOrders, ...orders.rows.map(orderFromRow)];
  state.proposals = [...pendingProposals, ...proposals.rows.map(proposalFromRow)];
  state.signals = signals.rows.map(signalFromRow);
  state.fills = fills.rows.map(fillFromRow);
  state.runs = runs.rows.map(runFromRow);

  // The newest audit events, continuing from the event just before them, so
  // AuditLog.verify() checks the window: events ascend by sequence, and baseSequence is the
  // sequence before the first one (0 when the window starts at the beginning).
  const events = audit.rows.map(auditFromRow);
  state.audit = events.length > 0 ? { events, baseHash: events[0].previousHash, baseSequence: events[0].sequence - 1 } : makeAuditLog();

  // The real idempotency record stays on the server; these are the ids of the orders returned.
  state.knownClientOrderIDs = new Set(state.orders.map((o) => o.clientOrderID));
  // Quotes and liquidity figures aren't stored: the app prices what it shows itself.
  state.quotes = {};
  state.stats = {};

  return {
    state: stateToJSON(state), asOf: now,
    truncated: {
      runs: runs.truncated, signals: signals.truncated, proposals: proposals.truncated, orders: orders.truncated,
      fills: fills.truncated, audit: audit.truncated,
    },
  };
}

/** `readState` in its own transaction, holding the person's lock so no write is half-seen. */
export async function readStateSnapshot(sql: Sql, userID: string, now: number, allowFixtureData: boolean): Promise<StateRead> {
  return await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    await lock(tx, userID);
    return await readState(tx, userID, now, allowFixtureData);
  }) as StateRead;
}

async function save(tx: Tx, userID: string, now: number, engine: TradingEngine, loaded: Loaded): Promise<{ notices: EngineNotice[]; auditEvents: AuditEvent[] }> {
  const state = engine.state;
  const when = new Date(now);

  // 1. The kill switch. (Live flags are never written: nothing in this build can set them.)
  if (JSON.stringify(state.accountPolicy) !== loaded.policy) {
    await tx`update public.risk_policies set kill_switch_engaged = ${state.accountPolicy.killSwitchEngaged},
               kill_switch_at = ${at(state.accountPolicy.killSwitchAt)} where user_id = ${userID}`;
  }

  // 2. Books: new, changed, and removed (kept, but no longer shown).
  for (const ledger of state.ledgers) {
    const marked = ledger.equityHistory.length > 0 ? new Date(ledger.equityHistory[ledger.equityHistory.length - 1].time) : null;
    const before = loaded.ledgers.get(ledger.id);
    if (before === undefined) {
      await tx`insert into public.trading_accounts ${tx({
        id: ledger.id, user_id: userID, name: ledger.name, kind: ledger.kind, mode: ledger.mode, currency: ledger.currency,
        agent_id: ledger.agentID ?? null, starting_cash: ledger.startingCash, cash: ledger.cash, realized_pnl: ledger.realizedPnL,
        fees_paid: ledger.feesPaid, peak_equity: ledger.peakEquity, day_key: ledger.dayKey, day_start_equity: ledger.dayStartEquity,
        realized_today: ledger.realizedToday, notional_today: ledger.notionalToday, last_fill_at: tx.json(ledger.lastFillAt as never),
        last_buy_at: tx.json(ledger.lastBuyAt as never), last_exit_at: tx.json(ledger.lastExitAt as never), created_at: new Date(ledger.createdAt),
        marked_at: marked,
      })}`;
    } else if (before !== ledgerJSON(ledger)) {
      await tx`update public.trading_accounts set ${tx({
        name: ledger.name, mode: ledger.mode, cash: ledger.cash, starting_cash: ledger.startingCash, realized_pnl: ledger.realizedPnL,
        fees_paid: ledger.feesPaid, peak_equity: ledger.peakEquity, day_key: ledger.dayKey, day_start_equity: ledger.dayStartEquity,
        realized_today: ledger.realizedToday, notional_today: ledger.notionalToday, last_fill_at: tx.json(ledger.lastFillAt as never),
        last_buy_at: tx.json(ledger.lastBuyAt as never), last_exit_at: tx.json(ledger.lastExitAt as never), created_at: new Date(ledger.createdAt),
        marked_at: marked,
      })} where id = ${ledger.id} and user_id = ${userID}`;
    }

    // Positions: a closed one is removed; one closed and reopened is a new row.
    const held = loaded.positions.get(ledger.id) ?? new Map<string, string>();
    const reset = loaded.ledgerCreatedAt.has(ledger.id) && loaded.ledgerCreatedAt.get(ledger.id) !== ledger.createdAt;
    const current = new Set(ledger.positions.map((p) => instrumentID(p.instrument)));
    for (const [id, json] of held) {
      const now_ = ledger.positions.find((p) => instrumentID(p.instrument) === id);
      const reopened = now_ !== undefined && (JSON.parse(json) as Position).openedAt !== now_.openedAt;
      if (!current.has(id) || reopened || reset) {
        await tx`delete from public.positions where ledger_id = ${ledger.id} and instrument_id = ${id}`;
        held.delete(id);
      }
    }
    for (const position of ledger.positions) {
      const id = instrumentID(position.instrument);
      const before_ = held.get(id);
      const values = {
        quantity: position.quantity, cost_basis: position.costBasis, opened_at: new Date(position.openedAt),
        last_price: position.lastPrice, last_price_time: at(position.lastPriceTime),
      };
      if (before_ === undefined) {
        await tx`insert into public.positions ${tx({ user_id: userID, ledger_id: ledger.id, instrument_id: id, instrument: tx.json(position.instrument as never), ...values })}`;
      } else if (before_ !== JSON.stringify(position)) {
        await tx`update public.positions set ${tx(values)} where ledger_id = ${ledger.id} and instrument_id = ${id}`;
      }
    }

    // Equity points: the engine replaces the latest point within the hour, or adds one.
    const tail = reset ? [] : (loaded.snapshots.get(ledger.id) ?? []);
    if (reset) await tx`delete from public.trading_portfolio_snapshots where ledger_id = ${ledger.id}`;
    for (let i = 0; i < ledger.equityHistory.length; i++) {
      const point = ledger.equityHistory[i];
      if (i < tail.length) {
        if (tail[i].point !== point) {
          await tx`update public.trading_portfolio_snapshots set time = ${new Date(point.time)}, equity = ${point.equity}, cash = ${point.cash} where id = ${tail[i].id}`;
        }
      } else {
        await tx`insert into public.trading_portfolio_snapshots ${tx({ user_id: userID, ledger_id: ledger.id, time: new Date(point.time), equity: point.equity, cash: point.cash })}`;
      }
    }
  }
  for (const id of loaded.ledgers.keys()) {
    if (!state.ledgers.some((l) => l.id === id)) {
      await tx`update public.trading_accounts set deleted_at = ${when} where id = ${id} and user_id = ${userID}`;
    }
  }

  // 3. Agents and any new strategy versions.
  for (const agent of state.agents) {
    const notified = state.dailyLossNotified[uuidString(agent.id)];
    const values = {
      name: agent.name, template_id: agent.templateID ?? null, mode: agent.mode, status: agent.status,
      pause_reason: agent.pauseReason ?? null, risk_policy: tx.json(agent.riskPolicy as never), ledger_id: agent.ledgerID ?? null,
      budget: agent.budget, review_each_paper_trade: agent.reviewEachPaperTrade, schedule_interval_minutes: agent.schedule.intervalMinutes,
      strategy_version: strategyVersion(agent), last_run_at: at(agent.lastRunAt), next_run_at: at(agent.nextRunAt),
      consecutive_errors: agent.consecutiveErrors, last_error: agent.lastError ?? null, daily_loss_notified_day: notified ?? null,
    };
    const before = loaded.agents.get(agent.id);
    if (before === undefined) {
      await tx`insert into public.trading_agents ${tx({ id: agent.id, user_id: userID, created_at: new Date(agent.createdAt), ...values })}`;
    } else if (before !== agentJSON(agent, notified)) {
      await tx`update public.trading_agents set ${tx(values)} where id = ${agent.id} and user_id = ${userID}`;
    }
    const stored = loaded.agentVersions.get(agent.id) ?? 0;
    for (const version of agent.versions) {
      if (version.version <= stored) continue;
      await tx`insert into public.agent_strategy_versions ${tx({
        user_id: userID, agent_id: agent.id, version: version.version, spec: tx.json(version.spec as never), note: version.note,
        author: version.author, created_at: new Date(version.createdAt),
      })}`;
    }
  }
  for (const id of loaded.agents.keys()) {
    if (!state.agents.some((a) => a.id === id)) {
      await tx`update public.trading_agents set deleted_at = ${when}, status = 'stopped', locked_until = null, locked_by = null
               where id = ${id} and user_id = ${userID}`;
    }
  }

  // 4. Signals.
  for (const signal of state.signals) {
    if (loaded.signals.has(signal.id)) continue;
    await tx`insert into public.trading_signals ${tx({
      id: signal.id, user_id: userID, agent_id: signal.agentID, strategy_version: signal.strategyVersion,
      instrument_id: instrumentID(signal.instrument), instrument: tx.json(signal.instrument as never), action: signal.action,
      headline: signal.headline, evidence: tx.json(signal.evidence as never), bar_time: new Date(signal.barTime), close: signal.close,
      rule_margin: signal.ruleMargin ?? null, exit_reason: signal.exitReason ?? null, created_at: new Date(signal.createdAt),
      provenance: tx.json(signal.provenance as never),
    })}`;
  }

  // 5. Proposals: resolve the ones that were waiting before adding new ones (an agent may
  //    have only one waiting per instrument and side).
  const proposalValues = (p: TradeProposal) => ({
    status: p.status, risk: tx.json(p.risk as never), estimated_fee: p.estimatedFee, resolved_at: at(p.resolvedAt),
    resolution_note: p.resolutionNote ?? null, order_id: p.orderID ?? null,
  });
  for (const proposal of state.proposals) {
    const before = loaded.proposals.get(proposal.id);
    if (before !== undefined && before !== JSON.stringify(proposal)) {
      await tx`update public.trade_proposals set ${tx(proposalValues(proposal))} where id = ${proposal.id} and user_id = ${userID}`;
    }
  }
  for (const proposal of state.proposals) {
    if (loaded.proposals.has(proposal.id)) continue;
    await tx`insert into public.trade_proposals ${tx({
      id: proposal.id, user_id: userID, agent_id: proposal.agentID, signal_id: proposal.signalID, strategy_version: proposal.strategyVersion,
      ledger_id: proposal.ledgerID, instrument_id: instrumentID(proposal.instrument), instrument: tx.json(proposal.instrument as never),
      side: proposal.side, quantity: proposal.quantity, reference_price: proposal.referencePrice, notional: proposal.notional,
      mode: proposal.mode, headline: proposal.headline, sizing_note: proposal.sizingNote ?? null,
      signal_bar_time: new Date(proposal.signalBarTime), created_at: new Date(proposal.createdAt), expires_at: new Date(proposal.expiresAt),
      client_order_id: proposal.clientOrderID, ...proposalValues(proposal),
    })}`;
  }

  // 6. Orders. A new order is written as it was first recorded (working or refused) and
  //    then moved to where it ended up, so the database's state machine sees a real move.
  const orderProgress = (o: Order) => ({
    status: o.status, filled_quantity: o.filledQuantity, average_fill_price: o.averageFillPrice, fees: o.fees,
    updated_at: new Date(o.updatedAt), stop_triggered_at: at(o.stopTriggeredAt), status_note: o.statusNote ?? null,
  });
  for (const order of state.orders) {
    const before = loaded.orders.get(order.id);
    if (before === undefined) {
      const initial: OrderStatus = order.status === "rejected" ? "rejected" : "accepted";
      await tx`insert into public.orders ${tx({
        id: order.id, user_id: userID, client_order_id: order.clientOrderID, ledger_id: order.ledgerID,
        instrument_id: instrumentID(order.instrument), instrument: tx.json(order.instrument as never), side: order.side, type: order.type,
        quantity: order.quantity, limit_price: order.limitPrice ?? null, stop_price: order.stopPrice ?? null,
        time_in_force: order.timeInForce, source_kind: order.source.kind, agent_id: order.source.agentID ?? null,
        proposal_id: order.source.proposalID ?? null, mode: order.mode, status: initial, filled_quantity: 0, average_fill_price: 0,
        fees: 0, reference_price: order.referencePrice, created_at: new Date(order.createdAt), updated_at: new Date(order.createdAt),
        expires_at: at(order.expiresAt), stop_triggered_at: null, status_note: initial === "rejected" ? (order.statusNote ?? null) : null,
        signal_bar_time: at(order.signalBarTime), broker_order_id: null,
      })}`;
      const untouched = order.status === initial && order.filledQuantity === 0 && order.statusNote === undefined &&
        order.stopTriggeredAt === undefined && order.updatedAt === order.createdAt;
      if (initial !== "rejected" && !untouched) {
        await tx`update public.orders set ${tx(orderProgress(order))} where id = ${order.id} and user_id = ${userID}`;
      }
    } else if (before !== JSON.stringify(order)) {
      await tx`update public.orders set ${tx(orderProgress(order))} where id = ${order.id} and user_id = ${userID}`;
    }
  }

  // 7. Fills, numbered per order so a repeat can't be booked twice.
  const fillNumbers = new Map(loaded.fillCounts);
  for (const fill of state.fills) {
    if (loaded.fills.has(fill.id)) continue;
    const n = (fillNumbers.get(fill.orderID) ?? 0) + 1;
    fillNumbers.set(fill.orderID, n);
    await tx`insert into public.order_fills ${tx({
      id: fill.id, user_id: userID, order_id: fill.orderID, fill_no: n, ledger_id: fill.ledgerID,
      instrument_id: instrumentID(fill.instrument), instrument: tx.json(fill.instrument as never), side: fill.side, quantity: fill.quantity,
      price: fill.price, fee: fill.fee, time: new Date(fill.time), source_kind: fill.source.kind, agent_id: fill.source.agentID ?? null,
      proposal_id: fill.source.proposalID ?? null, mode: fill.mode, realized_pnl: fill.realizedPnL ?? null,
      signal_bar_time: at(fill.signalBarTime),
    })}`;
  }

  // 8. Run traces.
  for (const run of state.runs) await insertRun(tx, userID, run);

  // 9. The audit trail. The database works out each event's place and hash again; they
  //    must agree with what the engine computed.
  const auditEvents = state.audit.events.filter((event) => event.sequence > loaded.auditBase);
  for (const event of auditEvents) {
    const [stored] = await tx`insert into public.audit_events ${tx({
      id: event.id, user_id: userID, time: new Date(event.time), actor: event.actor, kind: event.kind, summary: event.summary,
      mode: event.mode ?? null, agent_id: event.agentID ?? null, ledger_id: event.ledgerID ?? null, order_id: event.orderID ?? null,
      proposal_id: event.proposalID ?? null, instrument_id: event.instrumentID ?? null, details: tx.json(event.details as never),
    })} returning sequence, hash`;
    if (Number(stored.sequence) !== event.sequence || stored.hash !== event.hash) {
      throw new Error(`The audit chain disagrees at event ${event.sequence}: the engine and the database computed different hashes.`);
    }
  }

  // 10. Things to tell the person.
  const notices = engine.drainNotices();
  for (const notice of notices) {
    await tx`insert into public.agent_events ${tx({
      user_id: userID, kind: notice.kind, title: notice.title, body: notice.body, mode: notice.mode, agent_id: notice.agentID ?? null,
      order_id: notice.orderID ?? null, proposal_id: notice.proposalID ?? null, instrument_id: notice.instrumentID ?? null, created_at: when,
    })}`;
  }
  return { notices, auditEvents };
}

async function insertRun(tx: Tx, userID: string, run: AgentRun): Promise<void> {
  await tx`insert into public.agent_runs (id, user_id, agent_id, strategy_version, trigger, started_at, finished_at, status, summary,
                                          steps, signal_ids, proposal_ids, order_ids)
           values (${run.id}, ${userID}, ${run.agentID}, ${run.strategyVersion}, ${run.trigger}, ${new Date(run.startedAt)},
                   ${new Date(run.finishedAt)}, ${run.status}, ${run.summary}, ${tx.json(run.steps as never)},
                   ${uuidArray(run.signalIDs)}::uuid[], ${uuidArray(run.proposalIDs)}::uuid[], ${uuidArray(run.orderIDs)}::uuid[])`;
}

/**
 * Runs `work` for one person inside one transaction. A `TradingError` from the engine is a
 * refusal: whatever it changed first (an audit event, an expired proposal) is still saved,
 * and the refusal is returned. Any other error rolls everything back.
 */
export async function withEngine<T>(
  sql: Sql, userID: string, now: number,
  options: { allowFixtureData: boolean; scope?: LoadScope; readOnly?: boolean; includeState?: boolean },
  work: (session: EngineSession) => Promise<T> | T,
): Promise<SessionOutcome<T>> {
  return await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    await lock(tx, userID);
    const { state, loaded } = await load(tx, userID, now, options.allowFixtureData, options.scope ?? {});
    const engine = new TradingEngine(state);
    const outcome: SessionOutcome<T> = { notices: [], auditEvents: [] };
    try {
      outcome.value = await work({ engine, tx, userID, now });
    } catch (error) {
      if (!(error instanceof TradingError)) throw error;
      outcome.refusal = error;
    }
    // A preview looks and changes nothing: whatever the engine did in memory is dropped.
    if (options.readOnly) return outcome;
    const saved = await save(tx, userID, now, engine, loaded);
    outcome.notices = saved.notices;
    outcome.auditEvents = saved.auditEvents;
    // Read back from the tables just written, in the same transaction: exactly what was saved.
    if (options.includeState && !outcome.refusal) outcome.state = await readState(tx, userID, now, options.allowFixtureData);
    return outcome;
  }) as SessionOutcome<T>;
}

/** Instruments a person's open orders, holdings and waiting proposals need prices for. */
export async function instrumentsNeedingQuotes(sql: Sql, userID: string): Promise<Row[]> {
  return await sql`
    select distinct on (instrument_id) instrument_id, instrument from (
      select instrument_id, instrument from public.orders where user_id = ${userID} and status in ${sql(OPEN_STATUSES)} and mode = 'paper'
      union all
      select p.instrument_id, p.instrument from public.positions p join public.trading_accounts a on a.id = p.ledger_id
        where p.user_id = ${userID} and a.deleted_at is null
      union all
      select instrument_id, instrument from public.trade_proposals where user_id = ${userID} and status = 'pending'
    ) needed`;
}

export { agentSpec, isOpenStatus };
