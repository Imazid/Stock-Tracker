// agent-scheduler — keeps agents running while the phone is closed.
//
// Called every minute by pg_cron (see the migration) with a secret header; without the
// right secret it refuses. Each invocation:
//
//   1. claims the agents whose run time has come (a lease, so two invocations never run
//      the same agent at once);
//   2. fetches real market data for them, outside any transaction;
//   3. for each person, in ONE transaction: takes in the fresh quotes (which lets waiting
//      paper orders trade, expires what has run out of time and reprices portfolios), runs
//      each claimed agent through the same pipeline as the phone — data checks → decision →
//      signal → sizing → risk engine → proposal → paper order or wait for approval —
//      saves everything, and releases the leases.
//
// Each run also prunes idempotency keys older than 30 days, and CoinGecko's traded-value
// figures are cached for a day (migration 20261113150000), as the phone caches them.
//
// A failed fetch means no trade: the run is recorded as failed, the agent's error count
// goes up, and after five in a row it pauses itself. Every write is idempotent (state is
// re-read under the person's lock; client order ids, signal keys and fill numbers are
// unique), so a retried invocation can't fill anything twice.
//
// Only paper execution exists. There is no live adapter (see ../_shared/server/live.ts);
// reconciliation is a no-op for paper and refuses if it ever meets a live order. No
// language model is consulted anywhere in this function.
//
// Environment (function secrets; never logged or returned):
//   TRADING_SCHEDULER_SECRET                           required; the caller must send it
//   SUPABASE_DB_URL                                    provided by Supabase
//   ALPACA_DATA_KEY_ID, ALPACA_DATA_SECRET             market data (read-only prices)
//   COINGECKO_API_KEY                                  optional, market-wide crypto volume
//   TRADING_ALLOW_FIXTURE_DATA                         "1" only in test deployments

import { providerFromEnv } from "../_shared/market/index.ts";
import { errorResponse, HttpError, json, logEvent, readJSONObject, sameSecret } from "../_shared/server/http.ts";
import { reconcile } from "../_shared/server/live.ts";
import { database, instrumentsNeedingQuotes, type Sql, withEngine } from "../_shared/server/persistence.ts";
import { latestQuotes, type MarketSource, marketSnapshot, subset } from "../_shared/server/runner.ts";
import { postgresVolumeStore, pruneIdempotencyKeys } from "../_shared/server/upkeep.ts";
import { emptySnapshot, type Instrument, instrumentID, type MarketSnapshot, type Quote, type Timeframe } from "../_shared/trading/market.ts";
import { barsToFetch, decodeStrategySpec, type StrategySpec } from "../_shared/trading/strategy.ts";

const MAX_AGENTS = 40;
const MAX_OTHER_USERS = 60;
const LEASE_SECONDS = 120;
const TIME_BUDGET_MS = 40_000;
const STALE_MARK_MINUTES = 15;

interface ClaimedAgent {
  id: string;
  userID: string;
  /** Null when the stored strategy can't be read by this version of the code. Such an agent is paused, never run. */
  spec: StrategySpec | null;
  instruments: Instrument[];
}

function readSpec(raw: unknown): StrategySpec | null {
  try {
    return decodeStrategySpec(raw);
  } catch {
    return null;
  }
}

interface Summary {
  claimed: number;
  people: number;
  runs: Record<string, number>;
  fills: number;
  proposals: number;
  errors: number;
  skippedForTime: number;
  prunedIdempotencyKeys: number;
}

const env = (name: string) => Deno.env.get(name);

