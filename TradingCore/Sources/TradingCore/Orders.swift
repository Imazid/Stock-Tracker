import Foundation

public enum OrderSide: String, Codable, CaseIterable, Sendable {
    case buy, sell
}

public enum OrderType: String, Codable, CaseIterable, Sendable {
    case market, limit, stop, stopLimit

    public var displayName: String {
        switch self {
        case .market: return "Market"
        case .limit: return "Limit"
        case .stop: return "Stop"
        case .stopLimit: return "Stop limit"
        }
    }

    public var needsLimitPrice: Bool { self == .limit || self == .stopLimit }
    public var needsStopPrice: Bool { self == .stop || self == .stopLimit }
}

public enum TimeInForce: String, Codable, CaseIterable, Sendable {
    case day, gtc, ioc, fok

    public var displayName: String {
        switch self {
        case .day: return "Day"
        case .gtc: return "Good till cancelled"
        case .ioc: return "Immediate or cancel"
        case .fok: return "Fill or kill"
        }
    }
}

/// Paper money or real money. Carried on every order, fill, proposal and ledger so the two
/// can never be mixed up.
public enum ExecutionMode: String, Codable, CaseIterable, Sendable {
    case paper, live
}

public enum OrderStatus: String, Codable, CaseIterable, Sendable {
    /// Sent to the venue, not yet acknowledged (live only).
    case pendingSubmit
    /// Working at the venue.
    case accepted
    case partiallyFilled
    case filled
    case canceled
    case rejected
    case expired

    public var isOpen: Bool { self == .pendingSubmit || self == .accepted || self == .partiallyFilled }
    public var isTerminal: Bool { !isOpen }

    /// The only moves an order may make. Anything else is a bug or a bad broker message,
    /// and the engine refuses it rather than guessing.
    public func canTransition(to next: OrderStatus) -> Bool {
        switch self {
        case .pendingSubmit:
            return [.accepted, .partiallyFilled, .filled, .canceled, .rejected, .expired].contains(next)
        case .accepted:
            return [.partiallyFilled, .filled, .canceled, .rejected, .expired].contains(next)
        case .partiallyFilled:
            return [.partiallyFilled, .filled, .canceled, .expired].contains(next)
        case .filled, .canceled, .rejected, .expired:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .pendingSubmit: return "Sending"
        case .accepted: return "Working"
        case .partiallyFilled: return "Partly filled"
        case .filled: return "Filled"
        case .canceled: return "Cancelled"
        case .rejected: return "Rejected"
        case .expired: return "Expired"
        }
    }
}

/// Who asked for an order.
public struct OrderSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case manual, agent }
    public var kind: Kind
    public var agentID: UUID?
    public var proposalID: UUID?

    public init(kind: Kind, agentID: UUID? = nil, proposalID: UUID? = nil) {
        self.kind = kind
        self.agentID = agentID
        self.proposalID = proposalID
    }

    public static let manual = OrderSource(kind: .manual)
    public static func agent(_ agentID: UUID, proposal: UUID? = nil) -> OrderSource {
        OrderSource(kind: .agent, agentID: agentID, proposalID: proposal)
    }

    public var isAgent: Bool { kind == .agent }
}

/// What someone wants to trade, before any check has run.
public struct OrderRequest: Codable, Hashable, Sendable {
    /// Idempotency key: the same key is never accepted twice.
    public var clientOrderID: String
    public var ledgerID: UUID
    public var instrument: Instrument
    public var side: OrderSide
    public var type: OrderType
    /// Units to trade. Give this or `notional`.
    public var quantity: Double?
    /// Cash amount to trade (market orders only).
    public var notional: Double?
    public var limitPrice: Double?
    public var stopPrice: Double?
    public var timeInForce: TimeInForce
    public var source: OrderSource
    public var mode: ExecutionMode
    /// The completed bar an agent's signal came from.
    public var signalBarTime: Date?

