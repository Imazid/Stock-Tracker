import Foundation

/// How much an agent is allowed to do. Each step up is a separate, deliberate choice;
/// nothing is ever promoted automatically.
public enum AgentMode: String, Codable, CaseIterable, Sendable {
    /// Watches the market and reports. Produces no signals and no orders.
    case researchOnly
    /// Produces buy / sell / hold signals with evidence. No orders.
    case signals
    /// Trades a simulated portfolio.
    case paper
    /// Proposes real orders; each one needs a person's approval.
    case approvalRequired
    /// Places real orders by itself, inside fixed limits.
    case autonomousLive

    public var displayName: String {
        switch self {
        case .researchOnly: return "Research only"
        case .signals: return "Signals"
        case .paper: return "Paper trading"
        case .approvalRequired: return "Approval required"
        case .autonomousLive: return "Autonomous"
        }
    }

    public var summary: String {
        switch self {
        case .researchOnly: return "Watches the market and reports what it sees. No signals, no orders."
        case .signals: return "Gives buy, sell and hold signals with the evidence behind them. No orders."
        case .paper: return "Trades a simulated portfolio with pretend money."
        case .approvalRequired: return "Proposes real orders. Nothing is sent until you approve it."
        case .autonomousLive: return "Places real orders by itself, inside the limits you set."
        }
    }

    public var isLive: Bool { self == .approvalRequired || self == .autonomousLive }
    public var placesOrders: Bool { self == .paper || isLive }
    public var producesSignals: Bool { self != .researchOnly }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, stopped
}

public enum PauseReason: String, Codable, Sendable {
    case user, killSwitch, dailyLossLimit, drawdownLimit, repeatedErrors

    public var explanation: String {
        switch self {
        case .user: return "Paused by you."
        case .killSwitch: return "Paused by the kill switch."
        case .dailyLossLimit: return "Paused: today's loss reached the daily limit."
        case .drawdownLimit: return "Paused: the portfolio fell to its drawdown limit."
        case .repeatedErrors: return "Paused after repeated errors."
        }
    }
}

public enum ChangeAuthor: String, Codable, Sendable {
    case user, copilot, template
}

/// One saved version of an agent's strategy. Versions are only ever added, so every
/// signal and trade can name the exact rules that produced it.
public struct StrategyVersion: Codable, Hashable, Identifiable, Sendable {
    public var version: Int
    public var spec: StrategySpec
    public var createdAt: Date
    public var note: String
    public var author: ChangeAuthor

    public var id: Int { version }

    public init(version: Int, spec: StrategySpec, createdAt: Date, note: String, author: ChangeAuthor) {
        self.version = version
        self.spec = spec
        self.createdAt = createdAt
        self.note = note
        self.author = author
    }
}

public struct AgentSchedule: Codable, Hashable, Sendable {
    /// Minutes between runs.
    public var intervalMinutes: Int

    public init(intervalMinutes: Int) {
        self.intervalMinutes = intervalMinutes
    }

    public static let hourly = AgentSchedule(intervalMinutes: 60)

    public var displayName: String {
        switch intervalMinutes {
        case ..<60: return "Every \(intervalMinutes) minutes"
        case 60: return "Every hour"
        case 1_440: return "Once a day"
        default:
            return intervalMinutes % 60 == 0 ? "Every \(intervalMinutes / 60) hours" : "Every \(intervalMinutes) minutes"
        }
    }
}

public struct TradingAgent: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var templateID: String?
    public var mode: AgentMode
    public var status: AgentStatus
    public var pauseReason: PauseReason?
    /// Never empty: version 1 is written when the agent is created.
    public var versions: [StrategyVersion]
    public var riskPolicy: RiskPolicy
    public var ledgerID: UUID?
    /// Money assigned to this agent, in its ledger's currency.
    public var budget: Double
    /// Paper trades wait for approval instead of executing straight away.
    public var reviewEachPaperTrade: Bool
    public var schedule: AgentSchedule
    public var createdAt: Date
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var consecutiveErrors: Int
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, templateID: String? = nil, mode: AgentMode, spec: StrategySpec,
                riskPolicy: RiskPolicy, ledgerID: UUID? = nil, budget: Double, reviewEachPaperTrade: Bool = false,
                schedule: AgentSchedule = .hourly, createdAt: Date, author: ChangeAuthor = .user) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.mode = mode
        self.status = .active
        self.pauseReason = nil
        self.versions = [StrategyVersion(version: 1, spec: spec, createdAt: createdAt, note: "Created", author: author)]
        self.riskPolicy = riskPolicy
        self.ledgerID = ledgerID
        self.budget = budget
        self.reviewEachPaperTrade = reviewEachPaperTrade
        self.schedule = schedule
        self.createdAt = createdAt
        self.lastRunAt = nil
        self.nextRunAt = createdAt
        self.consecutiveErrors = 0
        self.lastError = nil
    }

    public var currentVersion: StrategyVersion { versions[versions.count - 1] }
    public var spec: StrategySpec { currentVersion.spec }
    public var strategyVersion: Int { currentVersion.version }
    public var isRunning: Bool { status == .active }

    public func isDue(at now: Date) -> Bool {
        guard status == .active else { return false }
        guard let nextRunAt else { return true }
        return now >= nextRunAt
    }
}

// MARK: - Signals and proposals