/** Claims due agents and reads what each one watches. */
async function claim(sql: Sql, now: number, worker: string): Promise<ClaimedAgent[]> {
  const rows = await sql.begin(async (tx) => {
    await tx`set local role service_role`;
    return await tx`select agent_id, user_id from public.claim_due_agents(${MAX_AGENTS}, ${LEASE_SECONDS}, ${new Date(now)}, ${worker})`;
  });
  if (rows.length === 0) return [];
  const ids = rows.map((row) => row.agent_id as string);
  const details = await sql`
    select a.id, a.user_id, a.ledger_id, v.spec from public.trading_agents a
    join public.agent_strategy_versions v on v.agent_id = a.id and v.version = a.strategy_version
    where a.id in ${sql(ids)}`;
  const read = details.map((d) => ({ row: d, spec: readSpec(d.spec) }));
  const ledgers = read.filter(({ row, spec }) => spec?.followsLedgerPositions && row.ledger_id).map(({ row }) => row.ledger_id as string);
  const held = ledgers.length > 0 ? await sql`select ledger_id, instrument from public.positions where ledger_id in ${sql(ledgers)} order by seq` : [];
  return read.map(({ row, spec }) => {
    const instruments = spec === null ? [] : spec.followsLedgerPositions
      ? held.filter((p) => p.ledger_id === row.ledger_id).map((p) => p.instrument as Instrument)
      : spec.universe;
    return { id: row.id as string, userID: row.user_id as string, spec, instruments };
  });
}

/** People with no agent due who still have something waiting on a price. */
async function othersWithWork(sql: Sql, now: number, exclude: string[]): Promise<string[]> {
  const stale = new Date(now - STALE_MARK_MINUTES * 60_000);
  const rows = await sql`
    select user_id from (
      select user_id from public.orders where status in ('pendingSubmit', 'accepted', 'partiallyFilled') and mode = 'paper'
      union
      select user_id from public.trade_proposals where status = 'pending'
      union
      select a.user_id from public.trading_accounts a
        where a.deleted_at is null and (a.marked_at is null or a.marked_at < ${stale})
          and exists (select 1 from public.positions p where p.ledger_id = a.id)
    ) waiting limit ${MAX_OTHER_USERS + exclude.length}`;
  return rows.map((row) => row.user_id as string).filter((id) => !exclude.includes(id)).slice(0, MAX_OTHER_USERS);
}

/** One request per bar size for everything a person's agents watch, split back out per agent. */
async function snapshotsFor(source: MarketSource, agents: ClaimedAgent[], now: number): Promise<Map<string, MarketSnapshot>> {
  const out = new Map<string, MarketSnapshot>();
  for (const timeframe of ["day", "hour"] as Timeframe[]) {
    const group = agents.filter((agent) => agent.spec?.timeframe === timeframe && agent.instruments.length > 0);
    if (group.length === 0) continue;
    const count = Math.max(...group.map((agent) => barsToFetch(agent.spec!)));
    const all = await marketSnapshot(source, group.flatMap((agent) => agent.instruments), timeframe, count, now);
    for (const agent of group) out.set(agent.id, subset(all, agent.instruments));
  }
  for (const agent of agents) if (!out.has(agent.id)) out.set(agent.id, emptySnapshot());
  return out;
}

async function processPerson(sql: Sql, source: MarketSource, userID: string, agents: ClaimedAgent[], now: number, worker: string, summary: Summary): Promise<void> {
  // Prices first, with no lock held.
  const watched = new Set(agents.flatMap((agent) => agent.instruments.map(instrumentID)));
  const needing = (await instrumentsNeedingQuotes(sql, userID)).map((row) => row.instrument as Instrument);
  const [snapshots, otherQuotes] = await Promise.all([
    snapshotsFor(source, agents, now),
    latestQuotes(source, needing.filter((instrument) => !watched.has(instrumentID(instrument))), now),
  ]);
  const quotes: Quote[] = [...otherQuotes];
  for (const snapshot of snapshots.values()) quotes.push(...Object.values(snapshot.quotes));

  const outcome = await withEngine(sql, userID, now, { allowFixtureData: source.allowFixtureData, scope: { agentIDs: agents.map((agent) => agent.id) } },
    async ({ engine, tx }) => {
      // Paper orders live in our own database: nothing outside to reconcile. A live order must not exist.
      reconcile(engine.state.orders);
      // Fresh quotes: waiting orders may trade, stale ones expire, portfolios are repriced, circuit breakers run.
      engine.ingest(quotes, {}, now);
      const statuses: string[] = [];
      for (const agent of agents) {
        if (agent.spec === null) {
          // A stored strategy this code can't read is never guessed at. The agent is paused, on the
          // record, until the person saves a strategy again — it doesn't fail quietly every minute.
          engine.pauseAgent(agent.id, now, "repeatedErrors");
          statuses.push("unreadable");
          continue;
        }
        const run = engine.runAgent(agent.id, snapshots.get(agent.id) ?? emptySnapshot(), "schedule", now);
        if (run) statuses.push(run.status);
      }
      if (agents.length > 0) {
        await tx`update public.trading_agents set locked_until = null, locked_by = null
                 where id in ${tx(agents.map((agent) => agent.id))} and locked_by = ${worker}`;
      }
      return { statuses, fills: engine.state.fills.length, proposals: engine.state.proposals.length };
    });
  for (const status of outcome.value?.statuses ?? []) summary.runs[status] = (summary.runs[status] ?? 0) + 1;
  summary.fills += outcome.auditEvents.filter((event) => event.kind === "orderFilled" || event.kind === "orderPartiallyFilled").length;
  summary.proposals += outcome.auditEvents.filter((event) => event.kind === "proposalCreated").length;
}

