// The single place trading state changes. A port of
// TradingCore/Sources/TradingCore/TradingEngine.swift and TradingEngine+Agents.swift.
//
// Every method takes the time and the market data it needs as arguments and touches
// nothing outside `state`, so a test can replay any sequence of events and get the same
// result every time. The pipeline is ordinary code end to end:
//
//   market data → strategy rules → signal → sizing → risk engine → proposal
//       → (approval) → order → simulated fill → ledger → audit trail
//
// Nothing here reaches a real broker. Orders are matched by the built-in simulator, the
// live paths refuse with the reason, and no language model is consulted anywhere.
//
// Swift's engine works on value types; this one changes objects in place. Where the Swift
// relies on a copy (the risk engine's rolled-over view of a ledger, a strategy handed in
// by a caller) a copy is taken here too.

import {
  type AgentMode, agentModeDisplayName, type AgentRun, type AgentSchedule, agentSpec, type ChangeAuthor, isDue, makeAgent,
  makeProposal, makeRun, makeSignal, modeIsLive, modePlacesOrders, pauseExplanation, type PauseReason, proposalStatusDisplayName,
  type RunStep, type RunTrigger, type StepKind, type StepOutcome, strategyVersion, type TradeProposal, type TradingAgent,
  type TradingSignal,
} from "./agent.ts";
import { appendAudit, archiveAudit, type AuditActor, type AuditInput, uuidString } from "./audit.ts";
import { LiveVenues, PaperBroker } from "./broker.ts";
import * as Calendar from "./calendar.ts";
import { Currencies } from "./currencies.ts";
import { decide, decideDCA, type Evidence, monthlyRebalanceTrades, rebalanceTrades, researchFacts, type SignalDecision } from "./evaluator.ts";
import {
  applyFill, drawdownPct, equity as ledgerEquity, type Ledger, ledgerDayKey, makeLedger, mark as markLedger, marketValue,
  averageCost, position as ledgerPosition, rolledCopy,
} from "./ledger.ts";
import {
  type Bar, barName, type DataProvenance, type Instrument, instrumentID, type InstrumentStats, isRealMarketData,
  type MarketSnapshot, type Quote, quoteSpreadBps,
} from "./market.ts";
import {
  agentSource, type ExecutionMode, type Fill, isOpenStatus, isTerminalStatus, type Order, type OrderRequest, type OrderSide,
  type OrderSource, type OrderStatus, orderStatusDisplayName, orderTypeDisplayName, remainingQuantity, transition,
} from "./orders.ts";
import {
  type AgentRiskView, evaluate as evaluateRisk, intentNotional, isApproved, makePolicy, type OrderIntent, policyIssues,
  quantityText, reportFailures, reportSummary, reportWarnings, type RiskContext, type RiskPolicy, type RiskReport, riskCheckTitle,
} from "./risk.ts";
import * as Rounding from "./rounding.ts";
import {
  type AgentDraft, clone, connectionCanTrade, deepEqual, draftCurrency, type EngineNotice, makeState, type OrderPreview, type OrderResult,
  resolvedPolicy, TradingError, type TradingState,
} from "./state.ts";
import { type StrategySpec, validate as validateSpec } from "./strategy.ts";
import { capitalized, cFixed, characterCount, NumberText, sortedStrings, swiftDouble, swiftTrim, trimNumber } from "./text.ts";

interface Sized {
  quantity: number;
  price: number;
  fee: number;
  modelledSpread: boolean;
}

export interface EngineOptions {
  /** Makes ids for new records. Defaults to random UUIDs. */
  newID?: () => string;
}

/** The practice budget range in US dollars. Other currencies: `Currencies.budgetRange`. */
export const budgetRange = Currencies.budgetRange("USD");

/**
 * Limits for an order a person places by hand in a paper portfolio: the hard rules (funds,
 * holdings, exchange rules, real fresh data) still apply; the sizing limits that exist to
 * bound an agent do not.
 */
