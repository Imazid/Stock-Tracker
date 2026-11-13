// trading-api — the only way a signed-in person changes trading state.
//
// POST a JSON object { "action": "...", ... } with the person's access token. The user id
// is taken from that token (checked with the auth server), never from the body. Each
// action runs as one database transaction through the engine: validation and the risk
// engine can't be skipped, and an order, its fill, the ledger change and the audit event
// are stored together or not at all.
//
// Only paper (simulated) execution exists. A request for anything live is refused with the
// reasons and recorded as `liveRequestRefused`; nothing here calls a broker. No language
// model is consulted anywhere in this function.
//
// Environment (function secrets; never logged or returned):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_DB_URL   provided by Supabase
//   ALPACA_DATA_KEY_ID, ALPACA_DATA_SECRET             market data (read-only prices)
//   COINGECKO_API_KEY                                  optional, market-wide crypto volume
//   TRADING_ALLOW_FIXTURE_DATA                         "1" only in test deployments

import { providerFromEnv } from "../_shared/market/index.ts";
import { authenticate, type Caller, requireStepUp } from "../_shared/server/auth.ts";
import { errorResponse, Field, HttpError, logEvent, ok, readJSONObject, refusal, tradingErrorStatus } from "../_shared/server/http.ts";
import { database, type EngineSession, instrumentsNeedingQuotes, type LoadScope, type Sql, withEngine } from "../_shared/server/persistence.ts";
import { isLoosening } from "../_shared/server/policy.ts";
import { assertPriced, latestQuotes, marketForOrder, type MarketSource, marketSnapshot } from "../_shared/server/runner.ts";
import { AGENT_MODES, type AgentMode, agentSpec, CHANGE_AUTHORS, modeIsLive } from "../_shared/trading/agent.ts";
import { appendAudit } from "../_shared/trading/audit.ts";
import { LiveVenues, PaperBroker } from "../_shared/trading/broker.ts";
import { Currencies } from "../_shared/trading/currencies.ts";
import { decodeInstrument, type Instrument, instrumentID, VENUES } from "../_shared/trading/market.ts";
import { ORDER_SIDES, ORDER_TYPES, type OrderRequest, TIMES_IN_FORCE } from "../_shared/trading/orders.ts";
import { reportSummary, type RiskPolicy } from "../_shared/trading/risk.ts";
import { type AgentDraft, type OrderResult, TradingError } from "../_shared/trading/state.ts";
import { barsToFetch, decodeStrategySpec, type StrategySpec } from "../_shared/trading/strategy.ts";

interface Context {
  sql: Sql;
  caller: Caller;
  body: Record<string, unknown>;
  now: number;
  market: MarketSource;
  idempotencyKey?: string;
}

const env = (name: string) => Deno.env.get(name);

// MARK: - Decoding what the caller sent

function strategy(raw: unknown): StrategySpec {
  try {
    return decodeStrategySpec(raw);
  } catch (error) {
    throw new HttpError(422, "invalid", error instanceof Error ? error.message : "The strategy couldn't be read.");
  }
}

function instrument(raw: unknown): Instrument {
  try {
    return decodeInstrument(raw);
  } catch (error) {
    throw new HttpError(422, "invalid", error instanceof Error ? error.message : "The asset couldn't be read.");
  }
}

const POLICY_NUMBERS: (keyof RiskPolicy)[] = ["maxOrderNotional", "maxPositionPct", "maxDailyNotional", "maxDailyLossPct", "maxDrawdownPct",
  "maxOpenPositions", "maxSpreadBps", "maxQuoteAgeSeconds", "minAverageDollarVolume", "maxDailyVolatilityPct", "cooldownSeconds", "maxPriceGapPct"];

function riskPolicy(raw: unknown): RiskPolicy {
  const o = Field.object(raw, "policy");
  const policy: Record<string, unknown> = { allowQueueOutsideHours: Field.boolean(o.allowQueueOutsideHours, "policy.allowQueueOutsideHours") };
  for (const key of POLICY_NUMBERS) policy[key] = Field.number(o[key], `policy.${key}`);
  return policy as unknown as RiskPolicy;
}