public struct TradingSignal: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var strategyVersion: Int
    public var instrument: Instrument
    public var action: SignalAction
    public var headline: String
    public var evidence: [Evidence]
    public var barTime: Date
    public var close: Double
    public var ruleMargin: Double?
    public var exitReason: ExitReason?
    public var createdAt: Date
    public var provenance: DataProvenance

    public init(id: UUID = UUID(), agentID: UUID, strategyVersion: Int, instrument: Instrument,
                decision: SignalDecision, createdAt: Date, provenance: DataProvenance) {
        self.id = id
        self.agentID = agentID
        self.strategyVersion = strategyVersion
        self.instrument = instrument
        self.action = decision.action
        self.headline = decision.headline
        self.evidence = decision.evidence
        self.barTime = decision.barTime
        self.close = decision.close
        self.ruleMargin = decision.ruleMargin
        self.exitReason = decision.exitReason
        self.createdAt = createdAt
        self.provenance = provenance
    }
}

public enum ProposalStatus: String, Codable, CaseIterable, Sendable {
    /// Waiting for a person to approve or reject it.
    case pending
    /// An order was submitted for it. Whether that order filled is the order's story.
    case submitted
    case rejected
    case expired
    /// The risk engine refused it; no order was ever created.
    case blocked
    /// Approved, but the order could not be submitted.
    case failed

    public var displayName: String {
        switch self {
        case .pending: return "Needs approval"
        case .submitted: return "Order submitted"
        case .rejected: return "Rejected"
        case .expired: return "Expired"
        case .blocked: return "Blocked by risk rules"
        case .failed: return "Failed"
        }
    }

    public var isResolved: Bool { self != .pending }
}

/// A sized order an agent wants to place, with the risk engine's verdict attached.
/// A proposal is a suggestion. It is not an order and it is not a fill.
public struct TradeProposal: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var signalID: UUID
    public var strategyVersion: Int
    public var ledgerID: UUID
    public var instrument: Instrument
    public var side: OrderSide
    public var quantity: Double
    public var referencePrice: Double
    public var notional: Double
    public var estimatedFee: Double
    public var mode: ExecutionMode
    public var status: ProposalStatus
    public var risk: RiskReport
    public var headline: String
    public var sizingNote: String?
    public var signalBarTime: Date
    public var createdAt: Date
    public var expiresAt: Date
    public var resolvedAt: Date?
    public var resolutionNote: String?
    public var orderID: UUID?
    public var clientOrderID: String

    public init(id: UUID = UUID(), agentID: UUID, signalID: UUID, strategyVersion: Int, ledgerID: UUID,
                instrument: Instrument, side: OrderSide, quantity: Double, referencePrice: Double,
                estimatedFee: Double, mode: ExecutionMode, status: ProposalStatus, risk: RiskReport,
                headline: String, sizingNote: String?, signalBarTime: Date, createdAt: Date, expiresAt: Date) {
        self.id = id
        self.agentID = agentID
        self.signalID = signalID
        self.strategyVersion = strategyVersion
        self.ledgerID = ledgerID
        self.instrument = instrument
        self.side = side
        self.quantity = quantity
        self.referencePrice = referencePrice
        self.notional = Rounding.money(quantity * referencePrice)
        self.estimatedFee = estimatedFee
        self.mode = mode
        self.status = status
        self.risk = risk
        self.headline = headline
        self.sizingNote = sizingNote
        self.signalBarTime = signalBarTime
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        // One order per proposal, ever: the key is derived from the proposal itself.
        self.clientOrderID = "proposal-\(id.uuidString)"
    }
}

// MARK: - Run traces

public enum RunTrigger: String, Codable, Sendable {
    case schedule, manual
}

public enum RunStatus: String, Codable, Sendable {
    case completed, skipped, failed
}

public enum StepKind: String, Codable, Sendable {
    case data, research, signal, sizing, risk, proposal, execution, note
}

public enum StepOutcome: String, Codable, Sendable {
    case ok, info, warning, blocked, failed
}

/// One thing the agent did or saw during a run.
public struct RunStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: StepKind
    public var outcome: StepOutcome
    public var instrumentID: String?
    public var title: String
    public var detail: String
    public var evidence: [Evidence]

    public init(id: UUID = UUID(), kind: StepKind, outcome: StepOutcome, instrumentID: String? = nil,
                title: String, detail: String = "", evidence: [Evidence] = []) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.instrumentID = instrumentID
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

/// The full trace of one agent run: what it looked at, what it concluded, which rules
/// passed or failed, and what (if anything) was ordered.
public struct AgentRun: Codable, Identifiable, Sendable {
    public var id: UUID
    public var agentID: UUID
    public var strategyVersion: Int
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var status: RunStatus
    public var summary: String
    public var steps: [RunStep]
    public var signalIDs: [UUID]
    public var proposalIDs: [UUID]
    public var orderIDs: [UUID]

    public init(id: UUID = UUID(), agentID: UUID, strategyVersion: Int, trigger: RunTrigger, startedAt: Date) {
        self.id = id
        self.agentID = agentID
        self.strategyVersion = strategyVersion
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = startedAt
        self.status = .completed
        self.summary = ""
        self.steps = []
        self.signalIDs = []
        self.proposalIDs = []
        self.orderIDs = []
    }
}
