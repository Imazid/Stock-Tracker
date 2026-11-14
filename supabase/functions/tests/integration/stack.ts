// Helpers for the tests that run against the local Supabase stack.
//
// Nothing here holds a key. The stack's own (local, throw-away) keys come from the
// environment, as `supabase status -o env` prints them:
//
//   set -a; eval "$(supabase status -o env)"; set +a
//
// and the scheduler secret from the same env file the functions were served with.

import postgres from "npm:postgres@3.4.5";

function need(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`${name} isn't set. Start the local stack and load its settings first: set -a; eval "$(supabase status -o env)"; set +a`);
  }
  return value;
}

export const apiURL = () => need("API_URL");
export const anonKey = () => need("ANON_KEY");
export const serviceKey = () => need("SERVICE_ROLE_KEY");
export const schedulerSecret = () => need("TRADING_SCHEDULER_SECRET");

// deno-lint-ignore no-explicit-any
export type Sql = postgres.Sql<any>;
// deno-lint-ignore no-explicit-any
export type Tx = postgres.TransactionSql<any>;

/** A connection as the database owner (the role migrations run as). */
export function connect(max = 4): Sql {
  return postgres(need("DB_URL"), { max, prepare: false, onnotice: () => {} });
}

export class Rollback extends Error {}

/** Runs `body` in a transaction that is always rolled back, so a test leaves nothing behind. */
export async function scratch(sql: Sql, body: (tx: Tx) => Promise<void>): Promise<void> {
  try {
    await sql.begin(async (tx) => {
      await body(tx);
      throw new Rollback();
    });
  } catch (error) {
    if (!(error instanceof Rollback)) throw error;
  }
}

/** Expects a statement to be refused by the database, and returns the message. The transaction carries on. */
export async function refused(tx: Tx, what: string, statement: (sp: Tx) => Promise<unknown>): Promise<string> {
  try {
    await tx.savepoint(async (sp) => {
      await statement(sp as unknown as Tx);
    });
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
  throw new Error(`The database accepted something it must refuse: ${what}`);
}

export interface Person {
  id: string;
  email: string;
  password: string;
  token: string;
}

const created: string[] = [];

/** Deletes every account these tests made, and with it everything that account owned. */
export async function removePeople(sql: Sql): Promise<void> {
  const ids = created.splice(0);
  if (ids.length > 0) await sql`delete from auth.users where id in ${sql(ids)}`;
}

/** Creates a real account through the auth server and signs it in. */
export async function signUp(label = "trader"): Promise<Person> {
  const email = `${label}-${crypto.randomUUID().slice(0, 12)}@example.test`;
  const password = `pw-${crypto.randomUUID()}`;
  const response = await fetch(`${apiURL()}/auth/v1/signup`, {
    method: "POST", headers: { apikey: anonKey(), "content-type": "application/json" }, body: JSON.stringify({ email, password }),
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) throw new Error(`sign-up failed (${response.status})`);
  created.push(body.user.id);
  return { id: body.user.id, email, password, token: body.access_token };
}

/** Signs in again with the password: a fresh, single-factor (aal1) session. */
export async function signIn(person: Person): Promise<string> {
  const response = await fetch(`${apiURL()}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: anonKey(), "content-type": "application/json" },
    body: JSON.stringify({ email: person.email, password: person.password }),
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) throw new Error(`sign-in failed (${response.status})`);
  return body.access_token;
}

/** A request to the data API as a signed-in person (row-level security applies). */
export async function rest(token: string, path: string, init: RequestInit = {}): Promise<{ status: number; body: unknown }> {
  const response = await fetch(`${apiURL()}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: anonKey(), authorization: `Bearer ${token}`, "content-type": "application/json", prefer: "return=representation", ...(init.headers ?? {}) },
  });
  const text = await response.text();
  let body: unknown = text;
  try { body = text === "" ? null : JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, body };
}

// deno-lint-ignore no-explicit-any
export type Answer = { status: number; ok: boolean; data: any; error?: { code: string; message: string; details?: any }; headers: Headers };

/** Calls the trading API as a signed-in person. */
export async function api(token: string | undefined, body: Record<string, unknown>, headers: Record<string, string> = {}): Promise<Answer> {
  const endpoint = Deno.env.get("TRADING_API_TEST_URL") ?? `${apiURL()}/functions/v1/trading-api`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token === undefined ? {} : { authorization: `Bearer ${token}` }), ...headers },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  // deno-lint-ignore no-explicit-any
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { error: { code: "not_json", message: text.slice(0, 200) } }; }
  return { status: response.status, ok: parsed.ok === true, data: parsed.data, error: parsed.error, headers: response.headers };
}