function agentDraft(raw: unknown): AgentDraft {
  const o = Field.object(raw, "draft");
  const schedule = o.schedule === undefined || o.schedule === null ? { intervalMinutes: 60 } : { intervalMinutes: Field.integer(Field.object(o.schedule, "draft.schedule").intervalMinutes, "draft.schedule.intervalMinutes") };
  const draft: AgentDraft = {
    name: Field.string(o.name, "draft.name"),
    mode: o.mode === undefined ? "paper" : Field.oneOf(o.mode, AGENT_MODES, "draft.mode"),
    spec: strategy(o.spec),
    budget: o.budget === undefined ? 10_000 : Field.number(o.budget, "draft.budget"),
    maxPositionPct: o.maxPositionPct === undefined ? 10 : Field.number(o.maxPositionPct, "draft.maxPositionPct"),
    reviewEachPaperTrade: o.reviewEachPaperTrade === undefined ? false : Field.boolean(o.reviewEachPaperTrade, "draft.reviewEachPaperTrade"),
    schedule,
    author: o.author === undefined ? "user" : Field.oneOf(o.author, CHANGE_AUTHORS, "draft.author"),
  };
  const templateID = Field.optionalString(o.templateID, "draft.templateID", 64);
  if (templateID !== undefined) draft.templateID = templateID;
  if (o.riskPolicy !== undefined && o.riskPolicy !== null) draft.riskPolicy = riskPolicy(o.riskPolicy);
  const attach = Field.optionalUUID(o.attachToLedgerID, "draft.attachToLedgerID");
  if (attach !== undefined) draft.attachToLedgerID = attach;
  return draft;
}

function orderRequest(raw: unknown, needsClientID: boolean): OrderRequest {
  const o = Field.object(raw, "order");
  const amount = (value: unknown, name: string): number | undefined => {
    const n = Field.optionalNumber(value, name);
    if (n !== undefined && n < 0) throw new HttpError(422, "invalid", `"${name}" can't be negative.`);
    return n;
  };
  const clientOrderID = needsClientID ? Field.string(o.clientOrderID, "order.clientOrderID", 128) : (Field.optionalString(o.clientOrderID, "order.clientOrderID", 128) ?? `preview-${crypto.randomUUID()}`);
  if (clientOrderID.trim() === "") throw new HttpError(400, "bad_request", "\"order.clientOrderID\" is required: it is what stops an order being placed twice.");
  const request: OrderRequest = {
    clientOrderID,
    ledgerID: Field.uuid(o.ledgerID, "order.ledgerID"),
    instrument: instrument(o.instrument),
    side: Field.oneOf(o.side, ORDER_SIDES, "order.side"),
    type: o.type === undefined ? "market" : Field.oneOf(o.type, ORDER_TYPES, "order.type"),
    timeInForce: o.timeInForce === undefined ? "day" : Field.oneOf(o.timeInForce, TIMES_IN_FORCE, "order.timeInForce"),
    // Orders through this API are always the person's own. Agents' orders are made by the engine.
    source: { kind: "manual" },
    mode: o.mode === undefined ? "paper" : Field.oneOf(o.mode, ["paper", "live"] as const, "order.mode"),
  };
  const quantity = amount(o.quantity, "order.quantity"), notional = amount(o.notional, "order.notional");
  const limitPrice = amount(o.limitPrice, "order.limitPrice"), stopPrice = amount(o.stopPrice, "order.stopPrice");
  if (quantity !== undefined) request.quantity = quantity;
  if (notional !== undefined) request.notional = notional;
  if (limitPrice !== undefined) request.limitPrice = limitPrice;
  if (stopPrice !== undefined) request.stopPrice = stopPrice;
  return request;
}

// MARK: - Running an action

/**
 * Runs engine work for the caller in one transaction and turns the outcome into a response.
 * With an Idempotency-Key, a repeat of a finished request returns the first answer and
 * does nothing else.
 */
