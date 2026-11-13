// The audit trail: an append-only chain where each event carries the hash of the one
// before it, so an edited, removed or reordered event breaks the chain. A port of
// TradingCore/Sources/TradingCore/Audit.swift.
//
// The hash rule (`canonical` + SHA-256) is the contract between the phone, this module
// and the database trigger in supabase/migrations/20261113120000_trading_platform.sql:
// all three must produce the same hex for the same event. Pinned by
// TradingCore/Tests/Vectors/audit.json.

import type { ExecutionMode } from "./orders.ts";
import { roundAway } from "./rounding.ts";
import { sha256Hex } from "./sha256.ts";
import { sortedStrings } from "./text.ts";

export type AuditActor = "user" | "agent" | "system" | "copilot";

export type AuditKind =
  | "portfolioCreated" | "portfolioReset" | "portfolioDeleted"
  | "agentCreated" | "agentRenamed" | "agentDeleted" | "agentPaused" | "agentResumed" | "agentStopped"
  | "strategyChanged" | "riskPolicyChanged" | "modeChanged" | "liveRequestRefused"
  | "killSwitchEngaged" | "killSwitchReleased"
  | "signalGenerated"
  | "proposalCreated" | "proposalBlocked" | "proposalApproved" | "proposalRejected" | "proposalExpired" | "proposalFailed"
  | "orderSubmitted" | "orderRejected" | "orderPartiallyFilled" | "orderFilled" | "orderCanceled" | "orderExpired"
  | "backtestRun";

export const AUDIT_KINDS: AuditKind[] = ["portfolioCreated", "portfolioReset", "portfolioDeleted", "agentCreated", "agentRenamed",
  "agentDeleted", "agentPaused", "agentResumed", "agentStopped", "strategyChanged", "riskPolicyChanged", "modeChanged",
  "liveRequestRefused", "killSwitchEngaged", "killSwitchReleased", "signalGenerated", "proposalCreated", "proposalBlocked",
  "proposalApproved", "proposalRejected", "proposalExpired", "proposalFailed", "orderSubmitted", "orderRejected",
  "orderPartiallyFilled", "orderFilled", "orderCanceled", "orderExpired", "backtestRun"];

const TITLES: Record<AuditKind, string> = {
  portfolioCreated: "Paper portfolio created", portfolioReset: "Paper portfolio reset", portfolioDeleted: "Paper portfolio deleted",
  agentCreated: "Agent created", agentRenamed: "Agent renamed", agentDeleted: "Agent deleted", agentPaused: "Agent paused",
  agentResumed: "Agent resumed", agentStopped: "Agent stopped", strategyChanged: "Strategy changed",
  riskPolicyChanged: "Risk limits changed", modeChanged: "Mode changed", liveRequestRefused: "Live trading refused",
  killSwitchEngaged: "Kill switch turned on", killSwitchReleased: "Kill switch turned off", signalGenerated: "Signal",
  proposalCreated: "Trade proposed", proposalBlocked: "Trade blocked by risk rules", proposalApproved: "Proposal approved",
  proposalRejected: "Proposal rejected", proposalExpired: "Proposal expired", proposalFailed: "Proposal failed",
  orderSubmitted: "Order submitted", orderRejected: "Order rejected", orderPartiallyFilled: "Order partly filled",
  orderFilled: "Order filled", orderCanceled: "Order cancelled", orderExpired: "Order expired", backtestRun: "Backtest run",
};

export const auditKindTitle = (kind: AuditKind): string => TITLES[kind];

/** What a caller supplies for a new event; the chain fields are filled in on append. */
export interface AuditInput {
  time: number;
  actor: AuditActor;
  kind: AuditKind;
  summary: string;
  mode?: ExecutionMode;
  agentID?: string;
  ledgerID?: string;
  orderID?: string;
  proposalID?: string;
  instrumentID?: string;
  details?: Record<string, string>;
}

export interface AuditEvent {
  id: string;
  sequence: number;
  time: number;
  actor: AuditActor;
  kind: AuditKind;
  summary: string;
  mode?: ExecutionMode;
  agentID?: string;
  ledgerID?: string;
  orderID?: string;
  proposalID?: string;
  instrumentID?: string;
  details: Record<string, string>;
  previousHash: string;
  hash: string;
}