async function handle(request: Request, started: number): Promise<Response> {
  if (request.method !== "POST") throw new HttpError(405, "method_not_allowed", "Send a POST request.");
  // Fail closed: with no secret configured, nobody can run the scheduler.
  const secret = env("TRADING_SCHEDULER_SECRET") ?? "";
  const given = request.headers.get("x-scheduler-secret") ?? "";
  if (secret.length < 16 || !sameSecret(secret, given)) throw new HttpError(401, "unauthorized", "Not allowed.");

  const body = await readJSONObject(request);
  const sql = database();
  // CoinGecko's traded-value figures are kept for a day in the database, as the phone keeps them.
  const volumeStore = postgresVolumeStore(sql);
  const choice = providerFromEnv(env, body.fixture === undefined ? { volumeStore } : { fixture: body.fixture, volumeStore });
  if (body.fixture !== undefined && !choice.provider) throw new HttpError(403, "fixtures_not_allowed", choice.reason ?? "Fixture data isn't allowed here.");
  const source: MarketSource = { provider: choice.provider, allowFixtureData: choice.allowFixtureData, reason: choice.reason };

  const worker = crypto.randomUUID();
  const summary: Summary = { claimed: 0, people: 0, runs: {}, fills: 0, proposals: 0, errors: 0, skippedForTime: 0, prunedIdempotencyKeys: 0 };

  // Housekeeping first and on its own: a failure here is logged and never stops agents running.
  try {
    summary.prunedIdempotencyKeys = await pruneIdempotencyKeys(sql, started);
  } catch (error) {
    logEvent("scheduler_prune_failed", { error: error instanceof Error ? error.name : "unknown" });
  }

  const claimed = await claim(sql, started, worker);
  summary.claimed = claimed.length;
  const byPerson = new Map<string, ClaimedAgent[]>();
  for (const agent of claimed) byPerson.set(agent.userID, [...(byPerson.get(agent.userID) ?? []), agent]);
  for (const userID of await othersWithWork(sql, started, [...byPerson.keys()])) byPerson.set(userID, []);

  for (const [userID, agents] of byPerson) {
    if (Date.now() - started > TIME_BUDGET_MS) {
      // Out of time: these leases simply run out and the agents are picked up next minute.
      summary.skippedForTime += 1;
      continue;
    }
    try {
      await processPerson(sql, source, userID, agents, started, worker, summary);
      summary.people += 1;
    } catch (error) {
      // One person's failure doesn't stop the rest. Nothing of theirs was half-written: the transaction rolled back.
      summary.errors += 1;
      logEvent("scheduler_person_failed", { person: userID.slice(0, 8), agents: agents.length, error: error instanceof Error ? `${error.name}: ${error.message}` : "unknown" });
    }
  }
  return json(200, { ok: true, data: { ...summary, marketData: source.provider?.name ?? null } });
}

Deno.serve(async (request) => {
  // The one place this function reads the clock. Every engine call in this invocation gets this instant.
  const started = Date.now();
  let response: Response;
  try {
    response = await handle(request, started);
  } catch (error) {
    response = errorResponse(error);
    if (response.status >= 500) logEvent("scheduler_error", { error: error instanceof Error ? `${error.name}: ${error.message}` : "unknown" });
  }
  logEvent("agent_scheduler", { status: response.status, ms: Date.now() - started });
  return response;
});
