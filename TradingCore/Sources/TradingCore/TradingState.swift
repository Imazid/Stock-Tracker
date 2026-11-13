import Foundation

/// A link to a place orders could be sent. Paper is built in; a real broker connection is
/// listed with exactly the permissions it was granted.
public struct BrokerConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var adapterID: String
    public var name: String
    public var environment: BrokerEnvironment
    public var permissions: [BrokerPermission]
    public var createdAt: Date

    public init(id: UUID = UUID(), adapterID: String, name: String, environment: BrokerEnvironment,
                permissions: [BrokerPermission], createdAt: Date) {
        self.id = id
        self.adapterID = adapterID
        self.name = name
        self.environment = environment
        self.permissions = permissions
        self.createdAt = createdAt
    }

    public var canTrade: Bool { permissions.contains(.trade) }
}

/// What a person fills in (or an AI drafts) to create an agent.
public struct AgentDraft: Codable, Sendable {
    public var name: String
    public var templateID: String?
    public var mode: AgentMode
    public var spec: StrategySpec
    public var budget: Double
    public var maxPositionPct: Double
    /// Full limits, when the person edited them. nil = standard limits for the budget.
    public var riskPolicy: RiskPolicy?
    public var reviewEachPaperTrade: Bool
    public var schedule: AgentSchedule
    /// Manage an existing paper portfolio instead of getting a new one.
    public var attachToLedgerID: UUID?
    public var author: ChangeAuthor

    public init(name: String, templateID: String? = nil, mode: AgentMode = .paper, spec: StrategySpec,
                budget: Double = 10_000, maxPositionPct: Double = 10, riskPolicy: RiskPolicy? = nil,
                reviewEachPaperTrade: Bool = false, schedule: AgentSchedule = .hourly,
                attachToLedgerID: UUID? = nil, author: ChangeAuthor = .user) {
        self.name = name
        self.templateID = templateID
        self.mode = mode
        self.spec = spec
        self.budget = budget
        self.maxPositionPct = maxPositionPct
        self.riskPolicy = riskPolicy
        self.reviewEachPaperTrade = reviewEachPaperTrade
        self.schedule = schedule
        self.attachToLedgerID = attachToLedgerID
        self.author = author
    }

    public var isCryptoOnly: Bool {
        !spec.universe.isEmpty && spec.universe.allSatisfy { $0.assetClass == .crypto }
    }

    public var resolvedPolicy: RiskPolicy {
        riskPolicy ?? .standard(budget: budget, maxPositionPct: maxPositionPct, crypto: isCryptoOnly)
    }
}

public enum TradingError: LocalizedError, Equatable {
    case invalid([String])
    case liveNotAvailable([String])
    case notFound(String)
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let problems): return problems.joined(separator: " ")
        case .liveNotAvailable(let reasons): return reasons.joined(separator: " ")
        case .notFound(let what): return "\(what) wasn't found."
        case .notAllowed(let why): return why
        }
    }
}

/// Something the person should hear about. The app turns these into notifications.
public struct EngineNotice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case approvalNeeded, proposalBlocked, orderSubmitted, orderFilled, orderPartiallyFilled
        case orderRejected, orderCanceled, agentPaused, dailyLossReached, dataUnavailable
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var mode: ExecutionMode
    public var agentID: UUID?
    public var orderID: UUID?
    public var proposalID: UUID?
    public var instrumentID: String?

    public init(kind: Kind, title: String, body: String, mode: ExecutionMode = .paper, agentID: UUID? = nil,
                orderID: UUID? = nil, proposalID: UUID? = nil, instrumentID: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.body = body
        self.mode = mode
        self.agentID = agentID
        self.orderID = orderID
        self.proposalID = proposalID
        self.instrumentID = instrumentID
    }
}

public struct OrderPreview: Sendable {
    public var instrument: Instrument
    public var side: OrderSide
    public var type: OrderType
    public var timeInForce: TimeInForce
    public var quantity: Double
    /// The price the estimate uses: the ask to buy, the bid to sell, or the order's own limit.
    public var estimatedPrice: Double
    public var estimatedValue: Double
    public var estimatedFee: Double
    /// Cash left after a buy, or cash after the proceeds of a sell.
    public var cashAfter: Double
    public var currency: String
    public var ledgerName: String
    public var mode: ExecutionMode
    public var quote: Quote?
    public var spreadBps: Double?
    public var usesModelledSpread: Bool
    public var willQueueUntilOpen: Bool
    public var nextOpen: Date?
    public var risk: RiskReport

    public var canSubmit: Bool { risk.isApproved }
}

public enum OrderResult: Sendable {
    case accepted(order: Order, fills: [Fill], risk: RiskReport)
    case rejected(order: Order?, risk: RiskReport)

    public var order: Order? {
        switch self {
        case .accepted(let order, _, _): return order
        case .rejected(let order, _): return order
        }
    }

    public var risk: RiskReport {
        switch self {
        case .accepted(_, _, let risk): return risk
        case .rejected(_, let risk): return risk
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Everything the trading side of the app knows. One value, saved and loaded whole, changed
/// only through `TradingEngine`.
public struct TradingState: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var accountPolicy: AccountPolicy
    public var paperConfig: PaperBrokerConfig
    public var connections: [BrokerConnection]
    public var ledgers: [Ledger]
    public var agents: [TradingAgent]
    public var signals: [TradingSignal]
    public var proposals: [TradeProposal]
    public var orders: [Order]
    public var fills: [Fill]
    public var runs: [AgentRun]
    public var audit: AuditLog
    public var knownClientOrderIDs: Set<String>
    /// The latest real quote seen for each instrument.
    public var quotes: [String: Quote]
    public var stats: [String: InstrumentStats]
    /// Agent id → the trading day its daily-loss notice was last sent, so it's sent once a day.
    public var dailyLossNotified: [String: String]

    public init() {
        dailyLossNotified = [:]
        schemaVersion = Self.currentSchemaVersion
        accountPolicy = AccountPolicy()
        paperConfig = PaperBrokerConfig()
        connections = []
        ledgers = []
        agents = []
        signals = []
        proposals = []
        orders = []
        fills = []
        runs = []
        audit = AuditLog()
        knownClientOrderIDs = []
        quotes = [:]
        stats = [:]
    }

    public func ledger(_ id: UUID?) -> Ledger? {
        guard let id else { return nil }
        return ledgers.first { $0.id == id }
    }

    public func agent(_ id: UUID?) -> TradingAgent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    public var openOrders: [Order] { orders.filter { $0.status.isOpen } }
    public var pendingProposals: [TradeProposal] { proposals.filter { $0.status == .pending } }
    public var manualLedgers: [Ledger] { ledgers.filter { $0.kind == .manualPaper } }

    /// Equity across every paper ledger in one currency.
    public func paperEquity(currency: String) -> Double {
        ledgers.filter { $0.mode == .paper && $0.currency == currency }.reduce(0) { $0 + $1.equity }
    }
}

/// JSON settings for saving `TradingState`. Dates are stored to the millisecond, which is
/// also what the audit hashes cover.
public enum TradingCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
