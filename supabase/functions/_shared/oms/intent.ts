// The immutable order intent and its hash.
//
// An approval is a signature over exactly one intent: the person approves what the screen
// showed them, and nothing else can ride on that approval. We canonicalise every field that
// changes what would be sent to the provider (account, instrument, side, type, size, prices,
// time in force, our client order id, the environment) and hash it. Any later change — a new
// quantity, a different limit, another account — gives a different hash, so the stored
// approval no longer matches and submission is refused with `intent_changed`.

import type { OrderIntentInput } from "./api.ts";
import type { ProviderID, TradingEnvironment } from "../brokers/types.ts";
import { isDecimal, isZero, normalise } from "./decimal.ts";

export const INTENT_VERSION = 1;

/** Everything that defines what would be sent. Field order here is irrelevant; canonical() sorts. */
export interface CanonicalIntent {
  v: number;
  userID: string;
  connectionID: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  symbol: string;
  assetClass: "us_equity" | "crypto";
  side: "buy" | "sell";
  type: "market" | "limit" | "stop" | "stop_limit";
  timeInForce: "day" | "gtc" | "ioc" | "fok";
  quantity: string | null;
  notional: string | null;
  limitPrice: string | null;
  stopPrice: string | null;
  clientOrderID: string;
}

export class IntentError extends Error {
  constructor(readonly field: string, message: string) {
    super(message);
    this.name = "IntentError";
  }
}

const SYMBOL = /^[A-Z0-9][A-Z0-9.\-/]{0,23}$/;
const CLIENT_ORDER_ID = /^[A-Za-z0-9-]{8,48}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Checks the shape of a drafted order. Business limits are the risk engine's job, not this. */
export function validateInput(input: OrderIntentInput): void {
  if (!UUID.test(input.connectionID)) throw new IntentError("connectionID", "Choose a connected account.");
  if (!SYMBOL.test(input.symbol)) throw new IntentError("symbol", "That symbol isn't valid.");
  if (input.assetClass !== "us_equity" && input.assetClass !== "crypto") throw new IntentError("assetClass", "Unsupported asset class.");
  if (input.side !== "buy" && input.side !== "sell") throw new IntentError("side", "Choose buy or sell.");
  if (!["market", "limit", "stop", "stop_limit"].includes(input.type)) throw new IntentError("type", "Unsupported order type.");
  if (!["day", "gtc", "ioc", "fok"].includes(input.timeInForce)) throw new IntentError("timeInForce", "Unsupported time in force.");

  const hasQty = input.quantity !== undefined && input.quantity !== "";
  const hasNotional = input.notional !== undefined && input.notional !== "";
  if (hasQty === hasNotional) throw new IntentError("quantity", "Give either a quantity or an amount, not both.");
  const size = hasQty ? input.quantity! : input.notional!;
  if (!isDecimal(size) || isZero(size)) throw new IntentError(hasQty ? "quantity" : "notional", "The size must be a number above zero.");
  if (hasNotional && input.type !== "market") throw new IntentError("notional", "An amount (rather than a quantity) only works with a market order.");

  const needsLimit = input.type === "limit" || input.type === "stop_limit";
  const needsStop = input.type === "stop" || input.type === "stop_limit";
  for (const [field, needed, value] of [["limitPrice", needsLimit, input.limitPrice], ["stopPrice", needsStop, input.stopPrice]] as const) {
    if (needed) {
      if (!isDecimal(value) || isZero(value)) throw new IntentError(field, `A ${input.type.replace("_", "-")} order needs a ${field === "limitPrice" ? "limit" : "stop"} price above zero.`);
    } else if (value !== undefined && value !== "") {
      throw new IntentError(field, `A ${input.type.replace("_", "-")} order doesn't take a ${field === "limitPrice" ? "limit" : "stop"} price.`);
    }
  }
  if (input.origin.kind === "agent") {
    if (!UUID.test(input.origin.agentID)) throw new IntentError("origin", "Unknown agent.");
    if (typeof input.origin.rationale !== "string" || input.origin.rationale.trim().length === 0) {
      throw new IntentError("origin", "An agent's proposal must say why.");
    }
  }
}

export function canonicalIntent(fields: {
  userID: string;
  provider: ProviderID;
  environment: TradingEnvironment;
  clientOrderID: string;
  input: OrderIntentInput;
}): CanonicalIntent {
  const { input } = fields;
  if (!CLIENT_ORDER_ID.test(fields.clientOrderID)) throw new IntentError("clientOrderID", "Bad client order id.");
  const dec = (value: string | undefined) => (value === undefined || value === "" ? null : normalise(value));
  return {
    v: INTENT_VERSION,
    userID: fields.userID.toLowerCase(),
    connectionID: input.connectionID.toLowerCase(),
    provider: fields.provider,
    environment: fields.environment,
    symbol: input.symbol,
    assetClass: input.assetClass,
    side: input.side,
    type: input.type,
    timeInForce: input.timeInForce,
    quantity: dec(input.quantity),
    notional: dec(input.notional),
    limitPrice: dec(input.limitPrice),
    stopPrice: dec(input.stopPrice),
    clientOrderID: fields.clientOrderID,
  };
}

/** Deterministic JSON: keys sorted at every level, no whitespace. */
export function canonicalJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJSON(v)}`).join(",")}}`;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function intentHash(intent: CanonicalIntent): Promise<string> {
  return sha256Hex(canonicalJSON(intent));
}

/** A fresh client order id: "st-" + 32 hex chars (35 chars; within Alpaca's 48 and Coinbase's limits). */
export function newClientOrderID(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `st-${[...bytes].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

/** Constant-time comparison for hashes, so a timing side channel can't guess an intent hash. */
export function sameHash(a: string, b: string): boolean {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