async function act(ctx: Context, scope: LoadScope, work: (session: EngineSession) => Promise<unknown> | unknown, readOnly = false): Promise<Response> {
  const key = ctx.idempotencyKey;
  const action = String(ctx.body.action);
  const outcome = await withEngine(ctx.sql, ctx.caller.userID, ctx.now, { allowFixtureData: ctx.market.allowFixtureData, scope, readOnly }, async (session) => {
    if (key !== undefined && !readOnly) {
      const [seen] = await session.tx`select status, response, action from public.trading_idempotency_keys where user_id = ${ctx.caller.userID} and key = ${key}`;
      if (seen) {
        if (seen.action !== action) throw new HttpError(409, "idempotency_key_reused", "That Idempotency-Key was already used for a different request.");
        return { replay: { status: seen.status as number, body: seen.response } };
      }
    }
    const data = await work(session);
    const body = { ok: true, data };
    if (key !== undefined && !readOnly) {
      await session.tx`insert into public.trading_idempotency_keys ${session.tx({ user_id: ctx.caller.userID, key, action, status: 200, response: session.tx.json(body as never) })}`;
    }
    return { body };
  });
  if (outcome.refusal) {
    const { status, code } = tradingErrorStatus(outcome.refusal);
    return refusal(status, code, outcome.refusal.description, { reasons: outcome.refusal.messages });
  }
  const value = outcome.value!;
  if ("replay" in value && value.replay) return new Response(JSON.stringify(value.replay.body), { status: value.replay.status, headers: { "content-type": "application/json; charset=utf-8", "idempotent-replay": "true" } });
  return ok((value as { body: { data: unknown } }).body.data);
}

function orderOutcome(result: OrderResult): Record<string, unknown> {
  const out: Record<string, unknown> = { accepted: result.accepted, risk: result.risk, summary: reportSummary(result.risk) };
  if (result.order) out.order = result.order;
  if (result.accepted) out.fills = result.fills;
  return out;
}

async function needing(ctx: Context): Promise<Instrument[]> {
  return (await instrumentsNeedingQuotes(ctx.sql, ctx.caller.userID)).map((row) => row.instrument as Instrument);
}

/** Refuses a live order before it reaches the engine, and records the refusal. No live row is ever written. */
function refuseLiveOrder(session: EngineSession, request: OrderRequest): never {
  const reasons = session.engine.liveBlockers();
  appendAudit(session.engine.state.audit, crypto.randomUUID(), {
    time: session.now, actor: "user", kind: "liveRequestRefused",
    summary: `Refused a live ${request.side} order for ${request.instrument.symbol}.`, mode: "live", ledgerID: request.ledgerID,
    instrumentID: instrumentID(request.instrument), details: { reasons: reasons.join(" "), clientOrderID: request.clientOrderID },
  });
  throw TradingError.liveNotAvailable(reasons.length === 0 ? ["Live trading isn't available in this version."] : reasons);
}