/** A UUID the way Swift prints it (upper case), which is the form the hash covers. */
export function uuidString(id: string | undefined): string {
  return id === undefined ? "" : id.toUpperCase();
}

/**
 * The text the hash covers. Time is taken to the millisecond so a save and reload can't
 * change it; detail keys are sorted so their order can't either.
 */
export function canonical(event: Omit<AuditEvent, "hash" | "id">): string {
  const ms = roundAway(event.time);
  const detailText = sortedStrings(Object.keys(event.details)).map((key) => `${key}=${event.details[key] ?? ""}`).join(";");
  return [
    event.previousHash, String(event.sequence), String(ms), event.actor, event.kind, event.summary,
    event.mode ?? "", uuidString(event.agentID), uuidString(event.ledgerID), uuidString(event.orderID),
    uuidString(event.proposalID), event.instrumentID ?? "", detailText,
  ].join("|");
}

export const digest = (text: string): string => sha256Hex(text);

export const genesisHash = "0".repeat(64);

export interface AuditVerification {
  isIntact: boolean;
  /** Sequence number of the first event that doesn't match, when the chain is broken. */
  brokenAtSequence?: number;
  eventCount: number;
}

/**
 * Append-only record of everything that changed money, orders, agents or limits.
 * There is no API to edit or delete an event.
 */
export interface AuditLog {
  events: AuditEvent[];
  /** Hash and sequence the stored events continue from, after old events are archived. */
  baseHash: string;
  baseSequence: number;
}

export function makeAuditLog(baseHash = genesisHash, baseSequence = 0): AuditLog {
  return { events: [], baseHash, baseSequence };
}

export function lastHash(log: AuditLog): string {
  return log.events.length > 0 ? log.events[log.events.length - 1].hash : log.baseHash;
}

export function nextSequence(log: AuditLog): number {
  return (log.events.length > 0 ? log.events[log.events.length - 1].sequence : log.baseSequence) + 1;
}

export function appendAudit(log: AuditLog, id: string, input: AuditInput): AuditEvent {
  const event: AuditEvent = {
    id, sequence: nextSequence(log), time: input.time, actor: input.actor, kind: input.kind, summary: input.summary,
    details: input.details ?? {}, previousHash: lastHash(log), hash: "",
  };
  if (input.mode !== undefined) event.mode = input.mode;
  if (input.agentID !== undefined) event.agentID = input.agentID;
  if (input.ledgerID !== undefined) event.ledgerID = input.ledgerID;
  if (input.orderID !== undefined) event.orderID = input.orderID;
  if (input.proposalID !== undefined) event.proposalID = input.proposalID;
  if (input.instrumentID !== undefined) event.instrumentID = input.instrumentID;
  event.hash = digest(canonical(event));
  log.events.push(event);
  return event;
}

/** Recomputes every hash from the base. Any tampering shows up as a break. */
export function verifyAudit(log: AuditLog): AuditVerification {
  return verifyEvents(log.events, log.baseHash, log.baseSequence);
}

/** The same check over a bare list of events (for a chain read back from the database). */
export function verifyEvents(events: AuditEvent[], baseHash = genesisHash, baseSequence = 0): AuditVerification {
  let previous = baseHash;
  let expected = baseSequence + 1;
  for (const event of events) {
    if (event.sequence !== expected || event.previousHash !== previous || digest(canonical(event)) !== event.hash) {
      return { isIntact: false, brokenAtSequence: event.sequence, eventCount: events.length };
    }
    previous = event.hash;
    expected += 1;
  }
  return { isIntact: true, eventCount: events.length };
}

/**
 * Drops the oldest events beyond `limit`, keeping the chain verifiable from the new base.
 * Returns what was removed so a caller can archive it.
 */
export function archiveAudit(log: AuditLog, limit: number): AuditEvent[] {
  if (!(log.events.length > limit && limit > 0)) return [];
  const removed = log.events.splice(0, log.events.length - limit);
  const last = removed[removed.length - 1];
  if (last) {
    log.baseHash = last.hash;
    log.baseSequence = last.sequence;
  }
  return removed;
}
