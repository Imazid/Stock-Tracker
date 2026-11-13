// Agents, signals, proposals and run traces. A port of
// TradingCore/Sources/TradingCore/Agent.swift.

import type { Evidence, ExitReason, SignalAction, SignalDecision } from "./evaluator.ts";
import type { DataProvenance, Instrument } from "./market.ts";
import type { ExecutionMode, OrderSide } from "./orders.ts";
import type { RiskPolicy, RiskReport } from "./risk.ts";
import * as Rounding from "./rounding.ts";
import type { StrategySpec } from "./strategy.ts";

/**
 * How much an agent is allowed to do. Each step up is a separate, deliberate choice;
 * nothing is ever promoted automatically.
 *   researchOnly      watches and reports; no signals, no orders
 *   signals           buy / sell / hold signals with evidence; no orders
 *   paper             trades a simulated portfolio
 *   approvalRequired  proposes real orders; each needs a person's approval (not available)
 *   autonomousLive    places real orders by itself (not available)
 */
export type AgentMode = "researchOnly" | "signals" | "paper" | "approvalRequired" | "autonomousLive";
export const AGENT_MODES: AgentMode[] = ["researchOnly", "signals", "paper", "approvalRequired", "autonomousLive"];

export function agentModeDisplayName(mode: AgentMode): string {
  switch (mode) {
    case "researchOnly": return "Research only";
    case "signals": return "Signals";
    case "paper": return "Paper trading";
    case "approvalRequired": return "Approval required";
    case "autonomousLive": return "Autonomous";
  }
}

export const modeIsLive = (mode: AgentMode): boolean => mode === "approvalRequired" || mode === "autonomousLive";
export const modePlacesOrders = (mode: AgentMode): boolean => mode === "paper" || modeIsLive(mode);
export const modeProducesSignals = (mode: AgentMode): boolean => mode !== "researchOnly";

export type AgentStatus = "active" | "paused" | "stopped";
export type PauseReason = "user" | "killSwitch" | "dailyLossLimit" | "drawdownLimit" | "repeatedErrors";

export function pauseExplanation(reason: PauseReason): string {
  switch (reason) {
    case "user": return "Paused by you.";
    case "killSwitch": return "Paused by the kill switch.";
    case "dailyLossLimit": return "Paused: today's loss reached the daily limit.";
    case "drawdownLimit": return "Paused: the portfolio fell to its drawdown limit.";
    case "repeatedErrors": return "Paused after repeated errors.";
  }
}

export type ChangeAuthor = "user" | "copilot" | "template";
export const CHANGE_AUTHORS: ChangeAuthor[] = ["user", "copilot", "template"];

/**
 * One saved version of an agent's strategy. Versions are only ever added, so every signal
 * and trade can name the exact rules that produced it.
 */
export interface StrategyVersion {
  version: number;
  spec: StrategySpec;
  createdAt: number;
  note: string;
  author: ChangeAuthor;
}

export interface AgentSchedule {
  /** Minutes between runs. */
  intervalMinutes: number;
}

export const hourly = (): AgentSchedule => ({ intervalMinutes: 60 });

export function scheduleDisplayName(schedule: AgentSchedule): string {
  const m = schedule.intervalMinutes;
  if (m < 60) return `Every ${m} minutes`;
  if (m === 60) return "Every hour";
  if (m === 1_440) return "Once a day";
  return m % 60 === 0 ? `Every ${m / 60} hours` : `Every ${m} minutes`;
}

export interface TradingAgent {
  id: string;
  name: string;
  templateID?: string;
  mode: AgentMode;
  status: AgentStatus;
  pauseReason?: PauseReason;
  /** Never empty: version 1 is written when the agent is created. */
  versions: StrategyVersion[];
  riskPolicy: RiskPolicy;
  ledgerID?: string;
  /** Money assigned to this agent, in its ledger's currency. */
  budget: number;
  /** Paper trades wait for approval instead of executing straight away. */
  reviewEachPaperTrade: boolean;
  schedule: AgentSchedule;
  createdAt: number;
  lastRunAt?: number;
  nextRunAt?: number;
  consecutiveErrors: number;
  lastError?: string;
}

export function makeAgent(fields: {
  id: string; name: string; templateID?: string; mode: AgentMode; spec: StrategySpec; riskPolicy: RiskPolicy; ledgerID?: string;
  budget: number; reviewEachPaperTrade?: boolean; schedule?: AgentSchedule; createdAt: number; author?: ChangeAuthor;
}): TradingAgent {
  const agent: TradingAgent = {
    id: fields.id, name: fields.name, mode: fields.mode, status: "active",
    versions: [{ version: 1, spec: fields.spec, createdAt: fields.createdAt, note: "Created", author: fields.author ?? "user" }],
    riskPolicy: fields.riskPolicy, budget: fields.budget, reviewEachPaperTrade: fields.reviewEachPaperTrade ?? false,
    schedule: fields.schedule ?? hourly(), createdAt: fields.createdAt, nextRunAt: fields.createdAt, consecutiveErrors: 0,
  };
  if (fields.templateID !== undefined) agent.templateID = fields.templateID;
  if (fields.ledgerID !== undefined) agent.ledgerID = fields.ledgerID;
  return agent;
}