    public init(clientOrderID: String = UUID().uuidString, ledgerID: UUID, instrument: Instrument,
                side: OrderSide, type: OrderType = .market, quantity: Double? = nil, notional: Double? = nil,
                limitPrice: Double? = nil, stopPrice: Double? = nil, timeInForce: TimeInForce = .day,
                source: OrderSource = .manual, mode: ExecutionMode = .paper, signalBarTime: Date? = nil) {
        self.clientOrderID = clientOrderID
        self.ledgerID = ledgerID
        self.instrument = instrument
        self.side = side
        self.type = type
        self.quantity = quantity
        self.notional = notional
        self.limitPrice = limitPrice
        self.stopPrice = stopPrice
        self.timeInForce = timeInForce
        self.source = source
        self.mode = mode
        self.signalBarTime = signalBarTime
    }
}

public struct Order: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var clientOrderID: String
    public var ledgerID: UUID
    public var instrument: Instrument
    public var side: OrderSide
    public var type: OrderType
    public var quantity: Double
    public var limitPrice: Double?
    public var stopPrice: Double?
    public var timeInForce: TimeInForce
    public var source: OrderSource
    public var mode: ExecutionMode
    public var status: OrderStatus
    public var filledQuantity: Double
    public var averageFillPrice: Double
    public var fees: Double
    /// The price the order was sized and checked against. A fill far from it is refused.
    public var referencePrice: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date?
    public var stopTriggeredAt: Date?
    /// Why the order was rejected, cancelled or is waiting.
    public var statusNote: String?
    public var signalBarTime: Date?
    /// The venue's own id for the order (live only).
    public var brokerOrderID: String?

    public init(id: UUID = UUID(), clientOrderID: String, ledgerID: UUID, instrument: Instrument, side: OrderSide,
                type: OrderType, quantity: Double, limitPrice: Double? = nil, stopPrice: Double? = nil,
                timeInForce: TimeInForce, source: OrderSource, mode: ExecutionMode, status: OrderStatus,
                referencePrice: Double, createdAt: Date, expiresAt: Date? = nil, statusNote: String? = nil,
                signalBarTime: Date? = nil) {
        self.id = id
        self.clientOrderID = clientOrderID
        self.ledgerID = ledgerID
        self.instrument = instrument
        self.side = side
        self.type = type
        self.quantity = quantity
        self.limitPrice = limitPrice
        self.stopPrice = stopPrice
        self.timeInForce = timeInForce
        self.source = source
        self.mode = mode
        self.status = status
        self.filledQuantity = 0
        self.averageFillPrice = 0
        self.fees = 0
        self.referencePrice = referencePrice
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.expiresAt = expiresAt
        self.statusNote = statusNote
        self.signalBarTime = signalBarTime
    }

    public var remainingQuantity: Double { max(quantity - filledQuantity, 0) }
    public var filledNotional: Double { filledQuantity * averageFillPrice }

    /// Moves the order to `next`, or returns false and changes nothing if that move isn't allowed.
    @discardableResult
    public mutating func transition(to next: OrderStatus, at time: Date, note: String? = nil) -> Bool {
        guard status.canTransition(to: next) else { return false }
        status = next
        updatedAt = time
        if let note { statusNote = note }
        return true
    }
}

public struct Fill: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var orderID: UUID
    public var ledgerID: UUID
    public var instrument: Instrument
    public var side: OrderSide
    public var quantity: Double
    public var price: Double
    public var fee: Double
    public var time: Date
    public var source: OrderSource
    public var mode: ExecutionMode
    /// Profit banked by this fill (sells only), after fees. Set when the ledger applies it.
    public var realizedPnL: Double?
    public var signalBarTime: Date?

    public init(id: UUID = UUID(), orderID: UUID, ledgerID: UUID, instrument: Instrument, side: OrderSide,
                quantity: Double, price: Double, fee: Double, time: Date, source: OrderSource,
                mode: ExecutionMode, signalBarTime: Date? = nil) {
        self.id = id
        self.orderID = orderID
        self.ledgerID = ledgerID
        self.instrument = instrument
        self.side = side
        self.quantity = quantity
        self.price = price
        self.fee = fee
        self.time = time
        self.source = source
        self.mode = mode
        self.signalBarTime = signalBarTime
    }

    /// Quantity × price, to the cent, before fees.
    public var gross: Double { Rounding.money(quantity * price) }
}