const actions: Record<string, (ctx: Context) => Promise<Response>> = {
  // What this server can and can't do, so the app can say so honestly.
  capabilities: (ctx) => act(ctx, {}, ({ engine }) => ({
    paper: PaperBroker.capabilities,
    live: LiveVenues.all,
    liveTradingAvailable: false,
    liveBlockers: { manual: engine.liveBlockers(), approvalRequired: engine.liveBlockers("approvalRequired"), autonomousLive: engine.liveBlockers("autonomousLive") },
    currencies: Currencies.supported,
    marketData: {
      configured: ctx.market.provider !== null,
      source: ctx.market.provider?.name ?? null,
      reason: ctx.market.reason ?? null,
      // A venue the data source can't price can't be traded on the server (the phone may still price it).
      venues: Object.fromEntries(VENUES.map((venue) => [venue, ctx.market.provider?.supports({ symbol: "X", name: "X", assetClass: venue === "crypto" ? "crypto" : "equity", venue, currency: "" }) ?? false])),
    },
    killSwitchEngaged: engine.state.accountPolicy.killSwitchEngaged,
  }), true),

  createPortfolio: (ctx) => {
    const name = Field.string(ctx.body.name, "name"), startingCash = Field.number(ctx.body.startingCash, "startingCash");
    const currency = Field.optionalString(ctx.body.currency, "currency", 8) ?? "USD";
    return act(ctx, {}, ({ engine, now }) => ({ ledger: engine.createPaperPortfolio(name, startingCash, currency, now) }));
  },
  resetPortfolio: (ctx) => {
    const id = Field.uuid(ctx.body.ledgerID, "ledgerID");
    return act(ctx, {}, ({ engine, now }) => {
      engine.resetPaperPortfolio(id, now);
      return { ledger: engine.ledger(id) };
    });
  },
  deletePortfolio: (ctx) => {
    const id = Field.uuid(ctx.body.ledgerID, "ledgerID");
    return act(ctx, {}, ({ engine, now }) => {
      engine.deletePaperPortfolio(id, now);
      return { deleted: id };
    });
  },

  createAgent: (ctx) => {
    const draft = agentDraft(ctx.body.draft);
    if (modeIsLive(draft.mode)) requireStepUp(ctx.caller);
    return act(ctx, {}, ({ engine, now }) => {
      assertPriced(ctx.market, draft.spec.universe);
      const agent = engine.createAgent(draft, now);
      return { agent, ledger: engine.ledger(agent.ledgerID) ?? null };
    });
  },
  updateStrategy: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), spec = strategy(ctx.body.spec);
    const note = Field.optionalString(ctx.body.note, "note", 500) ?? "";
    const author = ctx.body.author === undefined ? "user" : Field.oneOf(ctx.body.author, CHANGE_AUTHORS, "author");
    return act(ctx, {}, ({ engine, now }) => {
      assertPriced(ctx.market, spec.universe);
      engine.updateStrategy(id, spec, note, now, author);
      return { agent: engine.agent(id) };
    });
  },
  updateRiskPolicy: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), policy = riskPolicy(ctx.body.policy);
    return act(ctx, {}, ({ engine, now }) => {
      const agent = engine.agent(id);
      // Tightening is always allowed; loosening needs the stronger sign-in.
      if (agent && isLoosening(agent.riskPolicy, policy)) requireStepUp(ctx.caller);
      engine.updateRiskPolicy(id, policy, now);
      return { agent: engine.agent(id) };
    });
  },
  renameAgent: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), name = Field.string(ctx.body.name, "name");
    return act(ctx, {}, ({ engine, now }) => {
      engine.renameAgent(id, name, now);
      return { agent: engine.agent(id) };
    });
  },
  setSchedule: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), intervalMinutes = Field.integer(ctx.body.intervalMinutes, "intervalMinutes");
    return act(ctx, {}, ({ engine, now }) => {
      engine.setSchedule(id, { intervalMinutes }, now);
      return { agent: engine.agent(id) };
    });
  },
  setReviewEachPaperTrade: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), review = Field.boolean(ctx.body.review, "review");
    return act(ctx, {}, ({ engine, now }) => {
      engine.setReviewEachPaperTrade(id, review, now);
      return { agent: engine.agent(id) };
    });
  },
  pauseAgent: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID");
    return act(ctx, {}, ({ engine, now }) => {
      engine.pauseAgent(id, now);
      return { agent: engine.agent(id) };
    });
  },
  resumeAgent: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID");
    return act(ctx, {}, ({ engine, now }) => {
      engine.resumeAgent(id, now);
      return { agent: engine.agent(id) };
    });
  },
  deleteAgent: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID");
    return act(ctx, {}, ({ engine, now }) => {
      engine.deleteAgent(id, now);
      return { deleted: id };
    });
  },
  setMode: (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID"), mode: AgentMode = Field.oneOf(ctx.body.mode, AGENT_MODES, "mode");
    if (modeIsLive(mode)) requireStepUp(ctx.caller);
    return act(ctx, {}, ({ engine, now }) => {
      // A live mode is refused inside the engine, with the reasons, and audited as liveRequestRefused.
      engine.setMode(id, mode, now);
      return { agent: engine.agent(id) };
    });
  },

  engageKillSwitch: (ctx) => act(ctx, {}, ({ engine, now }) => ({ ordersCancelled: engine.engageKillSwitch(now), killSwitchEngaged: true })),
  releaseKillSwitch: (ctx) => {
    requireStepUp(ctx.caller);
    return act(ctx, {}, ({ engine, now }) => {
      engine.releaseKillSwitch(now);
      return { killSwitchEngaged: engine.state.accountPolicy.killSwitchEngaged };
    });
  },

  previewOrder: async (ctx) => {
    const request = orderRequest(ctx.body.order, false);
    if (request.mode === "live") requireStepUp(ctx.caller);
    const market = await marketForOrder(ctx.market, request.instrument, [], ctx.now);
    return act(ctx, {}, ({ engine, now }) => {
      if (request.mode === "live") {
        // Told the truth, changed nothing: a preview is never recorded.
        const reasons = engine.liveBlockers();
        throw TradingError.liveNotAvailable(reasons.length === 0 ? ["Live trading isn't available in this version."] : reasons);
      }
      engine.ingest(market.quotes, market.stats, now);
      const preview = engine.preview(request, now);
      if (!preview) throw TradingError.notFound("That portfolio");
      return { preview };
    }, true);
  },
  placeOrder: async (ctx) => {
    const request = orderRequest(ctx.body.order, true);
    if (request.mode === "live") requireStepUp(ctx.caller);
    const market = request.mode === "live" ? { quotes: [], stats: {} } : await marketForOrder(ctx.market, request.instrument, await needing(ctx), ctx.now);
    return act(ctx, { clientOrderIDs: [request.clientOrderID] }, async ({ engine, tx, userID, now }) => {
      if (request.mode === "live") refuseLiveOrder({ engine, tx, userID, now }, request);
      // The same client order id again returns the order it already made — it never places a second.
      const [existing] = await tx`select id from public.orders where user_id = ${userID} and client_order_id = ${request.clientOrderID}`;
      if (existing) {
        const [row] = await tx`select status, filled_quantity from public.orders where id = ${existing.id}`;
        return { accepted: row.status !== "rejected", orderID: existing.id, status: row.status, alreadyPlaced: true };
      }
      engine.ingest(market.quotes, market.stats, now);
      return orderOutcome(engine.submit(request, now));
    });
  },
  cancelOrder: (ctx) => {
    const id = Field.uuid(ctx.body.orderID, "orderID");
    return act(ctx, { orderIDs: [id] }, ({ engine, now }) => {
      const order = engine.state.orders.find((o) => o.id === id);
      if (!order) throw TradingError.notFound("That order");
      if (!engine.cancelOrder(id, now)) throw TradingError.notAllowed(`This order is already ${order.status} and can't be cancelled.`);
      return { order };
    });
  },

  approveProposal: async (ctx) => {
    const id = Field.uuid(ctx.body.proposalID, "proposalID");
    const [row] = await ctx.sql`select instrument, agent_id from public.trade_proposals where id = ${id} and user_id = ${ctx.caller.userID}`;
    if (!row) return errorResponse(TradingError.notFound("That proposal"));
    const market = await marketForOrder(ctx.market, row.instrument as Instrument, await needing(ctx), ctx.now);
    return act(ctx, { proposalIDs: [id], agentIDs: [row.agent_id] }, ({ engine, now }) => {
      // The order is judged again against the prices of this moment before it is placed.
      engine.ingest(market.quotes, market.stats, now);
      const result = engine.approveProposal(id, now);
      return { ...orderOutcome(result), proposal: engine.state.proposals.find((p) => p.id === id) };
    });
  },
  rejectProposal: (ctx) => {
    const id = Field.uuid(ctx.body.proposalID, "proposalID");
    return act(ctx, { proposalIDs: [id] }, ({ engine, now }) => {
      engine.rejectProposal(id, now);
      return { proposal: engine.state.proposals.find((p) => p.id === id) };
    });
  },

  runAgent: async (ctx) => {
    const id = Field.uuid(ctx.body.agentID, "agentID");
    const [row] = await ctx.sql`
      select a.ledger_id, v.spec from public.trading_agents a
      join public.agent_strategy_versions v on v.agent_id = a.id and v.version = a.strategy_version
      where a.id = ${id} and a.user_id = ${ctx.caller.userID} and a.deleted_at is null`;
    if (!row) return errorResponse(TradingError.notFound("That agent"));
    let spec: StrategySpec;
    try {
      spec = decodeStrategySpec(row.spec);
    } catch {
      // Never run on a strategy this code can't read.
      return errorResponse(TradingError.notAllowed("This agent's saved strategy can't be read. Save its strategy again, then run it."));
    }
    let instruments = spec.universe;
    if (spec.followsLedgerPositions && row.ledger_id) {
      instruments = (await ctx.sql`select instrument from public.positions where ledger_id = ${row.ledger_id} order by seq`).map((p) => p.instrument as Instrument);
    }
    const [snapshot, others] = await Promise.all([
      marketSnapshot(ctx.market, instruments, spec.timeframe, barsToFetch(spec), ctx.now),
      latestQuotes(ctx.market, await needing(ctx), ctx.now),
    ]);
    return act(ctx, { agentIDs: [id] }, ({ engine, now }) => {
      // Prices for the person's other open orders and holdings, then the agent's own run.
      engine.ingest(others, {}, now);
      const run = engine.runAgent(id, snapshot, "manual", now);
      if (!run) throw TradingError.notFound("That agent");
      return { run, agent: engine.agent(id), spec: engine.agent(id) ? agentSpec(engine.agent(id)!) : null };
    });
  },

  auditStatus: (ctx) => act(ctx, {}, async ({ tx, userID }) => {
    const [row] = await tx`select * from public.verify_audit_chain(${userID})`;
    return { isIntact: row.is_intact, brokenAtSequence: row.broken_at_sequence === null ? null : Number(row.broken_at_sequence), eventCount: Number(row.event_count) };
  }, true),
};