export const currentVersion = (agent: TradingAgent): StrategyVersion => agent.versions[agent.versions.length - 1];
export const agentSpec = (agent: TradingAgent): StrategySpec => currentVersion(agent).spec;
export const strategyVersion = (agent: TradingAgent): number => currentVersion(agent).version;

export function isDue(agent: TradingAgent, now: number): boolean {
  if (agent.status !== "active") return false;
  if (agent.nextRunAt === undefined) return true;
  return now >= agent.nextRunAt;
}

// MARK: - Signals and proposals

export interface TradingSignal {
  id: string;
  agentID: string;
  strategyVersion: number;
  instrument: Instrument;
  action: SignalAction;
  headline: string;
  evidence: Evidence[];
  barTime: number;
  close: number;
  ruleMargin?: number;
  exitReason?: ExitReason;
  createdAt: number;
  provenance: DataProvenance;
}

export function makeSignal(id: string, agentID: string, version: number, instrument: Instrument, decision: SignalDecision,
  createdAt: number, provenance: DataProvenance): TradingSignal {
  const signal: TradingSignal = {
    id, agentID, strategyVersion: version, instrument, action: decision.action, headline: decision.headline,
    evidence: decision.evidence, barTime: decision.barTime, close: decision.close, createdAt, provenance,
  };
  if (decision.ruleMargin !== undefined) signal.ruleMargin = decision.ruleMargin;
  if (decision.exitReason !== undefined) signal.exitReason = decision.exitReason;
  return signal;
}

/**
 *   pending    waiting for a person to approve or reject it
 *   submitted  an order was submitted for it (whether that order filled is the order's story)
 *   blocked    the risk engine refused it; no order was ever created
 *   failed     approved, but the order could not be submitted
 */
export type ProposalStatus = "pending" | "submitted" | "rejected" | "expired" | "blocked" | "failed";

export function proposalStatusDisplayName(status: ProposalStatus): string {
  switch (status) {
    case "pending": return "Needs approval";
    case "submitted": return "Order submitted";
    case "rejected": return "Rejected";
    case "expired": return "Expired";
    case "blocked": return "Blocked by risk rules";
    case "failed": return "Failed";
  }
}

/**
 * A sized order an agent wants to place, with the risk engine's verdict attached.
 * A proposal is a suggestion. It is not an order and it is not a fill.
 */
export interface TradeProposal {
  id: string;
  agentID: string;
  signalID: string;
  strategyVersion: number;
  ledgerID: string;
  instrument: Instrument;
  side: OrderSide;
  quantity: number;
  referencePrice: number;
  notional: number;
  estimatedFee: number;
  mode: ExecutionMode;
  status: ProposalStatus;
  risk: RiskReport;
  headline: string;
  sizingNote?: string;
  signalBarTime: number;
  createdAt: number;
  expiresAt: number;
  resolvedAt?: number;
  resolutionNote?: string;
  orderID?: string;
  clientOrderID: string;
}

export function makeProposal(fields: Omit<TradeProposal, "notional" | "clientOrderID" | "resolvedAt" | "resolutionNote" | "orderID">): TradeProposal {
  const proposal: TradeProposal = {
    ...fields,
    notional: Rounding.money(fields.quantity * fields.referencePrice),
    // One order per proposal, ever: the key is derived from the proposal itself.
    clientOrderID: `proposal-${fields.id.toUpperCase()}`,
  };
  if (proposal.sizingNote === undefined) delete proposal.sizingNote;
  return proposal;
}

// MARK: - Run traces

export type RunTrigger = "schedule" | "manual";
export type RunStatus = "completed" | "skipped" | "failed";
export type StepKind = "data" | "research" | "signal" | "sizing" | "risk" | "proposal" | "execution" | "note";
export type StepOutcome = "ok" | "info" | "warning" | "blocked" | "failed";

/** One thing the agent did or saw during a run. */
export interface RunStep {
  id: string;
  kind: StepKind;
  outcome: StepOutcome;
  instrumentID?: string;
  title: string;
  detail: string;
  evidence: Evidence[];
}

/**
 * The full trace of one agent run: what it looked at, what it concluded, which rules
 * passed or failed, and what (if anything) was ordered.
 */
export interface AgentRun {
  id: string;
  agentID: string;
  strategyVersion: number;
  trigger: RunTrigger;
  startedAt: number;
  finishedAt: number;
  status: RunStatus;
  summary: string;
  steps: RunStep[];
  signalIDs: string[];
  proposalIDs: string[];
  orderIDs: string[];
}

export function makeRun(id: string, agentID: string, version: number, trigger: RunTrigger, startedAt: number): AgentRun {
  return {
    id, agentID, strategyVersion: version, trigger, startedAt, finishedAt: startedAt, status: "completed", summary: "",
    steps: [], signalIDs: [], proposalIDs: [], orderIDs: [],
  };
}