/** Invokes the scheduler the way pg_cron does. Pass `null` as the secret to send no secret header at all. */
export async function schedule(body: Record<string, unknown> = {}, secret: string | null = schedulerSecret()): Promise<Answer> {
  const response = await fetch(`${apiURL()}/functions/v1/agent-scheduler`, {
    method: "POST", headers: { "content-type": "application/json", ...(secret === null ? {} : { "x-scheduler-secret": secret }) },
    body: JSON.stringify(body),
  });
  const parsed = await response.json().catch(() => ({}));
  return { status: response.status, ok: parsed.ok === true, data: parsed.data, error: parsed.error, headers: response.headers };
}

export const AAPL = { symbol: "AAPL", name: "Apple", assetClass: "equity", venue: "us", currency: "USD" };
export const BTC = { symbol: "BTC", name: "Bitcoin", assetClass: "crypto", venue: "crypto", currency: "USD" };

/** A minimal valid paper book, written as the service role would write it. */
export async function seedAccount(tx: Tx, userID: string, fields: Record<string, unknown> = {}): Promise<string> {
  const id = crypto.randomUUID();
  await tx`insert into public.trading_accounts ${tx({
    id, user_id: userID, name: "Test book", kind: "manualPaper", mode: "paper", currency: "USD", starting_cash: 10_000, cash: 10_000,
    peak_equity: 10_000, day_key: "2026-11-10", day_start_equity: 10_000, created_at: new Date(), ...fields,
  })}`;
  return id;
}

export async function seedAgent(tx: Tx, userID: string, fields: Record<string, unknown> = {}): Promise<string> {
  const id = crypto.randomUUID();
  await tx`insert into public.trading_agents ${tx({
    id, user_id: userID, name: "Test agent", mode: "paper", status: "active", risk_policy: tx.json({ maxOrderNotional: 500 }),
    // Never due unless a test says so: the scheduler must not pick up a half-made test agent.
    budget: 5_000, schedule_interval_minutes: 60, created_at: new Date(), next_run_at: new Date("2099-01-01T00:00:00Z"), ...fields,
  })}`;
  await tx`insert into public.agent_strategy_versions ${tx({ user_id: userID, agent_id: id, version: 1, spec: tx.json({ kind: "rules" }), author: "user", created_at: new Date() })}`;
  return id;
}

export async function seedOrder(tx: Tx, userID: string, ledgerID: string, fields: Record<string, unknown> = {}): Promise<string> {
  const id = crypto.randomUUID();
  await tx`insert into public.orders ${tx({
    id, user_id: userID, client_order_id: `c-${id}`, ledger_id: ledgerID, instrument_id: "us:AAPL", instrument: tx.json(AAPL),
    side: "buy", type: "market", quantity: 10, time_in_force: "day", source_kind: "manual", mode: "paper", status: "accepted",
    reference_price: 100, created_at: new Date(), updated_at: new Date(), ...fields,
  })}`;
  return id;
}

export async function seedAudit(tx: Tx, userID: string, fields: Record<string, unknown> = {}): Promise<{ sequence: number; previous_hash: string; hash: string }> {
  const [row] = await tx`insert into public.audit_events ${tx({
    user_id: userID, time: new Date("2026-11-10T15:00:00Z"), actor: "user", kind: "orderSubmitted", summary: "Order", details: tx.json({}), ...fields,
  })} returning sequence, previous_hash, hash`;
  return { sequence: Number(row.sequence), previous_hash: row.previous_hash, hash: row.hash };
}

/** RFC 6238 code for a base32 secret (what an authenticator app shows). */
export async function totp(secretBase32: string, at = Date.now()): Promise<string> {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const char of secretBase32.replace(/=+$/, "").toUpperCase()) bits += alphabet.indexOf(char).toString(2).padStart(5, "0");
  const bytes = new Uint8Array(Math.floor(bits.length / 8));
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(0, BigInt(Math.floor(at / 30_000)));
  const key = await crypto.subtle.importKey("raw", bytes, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, counter));
  const offset = mac[mac.length - 1] & 0x0f;
  const code = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(code % 1_000_000).padStart(6, "0");
}