export function manualPolicy(equity: number): RiskPolicy {
  return {
    maxOrderNotional: Math.max(equity, 1) * 10, maxPositionPct: 100, maxDailyNotional: Math.max(equity, 1) * 100,
    maxDailyLossPct: 100, maxDrawdownPct: 100, maxOpenPositions: 100, maxSpreadBps: 500, maxQuoteAgeSeconds: 900,
    minAverageDollarVolume: 0, maxDailyVolatilityPct: 1_000, cooldownSeconds: 0, maxPriceGapPct: 10, allowQueueOutsideHours: true,
  };
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

export class TradingEngine {
  state: TradingState;
  private pending: EngineNotice[] = [];
  private readonly newID: () => string;

  constructor(state: TradingState = makeState(), options: EngineOptions = {}) {
    this.state = state;
    this.newID = options.newID ?? (() => crypto.randomUUID());
  }

  /** Things worth telling the person about since the last call. */
  drainNotices(): EngineNotice[] {
    const out = this.pending;
    this.pending = [];
    return out;
  }

  private notify(notice: Partial<EngineNotice> & Pick<EngineNotice, "kind" | "title" | "body">): void {
    const out: EngineNotice = { kind: notice.kind, title: notice.title, body: notice.body, mode: notice.mode ?? "paper" };
    if (notice.agentID !== undefined) out.agentID = notice.agentID;
    if (notice.orderID !== undefined) out.orderID = notice.orderID;
    if (notice.proposalID !== undefined) out.proposalID = notice.proposalID;
    if (notice.instrumentID !== undefined) out.instrumentID = notice.instrumentID;
    this.pending.push(out);
  }

  private audit(input: AuditInput): void {
    appendAudit(this.state.audit, this.newID(), input);
  }

  ledger(id: string | undefined): Ledger | undefined {
    return id === undefined ? undefined : this.state.ledgers.find((l) => l.id === id);
  }

  agent(id: string | undefined): TradingAgent | undefined {
    return id === undefined ? undefined : this.state.agents.find((a) => a.id === id);
  }

  // MARK: - Paper portfolios

  createPaperPortfolio(name: string, startingCash: number, currency: string, now: number): Ledger {
    const clean = swiftTrim(name);
    const problems: string[] = [];
    if (clean === "" || characterCount(clean) > 40) problems.push("Give the portfolio a name of up to 40 characters.");
    const range = Currencies.budgetRange(currency);
    if (!Currencies.isSupported(currency)) {
      problems.push(`Practice portfolios can be held in ${Currencies.supported.join(", ")}.`);
    } else if (!(Number.isFinite(startingCash) && startingCash >= range.lowerBound && startingCash <= range.upperBound)) {
      problems.push(`The starting balance must be between ${NumberText.money(range.lowerBound, currency)} and ${NumberText.money(range.upperBound, currency)}.`);
    }
    if (problems.length > 0) throw TradingError.invalid(problems);
    const ledger = makeLedger({ id: this.newID(), name: clean, kind: "manualPaper", currency, startingCash, createdAt: now });
    this.state.ledgers.push(ledger);
    this.audit({
      time: now, actor: "user", kind: "portfolioCreated",
      summary: `Paper portfolio "${clean}" created with ${NumberText.money(ledger.startingCash, currency)}.`,
      mode: "paper", ledgerID: ledger.id, details: { startingCash: swiftDouble(ledger.startingCash), currency },
    });
    return ledger;
  }

  /** Puts a paper portfolio back to its starting balance. Open orders are cancelled first. */
  resetPaperPortfolio(id: string, now: number): void {
    const index = this.state.ledgers.findIndex((l) => l.id === id);
    if (index < 0) throw TradingError.notFound("That portfolio");
    const old = this.state.ledgers[index];
    for (const order of this.state.orders.slice()) {
      if (order.ledgerID === id && isOpenStatus(order.status)) this.cancelOrder(order.id, now, "system", "Portfolio reset.");
    }
    const equityBefore = Rounding.money(ledgerEquity(old));
    const fresh = makeLedger({ id: old.id, name: old.name, kind: old.kind, currency: old.currency, agentID: old.agentID, startingCash: old.startingCash, createdAt: now });
    fresh.mode = old.mode;
    this.state.ledgers[index] = fresh;
    this.audit({
      time: now, actor: "user", kind: "portfolioReset",
      summary: `"${old.name}" reset to ${NumberText.money(old.startingCash, old.currency)}.`,
      mode: "paper", ledgerID: id, details: { equityBefore: swiftDouble(equityBefore) },
    });
  }

  deletePaperPortfolio(id: string, now: number): void {
    const ledger = this.ledger(id);
    if (!ledger) throw TradingError.notFound("That portfolio");
    const user = this.state.agents.find((a) => a.ledgerID === id);
    if (user) throw TradingError.notAllowed(`${user.name} uses this portfolio. Delete the agent first.`);
    for (const order of this.state.orders.slice()) {
      if (order.ledgerID === id && isOpenStatus(order.status)) this.cancelOrder(order.id, now, "system", "Portfolio deleted.");
    }
    this.state.ledgers = this.state.ledgers.filter((l) => l.id !== id);
    this.audit({ time: now, actor: "user", kind: "portfolioDeleted", summary: `Paper portfolio "${ledger.name}" deleted.`, mode: "paper", ledgerID: id });
  }

  /** Records that a backtest was run, so the audit trail shows what a decision was based on. */
  noteBacktest(title: string, summary: string, now: number, options: { agentID?: string; actor?: AuditActor; details?: Record<string, string> } = {}): void {
    const input: AuditInput = {
      time: now, actor: options.actor ?? "user", kind: "backtestRun", summary: `Backtest of ${title}: ${summary}`, details: options.details ?? {},
    };
    if (options.agentID !== undefined) input.agentID = options.agentID;
    this.audit(input);
  }

  // MARK: - Live eligibility

  /** Why real-money trading can't be used in a given mode. Empty means it could be. */
  liveBlockers(mode?: AgentMode): string[] {
    const reasons: string[] = [];
    const tradingConnection = this.state.connections.find((connection) =>
      connection.environment === "live" && connectionCanTrade(connection) &&
      LiveVenues.all.some((venue) => venue.adapterID === connection.adapterID && venue.isExecutionEnabled));
    if (!tradingConnection) {
      if (this.state.connections.some((connection) => connection.environment === "live" && !connectionCanTrade(connection))) {
        reasons.push("Your broker connection is read-only, so it can't place orders.");
      } else {
        reasons.push("No trading account is connected.");
      }
    }
    const live = this.state.accountPolicy.live;
    if (mode === "approvalRequired") {
      if (!live.approvalAgentsEnabled) reasons.push("Live trading for agents hasn't been switched on for this account.");
    } else if (mode === "autonomousLive") {
      if (!live.autonomousAgentsEnabled) reasons.push("Autonomous live trading hasn't been authorised for this account.");
    } else if (!live.manualOrdersEnabled) {
      reasons.push("Live trading hasn't been switched on for this account.");
    }
    return reasons;
  }

  private refuseLive(reasons: string[]): TradingError {
    return TradingError.liveNotAvailable(reasons.length === 0 ? ["Live trading isn't available in this version."] : reasons);
  }

  // MARK: - Agents

  createAgent(draft: AgentDraft, now: number): TradingAgent {
    const name = swiftTrim(draft.name);
    const problems: string[] = [];
    if (name === "" || characterCount(name) > 40) problems.push("Give the agent a name of up to 40 characters.");
    problems.push(...validateSpec(draft.spec).filter((issue) => issue.severity === "error").map((issue) => issue.message));
    const policy = clone(resolvedPolicy(draft));
    problems.push(...policyIssues(policy));
    if (draft.mode === "paper" && draft.spec.kind === "research") {
      problems.push("A research strategy can't trade. Choose Research only, or pick a trading strategy.");
    }
    if (!(Number.isInteger(draft.schedule.intervalMinutes) && draft.schedule.intervalMinutes >= 5 && draft.schedule.intervalMinutes <= 10_080)) {
      problems.push("An agent can run between every 5 minutes and once a week.");
    }
    const currency = draftCurrency(draft);
    const range = Currencies.budgetRange(currency);
    if (draft.mode === "paper" && draft.attachToLedgerID === undefined &&
      !(Number.isFinite(draft.budget) && draft.budget >= range.lowerBound && draft.budget <= range.upperBound)) {
      problems.push(`The budget must be between ${NumberText.money(range.lowerBound, currency)} and ${NumberText.money(range.upperBound, currency)}.`);
    }
    if (draft.spec.followsLedgerPositions && draft.attachToLedgerID === undefined && draft.mode === "paper") {
      problems.push("Choose the portfolio this agent should watch.");
    }
    if (problems.length > 0) throw TradingError.invalid(problems);

    if (modeIsLive(draft.mode)) {
      const reasons = this.liveBlockers(draft.mode);
      this.audit({
        time: now, actor: "user", kind: "liveRequestRefused",
        summary: `Refused to create "${name}" in ${agentModeDisplayName(draft.mode)} mode.`, details: { reasons: reasons.join(" ") },
      });
      throw this.refuseLive(reasons);
    }

    const agent = makeAgent({
      id: this.newID(), name, templateID: draft.templateID, mode: draft.mode, spec: clone(draft.spec), riskPolicy: policy,
      budget: Rounding.money(draft.budget), reviewEachPaperTrade: draft.reviewEachPaperTrade, schedule: { ...draft.schedule },
      createdAt: now, author: draft.author,
    });
    if (draft.mode === "paper") {
      if (draft.attachToLedgerID !== undefined) {
        const ledger = this.ledger(draft.attachToLedgerID);
        if (!ledger) throw TradingError.notFound("That portfolio");
        const currency = draft.spec.universe[0]?.currency;
        if (currency !== undefined && currency !== ledger.currency) {
          throw TradingError.invalid([`This portfolio holds ${ledger.currency} but the strategy trades ${currency}.`]);
        }
        agent.ledgerID = draft.attachToLedgerID;
        agent.budget = Rounding.money(ledgerEquity(ledger));
      } else {
        agent.ledgerID = this.makeAgentLedger(agent, now);
      }
    }
    this.state.agents.push(agent);
    const spec = agentSpec(agent);
    const event: AuditInput = {
      time: now, actor: draft.author === "copilot" ? "copilot" : "user", kind: "agentCreated",
      summary: `${name} created in ${agentModeDisplayName(agent.mode)} mode: ${spec.title}.`, agentID: agent.id,
      details: {
        mode: agent.mode, strategyVersion: "1", budget: swiftDouble(agent.budget),
        assets: spec.universe.map((instrument) => instrument.symbol).join(","),
      },
    };
    if (modePlacesOrders(agent.mode)) event.mode = "paper";
    if (agent.ledgerID !== undefined) event.ledgerID = agent.ledgerID;
    this.audit(event);
    return agent;
  }

  private makeAgentLedger(agent: TradingAgent, now: number): string {
    const currency = agentSpec(agent).universe[0]?.currency ?? "USD";
    const ledger = makeLedger({ id: this.newID(), name: agent.name, kind: "agentPaper", currency, agentID: agent.id, startingCash: agent.budget, createdAt: now });
    this.state.ledgers.push(ledger);
    return ledger.id;
  }

  private agentIndex(id: string): number {
    const index = this.state.agents.findIndex((a) => a.id === id);
    if (index < 0) throw TradingError.notFound("That agent");
    return index;
  }

  /** Saves a new strategy version. Old versions are kept so past trades stay explainable. */
  updateStrategy(agentID: string, spec: StrategySpec, note: string, now: number, author: ChangeAuthor = "user"): void {
    const agent = this.state.agents[this.agentIndex(agentID)];
    const problems = validateSpec(spec).filter((issue) => issue.severity === "error").map((issue) => issue.message);
    if (problems.length > 0) throw TradingError.invalid(problems);
    const ledger = this.ledger(agent.ledgerID);
    const currency = spec.universe[0]?.currency;
    if (ledger && currency !== undefined && currency !== ledger.currency) {
      throw TradingError.invalid([`This agent's portfolio holds ${ledger.currency}; the new assets trade in ${currency}.`]);
    }
    if (agent.mode === "paper" && spec.kind === "research") {
      throw TradingError.invalid(["A research strategy can't trade. Switch the agent to Research only first."]);
    }
    if (deepEqual(spec, agentSpec(agent))) return;
    const version = strategyVersion(agent) + 1;
    agent.versions.push({ version, spec: clone(spec), createdAt: now, note: note === "" ? "Updated" : note, author });
    // Proposals made under the old rules shouldn't be approved under the new ones.
    this.expirePendingProposals(agentID, "The strategy changed.", now);
    this.audit({
      time: now, actor: author === "copilot" ? "copilot" : "user", kind: "strategyChanged",
      summary: `${agent.name}: strategy updated to version ${version}. ${note}`, agentID, details: { strategyVersion: String(version) },
    });
  }

  updateRiskPolicy(agentID: string, policy: RiskPolicy, now: number, actor: AuditActor = "user"): void {
    const agent = this.state.agents[this.agentIndex(agentID)];
    const issues = policyIssues(policy);
    if (issues.length > 0) throw TradingError.invalid(issues);
    const old = agent.riskPolicy;
    if (deepEqual(old, policy)) return;
    agent.riskPolicy = clone(policy);
    this.expirePendingProposals(agentID, "The risk limits changed.", now);
    const change = (a: number, b: number) => `${swiftDouble(a)} → ${swiftDouble(b)}`;
    this.audit({
      time: now, actor, kind: "riskPolicyChanged", summary: `${agent.name}: risk limits changed.`, agentID,
      details: {
        maxOrderNotional: change(old.maxOrderNotional, policy.maxOrderNotional),
        maxPositionPct: change(old.maxPositionPct, policy.maxPositionPct),
        maxDailyNotional: change(old.maxDailyNotional, policy.maxDailyNotional),
        maxDailyLossPct: change(old.maxDailyLossPct, policy.maxDailyLossPct),
        maxDrawdownPct: change(old.maxDrawdownPct, policy.maxDrawdownPct),
      },
    });
  }

  setMode(agentID: string, mode: AgentMode, now: number): void {
    const agent = this.state.agents[this.agentIndex(agentID)];
    const previous = agent.mode;
    if (previous === mode) return;
    if (modeIsLive(mode)) {
      const reasons = this.liveBlockers(mode);
      this.audit({
        time: now, actor: "user", kind: "liveRequestRefused",
        summary: `${agent.name}: refused to switch to ${agentModeDisplayName(mode)}.`, agentID, details: { reasons: reasons.join(" ") },
      });
      throw this.refuseLive(reasons);
    }
    if (mode === "paper" && agentSpec(agent).kind === "research") {
      throw TradingError.invalid(["A research strategy can't trade. Change the strategy first."]);
    }
    if (!modePlacesOrders(mode)) {
      // Leaving paper trading: nothing may be left waiting to trade.
      this.expirePendingProposals(agentID, "The agent no longer places orders.", now);
      for (const order of this.state.orders.slice()) {
        if (order.source.agentID === agentID && isOpenStatus(order.status)) {
          this.cancelOrder(order.id, now, "system", "The agent no longer places orders.");
        }
      }
    }
    agent.mode = mode;
    if (mode === "paper" && agent.ledgerID === undefined) agent.ledgerID = this.makeAgentLedger(agent, now);
    this.audit({
      time: now, actor: "user", kind: "modeChanged",
      summary: `${agent.name}: mode changed from ${agentModeDisplayName(previous)} to ${agentModeDisplayName(mode)}.`,
      agentID, details: { from: previous, to: mode },
    });
  }

  setReviewEachPaperTrade(agentID: string, review: boolean, now: number): void {
    const agent = this.state.agents[this.agentIndex(agentID)];
    if (agent.reviewEachPaperTrade === review) return;
    agent.reviewEachPaperTrade = review;
    this.audit({
      time: now, actor: "user", kind: "modeChanged",
      summary: `${agent.name}: paper trades now ${review ? "wait for your approval" : "execute automatically"}.`,
      agentID, details: { reviewEachPaperTrade: String(review) },
    });
  }

  setSchedule(agentID: string, schedule: AgentSchedule, now: number): void {
    const agent = this.state.agents[this.agentIndex(agentID)];
    if (!(Number.isInteger(schedule.intervalMinutes) && schedule.intervalMinutes >= 5 && schedule.intervalMinutes <= 10_080)) {
      throw TradingError.invalid(["An agent can run between every 5 minutes and once a week."]);
    }
    agent.schedule = { intervalMinutes: schedule.intervalMinutes };
    agent.nextRunAt = (agent.lastRunAt ?? now) + schedule.intervalMinutes * 60_000;
  }

  renameAgent(id: string, name: string, now: number): void {
    const agent = this.state.agents[this.agentIndex(id)];
    const clean = swiftTrim(name);
    if (clean === "" || characterCount(clean) > 40) throw TradingError.invalid(["Give the agent a name of up to 40 characters."]);
    const old = agent.name;
    if (old === clean) return;
    agent.name = clean;
    const ledger = this.state.ledgers.find((l) => l.agentID === id && l.kind === "agentPaper");
    if (ledger) ledger.name = clean;
    this.audit({ time: now, actor: "user", kind: "agentRenamed", summary: `${old} renamed to ${clean}.`, agentID: id });
  }

  /** Stops an agent acting. Its open orders are cancelled; its positions are left alone. */
  pauseAgent(id: string, now: number, reason: PauseReason = "user"): void {
    const agent = this.state.agents[this.agentIndex(id)];
    if (agent.status !== "active") return;
    agent.status = "paused";
    agent.pauseReason = reason;
    let cancelled = 0;
    for (const order of this.state.orders.slice()) {
      if (order.source.agentID === id && isOpenStatus(order.status)) {
        if (this.cancelOrder(order.id, now, "system", "The agent was paused.")) cancelled += 1;
      }
    }
    const ledger = this.ledger(agent.ledgerID);
    const openPositions = ledger ? (ledger.kind === "agentPaper" ? ledger.positions.length : 0) : 0;
    this.audit({
      time: now, actor: reason === "user" ? "user" : "system", kind: "agentPaused",
      summary: `${agent.name} paused. ${pauseExplanation(reason)}`, agentID: id,
      details: { reason, ordersCancelled: String(cancelled), openPositions: String(openPositions) },
    });
    if (reason !== "user" && reason !== "killSwitch") {
      const tail = openPositions > 0 ? ` It still holds ${plural(openPositions, "position")}.` : "";
      this.notify({ kind: "agentPaused", title: `${agent.name} paused`, body: pauseExplanation(reason) + tail, agentID: id });
    }
  }

  resumeAgent(id: string, now: number): void {
    const agent = this.state.agents[this.agentIndex(id)];
    if (agent.status !== "paused") return;
    if (this.state.accountPolicy.killSwitchEngaged) {
      throw TradingError.notAllowed("The kill switch is on. Turn it off before resuming an agent.");
    }
    agent.status = "active";
    delete agent.pauseReason;
    agent.consecutiveErrors = 0;
    agent.nextRunAt = now;
    this.audit({ time: now, actor: "user", kind: "agentResumed", summary: `${agent.name} resumed.`, agentID: id });
  }

  /** Removes an agent. Its paper portfolio goes with it; the audit trail does not. */
  deleteAgent(id: string, now: number): void {
    const index = this.agentIndex(id);
    const agent = this.state.agents[index];
    for (const order of this.state.orders.slice()) {
      if (order.source.agentID === id && isOpenStatus(order.status)) this.cancelOrder(order.id, now, "system", "The agent was deleted.");
    }
    this.expirePendingProposals(id, "The agent was deleted.", now);
    this.state.agents.splice(index, 1);
    this.state.ledgers = this.state.ledgers.filter((l) => !(l.agentID === id && l.kind === "agentPaper"));
    this.audit({ time: now, actor: "user", kind: "agentDeleted", summary: `${agent.name} deleted.`, agentID: id });
  }

  // MARK: - Kill switch

  /**
   * Stops every agent at once: pauses them, cancels their open orders and expires their
   * pending proposals. Positions are not sold — closing them is the person's call.
   * Returns how many orders were cancelled.
   */
  engageKillSwitch(now: number): number {
    const policy = this.state.accountPolicy;
    if (policy.killSwitchEngaged) return 0;
    policy.killSwitchEngaged = true;
    policy.killSwitchAt = now;
    let cancelled = 0;
    for (const order of this.state.orders.slice()) {
      if (order.source.kind === "agent" && isOpenStatus(order.status)) {
        if (this.cancelOrder(order.id, now, "system", "Kill switch.")) cancelled += 1;
      }
    }
    let paused = 0;
    for (const agent of this.state.agents.filter((a) => a.status === "active")) {
      this.pauseAgent(agent.id, now, "killSwitch");
      this.expirePendingProposals(agent.id, "Kill switch.", now);
      paused += 1;
    }
    this.audit({
      time: now, actor: "user", kind: "killSwitchEngaged",
      summary: `Kill switch turned on: ${plural(paused, "agent")} paused, ${plural(cancelled, "order")} cancelled.`,
      details: { agentsPaused: String(paused), ordersCancelled: String(cancelled) },
    });
    return cancelled;
  }

  /** Turns the kill switch off. Agents stay paused until each one is resumed by hand. */
  releaseKillSwitch(now: number): void {
    const policy = this.state.accountPolicy;
    if (!policy.killSwitchEngaged) return;
    policy.killSwitchEngaged = false;
    delete policy.killSwitchAt;
    this.audit({ time: now, actor: "user", kind: "killSwitchReleased", summary: "Kill switch turned off. Agents stay paused until you resume them." });
  }

  // MARK: - Orders

  private policyFor(source: OrderSource, ledger: Ledger): RiskPolicy {
    const agent = this.agent(source.agentID);
    return agent ? agent.riskPolicy : manualPolicy(ledgerEquity(ledger));
  }

  /** Turns a request into a quantity and the worst price it could trade at right now. */
  private size(request: OrderRequest): Sized {
    const rules = PaperBroker.rules(request.instrument);
    const quote = this.state.quotes[instrumentID(request.instrument)];
    let price = 0;
    let modelled = false;
    if (quote && quote.last > 0) {
      const market = PaperBroker.executionPrice(request.side, quote, request.instrument, this.state.paperConfig);
      price = market.price;
      modelled = market.modelled;
    }
    if (request.type === "limit" || request.type === "stopLimit") {
      if (request.limitPrice !== undefined && request.limitPrice > 0) price = request.limitPrice;
    } else if (request.type === "stop") {
      if (request.stopPrice !== undefined && request.stopPrice > 0) price = request.side === "buy" ? Math.max(price, request.stopPrice) : request.stopPrice;
    }
    let quantity = request.quantity ?? 0;
    if (request.quantity === undefined && request.notional !== undefined && price > 0) {
      quantity = Rounding.floor(request.notional / price, rules.quantityIncrement);
    }
    const fee = PaperBroker.fee(request.instrument, request.side, Rounding.money(quantity * price), true, this.state.paperConfig);
    return { quantity, price, fee, modelledSpread: modelled };
  }

  private agentView(agent: TradingAgent | undefined): AgentRiskView | undefined {
    if (!agent) return undefined;
    const spec = agentSpec(agent);
    return {
      id: agent.id, name: agent.name, mode: agent.mode, status: agent.status,
      universe: spec.universe.map(instrumentID), followsLedgerPositions: spec.followsLedgerPositions,
    };
  }

  private riskContext(ledger: Ledger, source: OrderSource, instrument: Instrument, now: number): RiskContext {
    const id = instrumentID(instrument);
    const state = this.state;
    const peers = state.ledgers.filter((l) => l.mode === ledger.mode && l.currency === ledger.currency);
    let exposure = 0, accountEquity = 0, notionalToday = 0;
    const today = ledgerDayKey(now, ledger.currency);
    for (const peer of peers) {
      const held = ledgerPosition(peer, id);
      exposure += held ? marketValue(held) : 0;
    }
    for (const peer of peers) accountEquity += ledgerEquity(peer);
    for (const peer of peers) notionalToday += peer.dayKey === today ? peer.notionalToday : 0;
    const context: RiskContext = {
      now,
      policy: this.policyFor(source, ledger),
      accountPolicy: state.accountPolicy,
      ledger: rolledCopy(ledger, now),
      openOrders: state.orders.filter((o) => o.ledgerID === ledger.id && isOpenStatus(o.status)),
      otherOpenOrders: state.orders.filter((o) => o.ledgerID !== ledger.id && isOpenStatus(o.status) && instrumentID(o.instrument) === id && o.mode === ledger.mode),
      knownClientOrderIDs: state.knownClientOrderIDs,
      accountExposure: exposure,
      accountEquity,
      accountNotionalToday: notionalToday,
      rules: PaperBroker.rules(instrument),
      capabilities: PaperBroker.capabilities,
      grantedPermissions: ["read", "trade"],
      marketOpen: Calendar.isOpen(instrument.venue, now),
    };
    const view = this.agentView(this.agent(source.agentID));
    if (view) context.agent = view;
    const quote = state.quotes[id];
    if (quote) context.quote = quote;
    const stats = state.stats[id];
    if (stats) context.stats = stats;
    return context;
  }

  private intent(request: OrderRequest, sized: Sized): OrderIntent {
    const intent: OrderIntent = {
      clientOrderID: request.clientOrderID, instrument: request.instrument, side: request.side, type: request.type,
      timeInForce: request.timeInForce, quantity: sized.quantity, price: sized.price, estimatedFee: sized.fee,
      source: request.source, mode: request.mode,
    };
    if (request.limitPrice !== undefined) intent.limitPrice = request.limitPrice;
    if (request.stopPrice !== undefined) intent.stopPrice = request.stopPrice;
    return intent;
  }

  /** The report a live request gets: refused, with the reasons, without touching a ledger. */
  private liveRefusal(request: OrderRequest, now: number): RiskReport {
    const reasons = this.liveBlockers(this.agent(request.source.agentID)?.mode);
    const detail = (reasons.length === 0 ? ["Live trading isn't available in this version."] : reasons).join(" ");
    return { checks: [{ id: "authorization", status: "failed", detail }], evaluatedAt: now };
  }

  private judge(request: OrderRequest, sized: Sized, ledger: Ledger, now: number): RiskReport {
    return request.mode === "live"
      ? this.liveRefusal(request, now)
      : evaluateRisk(this.intent(request, sized), this.riskContext(ledger, request.source, request.instrument, now));
  }

  /** What would happen if this order were placed now. Changes nothing. */
  preview(request: OrderRequest, now: number): OrderPreview | undefined {
    const ledger = this.ledger(request.ledgerID);
    if (!ledger) return undefined;
    const sized = this.size(request);
    const risk = this.judge(request, sized, ledger, now);
    const value = Rounding.money(sized.quantity * sized.price);
    const quote = this.state.quotes[instrumentID(request.instrument)];
    const open = Calendar.isOpen(request.instrument.venue, now);
    const cashAfter = request.side === "buy" ? ledger.cash - value - sized.fee : ledger.cash + value - sized.fee;
    const preview: OrderPreview = {
      instrument: request.instrument, side: request.side, type: request.type, timeInForce: request.timeInForce,
      quantity: sized.quantity, estimatedPrice: sized.price, estimatedValue: value, estimatedFee: sized.fee,
      cashAfter: Rounding.money(cashAfter), currency: ledger.currency, ledgerName: ledger.name, mode: request.mode,
      usesModelledSpread: sized.modelledSpread, willQueueUntilOpen: !open, risk, canSubmit: isApproved(risk),
    };
    if (quote) {
      preview.quote = quote;
      const spread = quoteSpreadBps(quote);
      if (spread !== undefined) preview.spreadBps = spread;
    }
    if (!open) {
      const next = Calendar.nextOpen(request.instrument.venue, now);
      if (next !== undefined) preview.nextOpen = next;
    }
    return preview;
  }

  /**
   * Checks and places an order. A refused order is recorded as rejected — never dropped
   * silently and never reported as placed.
   */
  submit(request: OrderRequest, now: number): OrderResult {
    const ledger = this.ledger(request.ledgerID);
    if (!ledger) {
      return { accepted: false, risk: { checks: [{ id: "authorization", status: "failed", detail: "That portfolio no longer exists." }], evaluatedAt: now } };
    }
    const sized = this.size(request);
    const actor: AuditActor = request.source.kind === "agent" ? "agent" : "user";
    const symbol = request.instrument.symbol;
    const id = instrumentID(request.instrument);

    const makeOrder = (status: OrderStatus, note: string | undefined): Order => {
      const order: Order = {
        id: this.newID(), clientOrderID: request.clientOrderID, ledgerID: ledger.id, instrument: request.instrument,
        side: request.side, type: request.type, quantity: sized.quantity, timeInForce: request.timeInForce,
        source: { ...request.source }, mode: request.mode, status, filledQuantity: 0, averageFillPrice: 0, fees: 0,
        referencePrice: sized.price, createdAt: now, updatedAt: now,
      };
      if (request.limitPrice !== undefined) order.limitPrice = request.limitPrice;
      if (request.stopPrice !== undefined) order.stopPrice = request.stopPrice;
      const expiresAt = PaperBroker.expiry(request.timeInForce, request.instrument.venue, now);
      if (expiresAt !== undefined) order.expiresAt = expiresAt;
      if (note !== undefined) order.statusNote = note;
      if (request.signalBarTime !== undefined) order.signalBarTime = request.signalBarTime;
      return order;
    };
    const event = (fields: Pick<AuditInput, "kind" | "summary" | "details"> & { orderID: string }): AuditInput => {
      const input: AuditInput = { time: now, actor, mode: request.mode, ledgerID: ledger.id, instrumentID: id, ...fields };
      if (request.source.agentID !== undefined) input.agentID = request.source.agentID;
      if (request.source.proposalID !== undefined) input.proposalID = request.source.proposalID;
      return input;
    };

    const risk = this.judge(request, sized, ledger, now);

    if (!isApproved(risk)) {
      // A repeat of an order we already hold is refused without a second record.
      if (this.state.knownClientOrderIDs.has(request.clientOrderID)) return { accepted: false, risk };
      const summary = reportSummary(risk);
      const order = makeOrder("rejected", summary);
      // A key is used once, whatever happened to it: a retry must come with a new one.
      this.state.knownClientOrderIDs.add(request.clientOrderID);
      this.state.orders.push(order);
      this.audit(event({
        kind: "orderRejected", summary: `${capitalized(request.side)} ${symbol} rejected: ${summary}`, orderID: order.id,
        details: {
          failedChecks: reportFailures(risk).map((check) => check.id).join(","),
          quantity: swiftDouble(sized.quantity), price: swiftDouble(sized.price),
        },
      }));
      this.notify({
        kind: "orderRejected", title: `${symbol} order rejected`, body: summary, mode: request.mode,
        agentID: request.source.agentID, orderID: order.id, instrumentID: id,
      });
      return { accepted: false, order, risk };
    }

    const order = makeOrder("accepted", undefined);
    if (!Calendar.isOpen(request.instrument.venue, now)) order.statusNote = "Waiting for the market to open.";
    this.state.knownClientOrderIDs.add(request.clientOrderID);
    this.state.orders.push(order);
    this.audit(event({
      kind: "orderSubmitted",
      summary: `Paper ${orderTypeDisplayName(request.type).toLowerCase()} order: ${request.side} ${quantityText(sized.quantity, PaperBroker.rules(request.instrument))} ${symbol}.`,
      orderID: order.id,
      details: {
        type: request.type, timeInForce: request.timeInForce, quantity: swiftDouble(sized.quantity),
        referencePrice: swiftDouble(sized.price), clientOrderID: request.clientOrderID,
      },
    }));
    const fills = this.matchOrder(order.id, now);
    return { accepted: true, order, fills, risk };
  }

  /** Cancels an open order. Returns false when it had already finished. */
  cancelOrder(id: string, now: number, actor: AuditActor = "user", note = "Cancelled by you."): boolean {
    const order = this.state.orders.find((o) => o.id === id);
    if (!order) return false;
    if (!transition(order, "canceled", now, note)) return false;
    const input: AuditInput = {
      time: now, actor, kind: "orderCanceled",
      summary: `${capitalized(order.side)} ${order.instrument.symbol} order cancelled. ${note}`,
      mode: order.mode, ledgerID: order.ledgerID, orderID: order.id, instrumentID: instrumentID(order.instrument),
      details: { filledQuantity: swiftDouble(order.filledQuantity) },
    };
    if (order.source.agentID !== undefined) input.agentID = order.source.agentID;
    this.audit(input);
    return true;
  }

  /** Tries to trade one open order against the latest quote. Returns the fills it made. */
  private matchOrder(id: string, now: number): Fill[] {
    const state = this.state;
    const order = state.orders.find((o) => o.id === id);
    if (!order || !isOpenStatus(order.status) || order.mode !== "paper") return [];
    const ledger = state.ledgers.find((l) => l.id === order.ledgerID);
    const instrument = order.instrument;
    const instrumentKey = instrumentID(instrument);
    const quote = state.quotes[instrumentKey];
    if (!ledger || !quote) return [];
    const open = Calendar.isOpen(instrument.venue, now);
    const match = PaperBroker.match(order, quote, open, now, state.paperConfig);
    if (!match) return [];
    if (match.stopTriggered) order.stopTriggeredAt = now;

    // A market order that waited (overnight, or for a fresh quote) is not filled at a
    // price far from the one it was checked against.
    if (match.fillQuantity > 0 && order.type === "market" && order.referencePrice > 0) {
      const gapLimit = this.policyFor(order.source, ledger).maxPriceGapPct;
      const gap = Math.abs(match.fillPrice / order.referencePrice - 1) * 100;
      if (gap > gapLimit) {
        this.cancelOrder(id, now, "system", `The price moved ${cFixed(gap, 1)}% from where the order was checked (limit ${cFixed(gapLimit, 1)}%).`);
        this.notify({
          kind: "orderCanceled", title: `${instrument.symbol} order cancelled`, body: `The price moved ${cFixed(gap, 1)}% before it could trade.`,
          mode: order.mode, agentID: order.source.agentID, orderID: id, instrumentID: instrumentKey,
        });
        return [];
      }
    }

    // The ledger can never go negative or short, whatever happened since the order was checked.
    const rules = PaperBroker.rules(instrument);
    if (match.fillQuantity > 0) {
      if (order.side === "buy") {
        const cost = Rounding.money(match.fillQuantity * match.fillPrice) + match.fee;
        if (cost > ledger.cash + 0.005) {
          this.cancelOrder(id, now, "system", "Not enough cash when the order came to trade.");
          return [];
        }
      } else {
        const held = ledgerPosition(ledger, instrumentKey)?.quantity ?? 0;
        if (match.fillQuantity > held + rules.quantityIncrement * 1e-3) {
          if (held <= 0) {
            this.cancelOrder(id, now, "system", "Nothing left to sell when the order came to trade.");
            return [];
          }
          match.fillQuantity = held;
          match.newStatus = "filled";
        }
      }
    }

    if (!(match.fillQuantity > 0)) {
      if (match.newStatus === "canceled") {
        this.cancelOrder(id, now, "system", match.note ?? "Cancelled.");
      } else if (match.note !== undefined) {
        order.statusNote = match.note;
        order.updatedAt = now;
      }
      return [];
    }

    const draft: Fill = {
      id: this.newID(), orderID: order.id, ledgerID: order.ledgerID, instrument, side: order.side,
      quantity: match.fillQuantity, price: match.fillPrice, fee: match.fee, time: now, source: { ...order.source }, mode: order.mode,
    };
    if (order.signalBarTime !== undefined) draft.signalBarTime = order.signalBarTime;
    const fill = applyFill(ledger, draft);
    state.fills.push(fill);

    const previous = order.filledQuantity;
    const total = previous + fill.quantity;
    order.averageFillPrice = total > 0 ? (order.averageFillPrice * previous + fill.price * fill.quantity) / total : 0;
    order.filledQuantity = Rounding.round(total, 9);
    order.fees = Rounding.money(order.fees + fill.fee);
    transition(order, match.newStatus, now, match.note);
    if (match.newStatus === "filled") {
      if (match.note === undefined) delete order.statusNote;
      else order.statusNote = match.note;
    }

    const complete = match.newStatus === "filled";
    const text = `${order.side === "buy" ? "Bought" : "Sold"} ${quantityText(fill.quantity, rules)} ${instrument.symbol} at ${NumberText.money(fill.price, ledger.currency)}`;
    const details: Record<string, string> = {
      quantity: swiftDouble(fill.quantity), price: swiftDouble(fill.price), fee: swiftDouble(fill.fee),
      orderStatus: match.newStatus, quoteSource: quote.provenance.source,
    };
    if (fill.realizedPnL !== undefined) details.realizedPnL = swiftDouble(fill.realizedPnL);
    const base: AuditInput = {
      time: now, actor: "system", kind: complete ? "orderFilled" : "orderPartiallyFilled", summary: `Paper fill: ${text}.`,
      mode: order.mode, ledgerID: order.ledgerID, orderID: order.id, instrumentID: instrumentKey, details,
    };
    if (order.source.agentID !== undefined) base.agentID = order.source.agentID;
    if (order.source.proposalID !== undefined) base.proposalID = order.source.proposalID;
    this.audit(base);
    this.notify({
      kind: complete ? "orderFilled" : "orderPartiallyFilled", title: complete ? "Paper order filled" : "Paper order partly filled",
      body: `${text}.`, mode: order.mode, agentID: order.source.agentID, orderID: order.id, instrumentID: instrumentKey,
    });
    if (match.newStatus === "canceled") {
      // An immediate-or-cancel order that filled in part: the rest is gone.
      const rest: AuditInput = {
        time: now, actor: "system", kind: "orderCanceled", summary: `The unfilled part of the ${instrument.symbol} order was cancelled.`,
        mode: order.mode, ledgerID: order.ledgerID, orderID: order.id, instrumentID: instrumentKey,
      };
      if (order.source.agentID !== undefined) rest.agentID = order.source.agentID;
      this.audit(rest);
    }
    return [fill];
  }

  // MARK: - Market updates

  private isUsable(provenance: DataProvenance): boolean {
    return isRealMarketData(provenance) || (provenance.kind === "fixture" && this.state.accountPolicy.allowFixtureData);
  }

  /**
   * Takes in fresh quotes and stats, lets waiting orders trade, expires what has run out
   * of time and reprices every portfolio. Call this whenever prices refresh.
   */
  ingest(quotes: Quote[], stats: Record<string, InstrumentStats>, now: number): void {
    const state = this.state;
    for (const quote of quotes) {
      if (!(quote.last > 0)) continue;
      if (!this.isUsable(quote.provenance)) continue;
      // Never replace a quote with an older one.
      const existing = state.quotes[quote.instrumentID];
      if (existing && existing.time > quote.time) continue;
      state.quotes[quote.instrumentID] = quote;
    }
    for (const [id, value] of Object.entries(stats)) state.stats[id] = value;

    for (const order of state.orders.slice()) {
      if (!isOpenStatus(order.status) || order.mode !== "paper") continue;
      if (order.expiresAt !== undefined && now >= order.expiresAt) {
        if (transition(order, "expired", now, "The order ran out of time.")) {
          const input: AuditInput = {
            time: now, actor: "system", kind: "orderExpired", summary: `${capitalized(order.side)} ${order.instrument.symbol} order expired.`,
            mode: order.mode, ledgerID: order.ledgerID, orderID: order.id, instrumentID: instrumentID(order.instrument),
          };
          if (order.source.agentID !== undefined) input.agentID = order.source.agentID;
          this.audit(input);
        }
        continue;
      }
      this.matchOrder(order.id, now);
    }

    this.expireStaleProposals(now);
    for (const ledger of state.ledgers) markLedger(ledger, state.quotes, now);
    this.applyCircuitBreakers(now);
    this.trim();
  }

  /**
   * Pauses an agent whose portfolio has hit its drawdown limit, and says so once when a
   * daily loss limit is reached (the risk engine is already refusing its buys).
   */
  private applyCircuitBreakers(now: number): void {
    const state = this.state;
    for (const agent of state.agents.filter((a) => a.status === "active" && a.mode === "paper")) {
      const ledger = this.ledger(agent.ledgerID);
      if (!ledger || ledger.kind !== "agentPaper") continue;
      if (drawdownPct(ledger) >= agent.riskPolicy.maxDrawdownPct) {
        this.pauseAgent(agent.id, now, "drawdownLimit");
        continue;
      }
      const lossPct = ledger.dayStartEquity > 0 ? Rounding.swiftMax(0, -ledger.realizedToday) / ledger.dayStartEquity * 100 : 0;
      const key = uuidString(agent.id);
      if (lossPct >= agent.riskPolicy.maxDailyLossPct && state.dailyLossNotified[key] !== ledger.dayKey) {
        state.dailyLossNotified[key] = ledger.dayKey;
        this.notify({
          kind: "dailyLossReached", title: `${agent.name}: daily loss limit reached`,
          body: `Today's realised loss is ${cFixed(lossPct, 1)}%. No new buys until tomorrow; exits still run.`, agentID: agent.id,
        });
      }
    }
  }

  /** Keeps in-memory history bounded. Orders, fills and the audit trail are kept far longer than runs. */
  private trim(): void {
    const state = this.state;
    if (state.signals.length > 600) state.signals.splice(0, state.signals.length - 500);
    if (state.runs.length > 1_200) state.runs.splice(0, state.runs.length - 1_000);
    if (state.proposals.length > 1_200) {
      const drop = new Set(state.proposals.filter((p) => p.status !== "pending").slice(0, state.proposals.length - 1_000).map((p) => p.id));
      state.proposals = state.proposals.filter((p) => !drop.has(p.id));
    }
    if (state.orders.length > 6_000) {
      const drop = new Set(state.orders.filter((o) => isTerminalStatus(o.status)).slice(0, state.orders.length - 5_000).map((o) => o.id));
      state.orders = state.orders.filter((o) => !drop.has(o.id));
    }
    if (state.fills.length > 12_000) state.fills.splice(0, state.fills.length - 10_000);
    archiveAudit(state.audit, 8_000);
  }

  // MARK: - The agent pipeline

  private step(kind: StepKind, outcome: StepOutcome, title: string, fields: { instrumentID?: string; detail?: string; evidence?: Evidence[] } = {}): RunStep {
    const step: RunStep = { id: this.newID(), kind, outcome, title, detail: fields.detail ?? "", evidence: fields.evidence ?? [] };
    if (fields.instrumentID !== undefined) step.instrumentID = fields.instrumentID;
    return step;
  }

  /**
   * Runs one agent once against a market snapshot the caller has already gathered.
   * Returns the trace of what it saw and did, or undefined if the agent doesn't exist.
   */
  runAgent(id: string, snapshot: MarketSnapshot, trigger: RunTrigger, now: number): AgentRun | undefined {
    const state = this.state;
    const agentIndex = state.agents.findIndex((a) => a.id === id);
    if (agentIndex < 0) return undefined;
    const agent = state.agents[agentIndex];
    const run = makeRun(this.newID(), id, strategyVersion(agent), trigger, now);

    const skipped = (reason: string): AgentRun => {
      run.status = "skipped";
      run.summary = reason;
      run.steps.push(this.step("note", "info", reason));
      return run;
    };

    if (state.accountPolicy.killSwitchEngaged) {
      state.runs.push(skipped("The kill switch is on, so nothing ran."));
      return run;
    }
    if (agent.status !== "active") {
      state.runs.push(skipped(`${agent.name} is ${agent.status}.`));
      return run;
    }
    if (modeIsLive(agent.mode)) {
      state.runs.push(skipped("Live trading isn't available, so nothing ran."));
      return run;
    }

    // Take in what the snapshot learned about prices before deciding anything.
    const usable: MarketSnapshot = { ...snapshot, series: {} };
    for (const [instrumentKey, series] of Object.entries(snapshot.series)) {
      if (this.isUsable(series.provenance)) usable.series[instrumentKey] = series;
    }
    // An instrument whose liquidity can't be measured this time loses its old figure too.
    // (Only daily bars measure liquidity, so an hourly series leaves the last daily figure alone.)
    for (const [instrumentKey, series] of Object.entries(usable.series)) {
      if (series.timeframe === "day") delete state.stats[instrumentKey];
    }
    this.ingest(Object.values(snapshot.quotes), Calendar.snapshotStats(usable, now), now);

    const spec = agentSpec(agent);
    const mode = agent.mode;
    let instruments = spec.universe;
    const book = this.ledger(agent.ledgerID);
    if (spec.followsLedgerPositions && book) instruments = book.positions.map((p) => p.instrument);
    if (instruments.length === 0) {
      skipped(spec.followsLedgerPositions ? "The portfolio has no positions to manage." : "There are no assets to watch.");
      this.finish(run, id, 0, 0, now, true);
      return run;
    }

    let dataFailures = 0;
    const prepared: { instrument: Instrument; bars: Bar[]; provenance: DataProvenance }[] = [];
    for (const instrument of instruments) {
      const usable = this.usableBars(instrument, spec, snapshot, now);
      if ("problem" in usable) {
        dataFailures += 1;
        run.steps.push(this.step("data", "failed", `${instrument.symbol}: no usable price data`, { instrumentID: instrumentID(instrument), detail: usable.problem }));
      } else {
        prepared.push({ instrument, bars: usable.bars, provenance: usable.provenance });
      }
    }

    const facts = (instrument: Instrument, bars: Bar[]) =>
      this.step("research", "ok", `${instrument.symbol}: market facts`, {
        instrumentID: instrumentID(instrument), detail: `From ${bars.length} completed ${barName(spec.timeframe)} bars.`,
        evidence: researchFacts(bars, spec.timeframe),
      });

    switch (spec.kind) {
      case "research":
        for (const { instrument, bars } of prepared) run.steps.push(facts(instrument, bars));
        break;
      case "rules":
        for (const { instrument, bars, provenance } of prepared) {
          if (mode === "researchOnly") {
            run.steps.push(facts(instrument, bars));
            continue;
          }
          const ledger = this.ledger(agent.ledgerID);
          const key = instrumentID(instrument);
          const held = ledger ? ledgerPosition(ledger, key) : undefined;
          const position = held ? { quantity: held.quantity, averageCost: averageCost(held), openedAt: held.openedAt } : undefined;
          const decision = decide(spec, bars, position, ledger?.lastExitAt[key]);
          if (!decision) continue;
          this.handle(decision, instrument, provenance, undefined, id, run, now);
        }
        break;
      case "dca":
        for (const { instrument, bars, provenance } of prepared) {
          if (mode === "researchOnly") continue;
          const lastBuy = this.ledger(agent.ledgerID)?.lastBuyAt[instrumentID(instrument)];
          const decision = decideDCA(spec, bars, lastBuy);
          if (!decision) continue;
          this.handle(decision, instrument, provenance, spec.dca?.amountPerBuy, id, run, now);
        }
        break;
      case "rebalance":
        if (mode !== "researchOnly") this.rebalance(prepared, id, run, now);
        break;
    }

    this.finish(run, id, dataFailures, instruments.length, now, false);
    return run;
  }

  /** Completed, real, recent bars for an instrument — or the reason there aren't any. */
  private usableBars(instrument: Instrument, spec: StrategySpec, snapshot: MarketSnapshot, now: number):
    { bars: Bar[]; provenance: DataProvenance } | { problem: string } {
    const key = instrumentID(instrument);
    const series = snapshot.series[key];
    if (!series) return { problem: snapshot.failures[key] ?? "No price history was returned." };
    if (!this.isUsable(series.provenance)) return { problem: "The price history isn't real market data, so it can't be traded on." };
    if (series.timeframe !== spec.timeframe) {
      return { problem: `Expected ${barName(spec.timeframe)} bars but got ${barName(series.timeframe)} ones.` };
    }
    const bars = Calendar.completedBars(series, now);
    const last = bars[bars.length - 1];
    if (!last) return { problem: "There are no completed bars yet." };
    let stale: boolean;
    if (spec.timeframe === "day") {
      stale = Calendar.tradingDays(instrument.venue, last.time, now) > 4;
    } else {
      stale = instrument.venue === "crypto" ? (now - last.time) / 1_000 > 6 * 3_600 : Calendar.tradingDays(instrument.venue, last.time, now) > 2;
    }
    if (stale) {
      return { problem: `The price history is out of date: the last completed bar is from ${Calendar.dayKey(instrument.venue, last.time)}.` };
    }
    return { bars, provenance: series.provenance };
  }

  /**
   * Records a decision and, where the agent's mode allows, takes it through sizing, risk
   * and execution.
   */
  private handle(decision: SignalDecision, instrument: Instrument, provenance: DataProvenance, targetNotional: number | undefined,
    agentID: string, run: AgentRun, now: number): void {
    const state = this.state;
    const agent = this.agent(agentID);
    if (!agent) return;
    const key = instrumentID(instrument);
    const symbol = instrument.symbol;
    const version = strategyVersion(agent);
    run.steps.push(this.step("signal", decision.action === "hold" ? "info" : "ok", `${symbol}: ${capitalized(decision.action)}`,
      { instrumentID: key, detail: decision.headline, evidence: decision.evidence }));
    if (decision.action === "hold") return;

    // One signal per bar per direction: re-running on the same bar doesn't repeat it.
    let signal: TradingSignal | undefined;
    for (let i = state.signals.length - 1; i >= 0; i--) {
      const s = state.signals[i];
      if (s.agentID === agent.id && instrumentID(s.instrument) === key && s.barTime === decision.barTime &&
        s.action === decision.action && s.strategyVersion === version) {
        signal = s;
        break;
      }
    }
    if (!signal) {
      signal = makeSignal(this.newID(), agent.id, version, instrument, decision, now, provenance);
      state.signals.push(signal);
      this.audit({
        time: now, actor: "agent", kind: "signalGenerated",
        summary: `${agent.name}: ${decision.action} signal for ${symbol}. ${decision.headline}`, agentID: agent.id, instrumentID: key,
        details: {
          strategyVersion: String(version), barTime: String(Math.trunc(decision.barTime / 1_000)),
          close: swiftDouble(decision.close), dataSource: provenance.source,
        },
      });
    }
    run.signalIDs.push(signal.id);

    if (agent.mode !== "paper") return;
    const ledger = this.ledger(agent.ledgerID);
    if (!ledger) {
      run.steps.push(this.step("sizing", "failed", `${symbol}: no portfolio`, { instrumentID: key, detail: "This agent has no paper portfolio to trade." }));
      return;
    }
    const side: OrderSide = decision.action === "buy" ? "buy" : "sell";

    // Don't act twice on one bar, and don't stack proposals or orders.
    if (state.fills.some((f) => f.source.agentID === agent.id && instrumentID(f.instrument) === key && f.side === side && f.signalBarTime === decision.barTime)) {
      run.steps.push(this.step("note", "info", `${symbol}: already traded this signal`, { instrumentID: key, detail: `This bar's ${side} signal has already been acted on.` }));
      return;
    }
    if (state.proposals.some((p) => p.agentID === agent.id && instrumentID(p.instrument) === key && p.side === side && p.status === "pending")) {
      run.steps.push(this.step("note", "info", `${symbol}: waiting for your approval`, { instrumentID: key, detail: `A ${side} proposal for ${symbol} is already waiting.` }));
      return;
    }
    if (state.orders.some((o) => o.source.agentID === agent.id && instrumentID(o.instrument) === key && o.side === side && isOpenStatus(o.status))) {
      run.steps.push(this.step("note", "info", `${symbol}: order already working`, { instrumentID: key, detail: `A ${side} order for ${symbol} is already open.` }));
      return;
    }

    const quote = state.quotes[key];
    if (!quote || !(quote.last > 0)) {
      run.steps.push(this.step("sizing", "failed", `${symbol}: no live quote`,
        { instrumentID: key, detail: "Without a live quote the order can't be sized, so nothing was proposed." }));
      return;
    }

    // Size the order inside the agent's limits.
    const rules = PaperBroker.rules(instrument);
    const currency = ledger.currency;
    const price = PaperBroker.executionPrice(side, quote, instrument, state.paperConfig).price;
    const spec = agentSpec(agent);
    let quantity = 0;
    const notes: string[] = [];
    if (side === "buy") {
      const equity = ledgerEquity(ledger);
      let notional = targetNotional ?? (spec.sizing.mode === "fixedNotional" ? spec.sizing.value : equity * spec.sizing.value / 100);
      const wanted = notional;
      if (notional > agent.riskPolicy.maxOrderNotional) {
        notional = agent.riskPolicy.maxOrderNotional;
        notes.push(`cut to the ${NumberText.money(notional, currency)} order limit`);
      }
      const heldNow = ledgerPosition(ledger, key);
      const room = equity * agent.riskPolicy.maxPositionPct / 100 - (heldNow ? marketValue(heldNow) : 0);
      if (notional > room) {
        notional = Math.max(room, 0);
        notes.push(`cut to stay inside the ${trimNumber(agent.riskPolicy.maxPositionPct)}% position limit`);
      }
      let reserved = 0;
      for (const o of state.orders) {
        if (o.ledgerID === ledger.id && isOpenStatus(o.status) && o.side === "buy") reserved += remainingQuantity(o) * (o.limitPrice ?? o.referencePrice);
      }
      const isCrypto = instrument.assetClass === "crypto";
      // The buy-side transaction tax counts too, so a taxed buy never overspends the cash.
      const feeRate = (isCrypto ? state.paperConfig.cryptoFeeBps : state.paperConfig.equityFeeBps) / 10_000
        + PaperBroker.taxBps(instrument, "buy") / 10_000;
      const flatFee = isCrypto ? 0 : state.paperConfig.equityFeePerOrder;
      const spendable = Math.max((ledger.cash - reserved - flatFee) / (1 + feeRate), 0);
      if (notional > spendable) {
        notional = spendable;
        notes.push("cut to the cash available");
      }
      quantity = price > 0 ? Rounding.floor(notional / price, rules.quantityIncrement) : 0;
      if (notes.length > 0) notes.unshift(`Wanted ${NumberText.money(wanted, currency)}`);
    } else {
      let reserved = 0;
      for (const o of state.orders) {
        if (o.ledgerID === ledger.id && isOpenStatus(o.status) && o.side === "sell" && instrumentID(o.instrument) === key) reserved += remainingQuantity(o);
      }
      const held = Math.max((ledgerPosition(ledger, key)?.quantity ?? 0) - reserved, 0);
      quantity = targetNotional !== undefined && price > 0
        ? Math.min(held, Rounding.floor(targetNotional / price, rules.quantityIncrement))
        : held;
    }
    const sizingNote = notes.length === 0 ? undefined : `${notes.join("; ")}.`;

    if (!(quantity >= rules.minQuantity && quantity * price >= rules.minNotional)) {
      const reason = side === "sell"
        ? "There is nothing available to sell."
        : `After the agent's limits and available cash, the order would be below the ${NumberText.money(rules.minNotional, currency)} minimum.`;
      run.steps.push(this.step("sizing", "warning", `${symbol}: order too small`,
        { instrumentID: key, detail: [reason, sizingNote].filter((part): part is string => part !== undefined).join(" ") }));
      return;
    }
    run.steps.push(this.step("sizing", "ok", `${symbol}: sized ${side} of ${quantityText(quantity, rules)}`, {
      instrumentID: key,
      detail: `About ${NumberText.money(quantity * price, currency)} at ${NumberText.money(price, currency)}. ${sizingNote ?? ""}`,
    }));

    // Risk engine: the same gate a manual order passes.
    const proposal = makeProposal({
      id: this.newID(), agentID: agent.id, signalID: signal.id, strategyVersion: version, ledgerID: ledger.id, instrument, side,
      quantity, referencePrice: price, estimatedFee: 0, mode: "paper", status: "pending", risk: { checks: [], evaluatedAt: now },
      headline: decision.headline, sizingNote, signalBarTime: decision.barTime, createdAt: now,
      expiresAt: now + (spec.timeframe === "day" ? 86_400 : 2 * 3_600) * 1_000,
    });
    const request = this.orderRequest(proposal);
    const sized = this.size(request);
    proposal.estimatedFee = sized.fee;
    const report = evaluateRisk(this.intent(request, sized), this.riskContext(ledger, request.source, instrument, now));
    proposal.risk = report;
    const passed = report.checks.filter((check) => check.status === "passed").length;
    const summary = reportSummary(report);

    if (!isApproved(report)) {
      proposal.status = "blocked";
      proposal.resolvedAt = now;
      proposal.resolutionNote = summary;
      state.proposals.push(proposal);
      run.proposalIDs.push(proposal.id);
      const failures = reportFailures(report);
      run.steps.push(this.step("risk", "blocked", `${symbol}: blocked by risk rules`, {
        instrumentID: key, detail: summary,
        evidence: failures.map((check) => ({ label: riskCheckTitle(check.id), value: check.detail, passed: false })),
      }));
      this.audit({
        time: now, actor: "system", kind: "proposalBlocked", summary: `${agent.name}: ${side} ${symbol} blocked. ${summary}`,
        mode: "paper", agentID: agent.id, ledgerID: ledger.id, proposalID: proposal.id, instrumentID: key,
        details: { failedChecks: failures.map((check) => check.id).join(","), quantity: swiftDouble(quantity), price: swiftDouble(price) },
      });
      this.notify({
        kind: "proposalBlocked", title: `${agent.name}: trade blocked`, body: `${capitalized(side)} ${symbol}: ${summary}`,
        agentID: agent.id, proposalID: proposal.id, instrumentID: key,
      });
      return;
    }
    const warnings = reportWarnings(report);
    run.steps.push(this.step("risk", warnings.length === 0 ? "ok" : "warning", `${symbol}: passed ${passed} risk checks`, {
      instrumentID: key, detail: summary, evidence: warnings.map((check) => ({ label: riskCheckTitle(check.id), value: check.detail })),
    }));

    state.proposals.push(proposal);
    run.proposalIDs.push(proposal.id);
    const text = `${capitalized(side)} ${quantityText(quantity, rules)} ${symbol} (about ${NumberText.money(proposal.notional, currency)})`;
    this.audit({
      time: now, actor: "agent", kind: "proposalCreated", summary: `${agent.name} proposed: ${text}.`, mode: "paper",
      agentID: agent.id, ledgerID: ledger.id, proposalID: proposal.id, instrumentID: key,
      details: {
        quantity: swiftDouble(quantity), referencePrice: swiftDouble(price), strategyVersion: String(version),
        signalID: uuidString(signal.id),
      },
    });

    if (agent.reviewEachPaperTrade) {
      run.steps.push(this.step("proposal", "info", `${symbol}: waiting for your approval`, { instrumentID: key, detail: `${text}.` }));
      this.notify({
        kind: "approvalNeeded", title: `${agent.name} wants to trade`, body: `Paper: ${text}. Review it to approve or reject.`,
        agentID: agent.id, proposalID: proposal.id, instrumentID: key,
      });
      return;
    }
    this.execute(proposal.id, run, now);
  }

  private orderRequest(proposal: TradeProposal): OrderRequest {
    return {
      clientOrderID: proposal.clientOrderID, ledgerID: proposal.ledgerID, instrument: proposal.instrument, side: proposal.side,
      type: "market", quantity: proposal.quantity, timeInForce: "day", source: agentSource(proposal.agentID, proposal.id),
      mode: proposal.mode, signalBarTime: proposal.signalBarTime,
    };
  }

  /**
   * Submits the order for a proposal. The order goes through `submit`, so the risk engine
   * judges it again against the prices of this moment.
   */
  private execute(proposalID: string, run: AgentRun, now: number): OrderResult | undefined {
    const proposal = this.state.proposals.find((p) => p.id === proposalID);
    if (!proposal) return undefined;
    const key = instrumentID(proposal.instrument);
    const symbol = proposal.instrument.symbol;
    const result = this.submit(this.orderRequest(proposal), now);
    proposal.resolvedAt = now;
    proposal.risk = result.risk;
    if (result.order) {
      proposal.orderID = result.order.id;
      run.orderIDs.push(result.order.id);
    } else {
      delete proposal.orderID;
    }
    if (result.accepted) {
      proposal.status = "submitted";
      const order = result.order;
      const lastFill = result.fills[result.fills.length - 1];
      let detail: string;
      if (order.status === "filled" && lastFill) detail = `Filled at ${NumberText.money(lastFill.price, proposal.instrument.currency)}.`;
      else if (order.status === "partiallyFilled") detail = "Partly filled; the rest is still working.";
      else detail = order.statusNote ?? "The order is working.";
      proposal.resolutionNote = detail;
      run.steps.push(this.step("execution", "ok", `${symbol}: paper order ${orderStatusDisplayName(order.status).toLowerCase()}`, { instrumentID: key, detail }));
    } else {
      const summary = reportSummary(result.risk);
      proposal.status = "failed";
      proposal.resolutionNote = summary;
      run.steps.push(this.step("execution", "failed", `${symbol}: order refused`, { instrumentID: key, detail: summary }));
      this.audit({
        time: now, actor: "system", kind: "proposalFailed", summary: `${capitalized(proposal.side)} ${symbol} could not be placed: ${summary}`,
        mode: proposal.mode, agentID: proposal.agentID, ledgerID: proposal.ledgerID, proposalID: proposal.id, instrumentID: key,
      });
    }
    return result;
  }

  // MARK: Rebalancing

  private rebalance(prepared: { instrument: Instrument; bars: Bar[]; provenance: DataProvenance }[], agentID: string, run: AgentRun, now: number): void {
    const agent = this.agent(agentID);
    if (!agent) return;
    const spec = agentSpec(agent);
    const config = spec.monthlyInvestment?.allocation ?? spec.rebalance;
    if (!config) return;
    const ledger = this.ledger(agent.ledgerID);
    if (agent.mode !== "paper" || !ledger) {
      run.steps.push(this.step("note", "info", "Rebalancing needs a paper portfolio", { detail: "Switch this agent to Paper trading to see its rebalancing trades." }));
      return;
    }
    const available = new Map(prepared.map((entry) => [instrumentID(entry.instrument), entry]));
    const targetIDs = sortedStrings(Object.keys(config.targets));
    // Every target needs real data, or the weights would be worked out on a partial picture.
    const missing = targetIDs.filter((id) => !available.has(id) || this.state.quotes[id] === undefined);
    if (missing.length > 0) {
      run.steps.push(this.step("data", "failed", "Rebalance skipped", { detail: `Prices are missing for ${missing.join(", ")}, so no trades were worked out.` }));
      return;
    }
    const values: Record<string, number> = {};
    for (const id of targetIDs) {
      const held = ledgerPosition(ledger, id);
      values[id] = held ? marketValue(held) : 0;
    }
    const equity = ledgerEquity(ledger);
    const currency = ledger.currency;
    const monthly = spec.monthlyInvestment !== undefined;
    let contribution = 0;
    let period: string | undefined;
    if (monthly) {
      const sessions = new Set(targetIDs.map((id) => {
        const { instrument, bars } = available.get(id)!;
        return Calendar.dayKey(instrument.venue, bars[bars.length - 1].time);
      }));
      const hasPending = this.state.proposals.some((proposal) => proposal.agentID === agent.id && proposal.status === "pending") ||
        this.state.orders.some((order) => order.source.agentID === agent.id && isOpenStatus(order.status));
      if (sessions.size !== 1 || hasPending) {
        run.steps.push(this.step("note", "info", "Monthly investing and rebalancing are waiting", {
          detail: "Wait for matching completed sessions and for open proposals or orders to resolve.",
        }));
        return;
      }
      period = [...sessions][0].slice(0, 7);
      const currentMonth = Calendar.dayKey(spec.universe[0].venue, now).slice(0, 7);
      if (period === currentMonth && period > (agent.lastMonthlyInvestmentPeriod ?? "") && spec.monthlyInvestment !== undefined) {
        contribution = Math.min(spec.monthlyInvestment.amount, Math.max(ledger.cash, 0));
        if (contribution < spec.monthlyInvestment.amount) {
          run.steps.push(this.step("sizing", "warning", "Monthly amount limited by practice cash", {
            detail: `Available cash for this month's purchases is ${NumberText.money(contribution, currency)}.`,
          }));
        }
      }
    }
    const denominator = monthly ? Object.values(values).reduce((sum, value) => sum + value, 0) : equity;
    const trades = monthly ? monthlyRebalanceTrades(config, values, contribution) : rebalanceTrades(config, values, equity);
    if (trades.length === 0) {
      run.steps.push(this.step("signal", "info", "Holdings are on target", {
        detail: `Nothing has drifted more than ${trimNumber(config.driftThresholdPct)} points from its target.`,
        evidence: targetIDs.map((id) => ({
          label: id.split(":").pop() ?? id,
          value: `${cFixed((values[id] ?? 0) / Math.max(denominator, 0.01) * 100, 1)}% (target ${cFixed(config.targets[id], 1)}%)`,
        })),
      }));
      return;
    }
    const proposalsBefore = run.proposalIDs.length;
    for (const trade of trades) {
      const entry = available.get(trade.instrumentID);
      const last = entry?.bars[entry.bars.length - 1];
      if (!entry || !last) continue;
      const headline = contribution > 0 ? "Monthly investment and allocation check" : "Rebalance";
      const weight = monthly ? (values[trade.instrumentID] ?? 0) / Math.max(denominator, 0.01) * 100 : trade.currentPct;
      const decision: SignalDecision = {
        action: trade.side === "buy" ? "buy" : "sell",
        headline: `${headline}: ${entry.instrument.symbol} is ${cFixed(weight, 1)}% of the portfolio; the target is ${cFixed(trade.targetPct, 1)}%.`,
        evidence: [
          { label: "Current weight", value: `${cFixed(weight, 1)}%` },
          { label: "Target weight", value: `${cFixed(trade.targetPct, 1)}%` },
          { label: "Trade", value: `${capitalized(trade.side)} ${NumberText.money(trade.notional, currency)}` },
        ],
        barTime: last.time, close: last.close,
      };
      if (trade.side === "sell") decision.exitReason = "rebalance";
      this.handle(decision, entry.instrument, entry.provenance, trade.notional, agentID, run, now);
    }
    if (contribution > 0 && period) {
      const created = new Set(run.proposalIDs.slice(proposalsBefore));
      if (this.state.proposals.some((proposal) => created.has(proposal.id) && proposal.side === "buy" &&
        (proposal.status === "pending" || proposal.status === "submitted"))) agent.lastMonthlyInvestmentPeriod = period;
    }
  }

  // MARK: Finishing a run

  private finish(run: AgentRun, agentID: string, dataFailures: number, checked: number, now: number, skipped: boolean): void {
    const state = this.state;
    run.finishedAt = now;
    if (!skipped) {
      const signals = run.signalIDs.length;
      const orders = run.orderIDs.length;
      const blocked = run.steps.filter((step) => step.outcome === "blocked").length;
      const waiting = state.proposals.filter((p) => run.proposalIDs.includes(p.id) && p.status === "pending").length;
      const parts = [`Checked ${plural(checked, "asset")}`];
      if (signals > 0) parts.push(plural(signals, "signal"));
      if (orders > 0) parts.push(plural(orders, "order"));
      if (waiting > 0) parts.push(`${waiting} waiting for approval`);
      if (blocked > 0) parts.push(`${blocked} blocked`);
      if (dataFailures > 0) parts.push(`${dataFailures} without data`);
      if (signals === 0 && orders === 0 && blocked === 0 && dataFailures === 0) parts.push("nothing to do");
      run.summary = parts.join(" · ");
      run.status = checked > 0 && dataFailures === checked ? "failed" : "completed";
    }

    // The agent may have been paused by a circuit breaker during the run.
    const agent = this.agent(agentID);
    if (agent) {
      agent.lastRunAt = now;
      agent.nextRunAt = now + agent.schedule.intervalMinutes * 60_000;
      if (run.status === "failed") {
        agent.consecutiveErrors += 1;
        agent.lastError = "No usable market data for any asset.";
        if (agent.consecutiveErrors === 1) {
          this.notify({
            kind: "dataUnavailable", title: `${agent.name}: market data unavailable`,
            body: "No usable prices came back, so nothing was traded. It will try again.", agentID,
          });
        }
        if (agent.consecutiveErrors >= 5) this.pauseAgent(agentID, now, "repeatedErrors");
      } else if (run.status === "completed") {
        agent.consecutiveErrors = 0;
        delete agent.lastError;
      }
    }
    state.runs.push(run);
    // Keep each agent's trace list short; orders and the audit trail hold the long record.
    const mine = state.runs.filter((r) => r.agentID === agentID);
    if (mine.length > 120) {
      const drop = new Set(mine.slice(0, mine.length - 100).map((r) => r.id));
      state.runs = state.runs.filter((r) => !drop.has(r.id));
    }
  }

  // MARK: - Proposals

  /**
   * A person approves a waiting proposal. The order is checked again against current
   * prices before it is placed, and the proposal says plainly whether an order went in.
   */
  approveProposal(id: string, now: number): OrderResult {
    const proposal = this.state.proposals.find((p) => p.id === id);
    if (!proposal) throw TradingError.notFound("That proposal");
    if (proposal.status !== "pending") {
      throw TradingError.notAllowed(`This proposal is already ${proposalStatusDisplayName(proposal.status).toLowerCase()}.`);
    }
    if (!(now < proposal.expiresAt)) {
      this.expireStaleProposals(now);
      throw TradingError.notAllowed("This proposal has expired. The agent will look again on its next run.");
    }
    const agent = this.agent(proposal.agentID);
    if (!agent) throw TradingError.notFound("That agent");
    if (strategyVersion(agent) !== proposal.strategyVersion) throw TradingError.notAllowed("The strategy changed after this was proposed.");
    this.audit({
      time: now, actor: "user", kind: "proposalApproved",
      summary: `You approved: ${proposal.side} ${proposal.instrument.symbol} for ${agent.name}.`, mode: proposal.mode,
      agentID: agent.id, ledgerID: proposal.ledgerID, proposalID: id, instrumentID: instrumentID(proposal.instrument),
    });
    const scratch = makeRun(this.newID(), agent.id, strategyVersion(agent), "manual", now);
    const result = this.execute(id, scratch, now);
    if (!result) throw TradingError.notFound("That proposal");
    return result;
  }

  rejectProposal(id: string, now: number): void {
    const proposal = this.state.proposals.find((p) => p.id === id);
    if (!proposal) throw TradingError.notFound("That proposal");
    if (proposal.status !== "pending") return;
    proposal.status = "rejected";
    proposal.resolvedAt = now;
    proposal.resolutionNote = "Rejected by you.";
    this.audit({
      time: now, actor: "user", kind: "proposalRejected", summary: `You rejected: ${proposal.side} ${proposal.instrument.symbol}.`,
      mode: proposal.mode, agentID: proposal.agentID, ledgerID: proposal.ledgerID, proposalID: id,
      instrumentID: instrumentID(proposal.instrument),
    });
  }

  private expirePendingProposals(agentID: string, note: string, now: number): void {
    for (const proposal of this.state.proposals) {
      if (proposal.agentID === agentID && proposal.status === "pending") this.expire(proposal, note, now);
    }
  }

  private expireStaleProposals(now: number): void {
    for (const proposal of this.state.proposals) {
      if (proposal.status === "pending" && now >= proposal.expiresAt) this.expire(proposal, "Nobody approved it in time.", now);
    }
  }

  private expire(proposal: TradeProposal, note: string, now: number): void {
    proposal.status = "expired";
    proposal.resolvedAt = now;
    proposal.resolutionNote = note;
    this.audit({
      time: now, actor: "system", kind: "proposalExpired",
      summary: `Proposal to ${proposal.side} ${proposal.instrument.symbol} expired. ${note}`, mode: proposal.mode,
      agentID: proposal.agentID, ledgerID: proposal.ledgerID, proposalID: proposal.id, instrumentID: instrumentID(proposal.instrument),
    });
  }

  // MARK: - Scheduling

  /** Agents whose next run time has arrived. */
  dueAgents(now: number): TradingAgent[] {
    if (this.state.accountPolicy.killSwitchEngaged) return [];
    return this.state.agents.filter((agent) => isDue(agent, now) && !modeIsLive(agent.mode));
  }

  /** Every instrument that needs a fresh quote: open orders, positions and pending proposals. */
  instrumentsNeedingQuotes(): Instrument[] {
    const seen = new Set<string>();
    const out: Instrument[] = [];
    const add = (instrument: Instrument) => {
      const id = instrumentID(instrument);
      if (!seen.has(id)) {
        seen.add(id);
        out.push(instrument);
      }
    };
    for (const order of this.state.orders) if (isOpenStatus(order.status)) add(order.instrument);
    for (const ledger of this.state.ledgers) for (const position of ledger.positions) add(position.instrument);
    for (const proposal of this.state.proposals) if (proposal.status === "pending") add(proposal.instrument);
    return out;
  }
}

export type { ExecutionMode };
export { intentNotional, makePolicy };