async function handle(request: Request, started: number): Promise<{ response: Response; action: string }> {
  if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
  const caller = await authenticate(request, { url: env("SUPABASE_URL"), anonKey: env("SUPABASE_ANON_KEY") });
  const body = await readJSONObject(request);
  const action = typeof body.action === "string" ? body.action : "";
  const run = Object.hasOwn(actions, action) ? actions[action] : undefined;
  if (!run) throw new HttpError(400, "unknown_action", "That isn't something the trading API can do.");

  // Fixture prices are for tests: they are honoured only when the function's own flag is on.
  const choice = providerFromEnv(env, body.fixture === undefined ? {} : { fixture: body.fixture });
  if (body.fixture !== undefined && !choice.provider) throw new HttpError(403, "fixtures_not_allowed", choice.reason ?? "Fixture data isn't allowed here.");
  const headerKey = request.headers.get("idempotency-key") ?? undefined;
  if (headerKey !== undefined && (headerKey.length < 8 || headerKey.length > 128)) throw new HttpError(400, "bad_request", "The Idempotency-Key must be 8 to 128 characters.");

  const ctx: Context = {
    sql: database(), caller, body, now: started,
    market: { provider: choice.provider, allowFixtureData: choice.allowFixtureData, reason: choice.reason },
    idempotencyKey: headerKey,
  };
  return { response: await run(ctx), action };
}

Deno.serve(async (request) => {
  // The one place this function reads the clock. Every engine call gets this instant.
  const started = Date.now();
  let action = "unknown";
  let response: Response;
  try {
    if (request.method === "OPTIONS") return new Response(null, { status: 204 });
    const handled = await handle(request, started);
    action = handled.action;
    response = handled.response;
  } catch (error) {
    response = errorResponse(error);
    if (response.status >= 500) {
      logEvent("trading_api_error", { action, error: error instanceof Error ? `${error.name}: ${error.message}` : "unknown" });
    }
  }
  logEvent("trading_api", { action, status: response.status, ms: Date.now() - started });
  return response;
});
