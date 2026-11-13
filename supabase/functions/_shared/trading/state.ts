// Everything the trading side knows, as one value changed only through `TradingEngine`.
// A port of TradingCore/Sources/TradingCore/TradingState.swift.

import type { AgentMode, AgentRun, AgentSchedule, ChangeAuthor, TradeProposal, TradingAgent, TradingSignal } from "./agent.ts";
import { type AuditLog, makeAuditLog } from "./audit.ts";
import { type BrokerEnvironment, type BrokerPermission, defaultPaperConfig, type PaperBrokerConfig } from "./broker.ts";
import type { Ledger } from "./ledger.ts";
import type { Instrument, InstrumentStats, Quote } from "./market.ts";
import type { ExecutionMode, Fill, Order, OrderSide, OrderType, TimeInForce } from "./orders.ts";
import { type AccountPolicy, defaultAccountPolicy, type RiskPolicy, type RiskReport, standardPolicy } from "./risk.ts";
import type { StrategySpec } from "./strategy.ts";

/**
 * A link to a place orders could be sent. Paper is built in; a real broker connection is
 * listed with exactly the permissions it was granted.
 */
export interface BrokerConnection {
  id: string;
  adapterID: string;
  name: string;
  environment: BrokerEnvironment;
  permissions: BrokerPermission[];
  createdAt: number;
}

export const connectionCanTrade = (connection: BrokerConnection): boolean => connection.permissions.includes("trade");

/** What a person fills in (or an AI drafts) to create an agent. */
export interface AgentDraft {
  name: string;
  templateID?: string;
  mode: AgentMode;
  spec: StrategySpec;
  budget: number;
  maxPositionPct: number;
  /** Full limits, when the person edited them. undefined = standard limits for the budget. */
  riskPolicy?: RiskPolicy;
  reviewEachPaperTrade: boolean;
  schedule: AgentSchedule;
  /** Manage an existing paper portfolio instead of getting a new one. */
  attachToLedgerID?: string;
  author: ChangeAuthor;
}

export function makeDraft(fields: Partial<AgentDraft> & Pick<AgentDraft, "name" | "spec">): AgentDraft {
  return {
    mode: "paper", budget: 10_000, maxPositionPct: 10, reviewEachPaperTrade: false, schedule: { intervalMinutes: 60 }, author: "user",
    ...fields,
  };
}

export function draftIsCryptoOnly(draft: AgentDraft): boolean {
  return draft.spec.universe.length > 0 && draft.spec.universe.every((instrument) => instrument.assetClass === "crypto");
}

export function resolvedPolicy(draft: AgentDraft): RiskPolicy {
  return draft.riskPolicy ?? standardPolicy(draft.budget, draft.maxPositionPct, draftIsCryptoOnly(draft));
}

export type TradingErrorKind = "invalid" | "liveNotAvailable" | "notFound" | "notAllowed";

/** A refusal with a reason a person can read. Anything else thrown is a bug. */
export class TradingError extends Error {
  readonly kind: TradingErrorKind;
  /** The problems (invalid), the reasons (liveNotAvailable), or the one subject / reason. */
  readonly messages: string[];

  constructor(kind: TradingErrorKind, messages: string[]) {
    super(TradingError.describe(kind, messages));
    this.name = "TradingError";
    this.kind = kind;
    this.messages = messages;
  }

  static describe(kind: TradingErrorKind, messages: string[]): string {
    if (kind === "notFound") return `${messages[0] ?? "That"} wasn't found.`;
    return messages.join(" ");
  }

  get description(): string {
    return this.message;
  }

  static invalid = (problems: string[]) => new TradingError("invalid", problems);
  static liveNotAvailable = (reasons: string[]) => new TradingError("liveNotAvailable", reasons);
  static notFound = (what: string) => new TradingError("notFound", [what]);
  static notAllowed = (why: string) => new TradingError("notAllowed", [why]);
}

export type NoticeKind =
  | "approvalNeeded" | "proposalBlocked" | "orderSubmitted" | "orderFilled" | "orderPartiallyFilled"
  | "orderRejected" | "orderCanceled" | "agentPaused" | "dailyLossReached" | "dataUnavailable";

/** Something the person should hear about. The app turns these into notifications. */
export interface EngineNotice {
  kind: NoticeKind;
  title: string;
  body: string;
  mode: ExecutionMode;
  agentID?: string;
  orderID?: string;
  proposalID?: string;
  instrumentID?: string;
}

export interface OrderPreview {
  instrument: Instrument;
  side: OrderSide;
  type: OrderType;
  timeInForce: TimeInForce;
  quantity: number;
  /** The price the estimate uses: the ask to buy, the bid to sell, or the order's own limit. */
  estimatedPrice: number;
  estimatedValue: number;
  estimatedFee: number;
  /** Cash left after a buy, or cash after the proceeds of a sell. */
  cashAfter: number;
  currency: string;
  ledgerName: string;
  mode: ExecutionMode;
  quote?: Quote;
  spreadBps?: number;
  usesModelledSpread: boolean;
  willQueueUntilOpen: boolean;
  nextOpen?: number;
  risk: RiskReport;
  canSubmit: boolean;
}

export type OrderResult =
  | { accepted: true; order: Order; fills: Fill[]; risk: RiskReport }
  | { accepted: false; order?: Order; risk: RiskReport };

export interface TradingState {
  schemaVersion: number;
  accountPolicy: AccountPolicy;
  paperConfig: PaperBrokerConfig;
  connections: BrokerConnection[];
  ledgers: Ledger[];
  agents: TradingAgent[];
  signals: TradingSignal[];
  proposals: TradeProposal[];
  orders: Order[];
  fills: Fill[];
  runs: AgentRun[];
  audit: AuditLog;
  knownClientOrderIDs: Set<string>;
  /** The latest real quote seen for each instrument. */
  quotes: Record<string, Quote>;
  stats: Record<string, InstrumentStats>;
  /** Agent id → the trading day its daily-loss notice was last sent, so it's sent once a day. */
  dailyLossNotified: Record<string, string>;
}

export const currentSchemaVersion = 1;

export function makeState(): TradingState {
  return {
    schemaVersion: currentSchemaVersion, accountPolicy: defaultAccountPolicy(), paperConfig: defaultPaperConfig(), connections: [],
    ledgers: [], agents: [], signals: [], proposals: [], orders: [], fills: [], runs: [], audit: makeAuditLog(),
    knownClientOrderIDs: new Set<string>(), quotes: {}, stats: {}, dailyLossNotified: {},
  };
}

/** The state as Swift's `TradingCodec` would write it (a set becomes a sorted list). */
export function stateToJSON(state: TradingState): Record<string, unknown> {
  return JSON.parse(JSON.stringify({ ...state, knownClientOrderIDs: Array.from(state.knownClientOrderIDs).sort() }));
}

/** Value equality the way Swift compares two structs: by content, key order ignored, absent = undefined. */
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  const keys = new Set([...Object.keys(x), ...Object.keys(y)]);
  for (const key of keys) {
    const l = x[key], r = y[key];
    if (l === undefined && r === undefined) continue;
    if (!deepEqual(l, r)) return false;
  }
  return true;
}

export function clone<T>(value: T): T {
  return structuredClone(value);
}
