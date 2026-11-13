import Foundation

public struct Position: Codable, Hashable, Identifiable, Sendable {
    public var instrument: Instrument
    public var quantity: Double
    /// What the held quantity cost, buy fees included.
    public var costBasis: Double
    public var openedAt: Date
    public var lastPrice: Double
    public var lastPriceTime: Date?

    public var id: String { instrument.id }
    public var averageCost: Double { quantity > 0 ? costBasis / quantity : 0 }
    public var marketValue: Double { quantity * lastPrice }
    public var unrealizedPnL: Double { marketValue - costBasis }
    public var unrealizedPct: Double { costBasis > 0 ? unrealizedPnL / costBasis * 100 : 0 }

    public init(instrument: Instrument, quantity: Double, costBasis: Double, openedAt: Date,
                lastPrice: Double, lastPriceTime: Date? = nil) {
        self.instrument = instrument
        self.quantity = quantity
        self.costBasis = costBasis
        self.openedAt = openedAt
        self.lastPrice = lastPrice
        self.lastPriceTime = lastPriceTime
    }
}

public struct EquityPoint: Codable, Hashable, Sendable {
    public var time: Date
    public var equity: Double
    public var cash: Double

    public init(time: Date, equity: Double, cash: Double) {
        self.time = time
        self.equity = equity
        self.cash = cash
    }
}

public enum LedgerKind: String, Codable, Sendable {
    /// A simulated portfolio the person trades by hand.
    case manualPaper
    /// A simulated portfolio owned by one agent.
    case agentPaper
}

/// Cash and positions for one book — a paper portfolio or one agent's budget. Every change
/// goes through `apply`, so cash, cost and realised profit can't drift apart.
public struct Ledger: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: LedgerKind
    public var mode: ExecutionMode
    public var currency: String
    public var agentID: UUID?
    public var startingCash: Double
    public var cash: Double
    public var positions: [Position]
    public var realizedPnL: Double
    public var feesPaid: Double
    public var createdAt: Date
    public var equityHistory: [EquityPoint]
    public var peakEquity: Double

    // Daily counters, reset when the ledger's trading day changes.
    public var dayKey: String
    public var dayStartEquity: Double
    public var realizedToday: Double
    public var notionalToday: Double

    public var lastFillAt: [String: Date]
    public var lastBuyAt: [String: Date]
    public var lastExitAt: [String: Date]

    public init(id: UUID = UUID(), name: String, kind: LedgerKind, currency: String = "USD",
                agentID: UUID? = nil, startingCash: Double, createdAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mode = .paper
        self.currency = currency
        self.agentID = agentID
        self.startingCash = Rounding.money(startingCash)
        self.cash = Rounding.money(startingCash)
        self.positions = []
        self.realizedPnL = 0
        self.feesPaid = 0
        self.createdAt = createdAt
        self.equityHistory = [EquityPoint(time: createdAt, equity: Rounding.money(startingCash), cash: Rounding.money(startingCash))]
        self.peakEquity = Rounding.money(startingCash)
        self.dayKey = ""
        self.dayStartEquity = Rounding.money(startingCash)
        self.realizedToday = 0
        self.notionalToday = 0
        self.lastFillAt = [:]
        self.lastBuyAt = [:]
        self.lastExitAt = [:]
        self.dayKey = Self.dayKey(for: createdAt, currency: currency)
    }

    public var positionsValue: Double { positions.reduce(0) { $0 + $1.marketValue } }
    public var equity: Double { cash + positionsValue }
    public var unrealizedPnL: Double { positions.reduce(0) { $0 + $1.unrealizedPnL } }
    public var totalReturn: Double { equity - startingCash }
    public var totalReturnPct: Double { startingCash > 0 ? totalReturn / startingCash * 100 : 0 }
    /// How far equity sits below its highest point, in percent.
    public var drawdownPct: Double { peakEquity > 0 ? max(0, (peakEquity - equity) / peakEquity * 100) : 0 }
    /// Today's change in equity as a percent of where the day started.
    public var dayChangePct: Double { dayStartEquity > 0 ? (equity - dayStartEquity) / dayStartEquity * 100 : 0 }

    public func position(_ instrumentID: String) -> Position? {
        positions.first { $0.id == instrumentID }
    }

    /// The ledger's trading day: Sydney for an AUD book, New York otherwise.
    public static func dayKey(for date: Date, currency: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: currency == "AUD" ? "Australia/Sydney" : "America/New_York")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Starts a new trading day if the date has moved on.
    public mutating func rollDayIfNeeded(now: Date) {
        let key = Self.dayKey(for: now, currency: currency)
        guard key != dayKey else { return }
        dayKey = key
        dayStartEquity = equity
        realizedToday = 0
        notionalToday = 0
    }

    /// Books a fill and returns it with the realised profit filled in.
    /// Buys add their fee to the cost; sells take theirs off the proceeds.
    @discardableResult
    public mutating func apply(_ fill: Fill) -> Fill {
        var fill = fill
        rollDayIfNeeded(now: fill.time)
        let id = fill.instrument.id
        let gross = fill.gross
        switch fill.side {
        case .buy:
            cash = Rounding.money(cash - gross - fill.fee)
            if let index = positions.firstIndex(where: { $0.id == id }) {
                positions[index].quantity = Rounding.round(positions[index].quantity + fill.quantity, places: 9)
                positions[index].costBasis = Rounding.money(positions[index].costBasis + gross + fill.fee)
                positions[index].lastPrice = fill.price
                positions[index].lastPriceTime = fill.time
            } else {
                positions.append(Position(instrument: fill.instrument, quantity: fill.quantity,
                                          costBasis: Rounding.money(gross + fill.fee), openedAt: fill.time,
                                          lastPrice: fill.price, lastPriceTime: fill.time))
            }
            lastBuyAt[id] = fill.time
        case .sell:
            guard let index = positions.firstIndex(where: { $0.id == id }) else { return fill }
            let held = positions[index].quantity
            let sold = min(fill.quantity, held)
            let closing = held - sold <= 1e-9
            let costRemoved = closing ? positions[index].costBasis
                : Rounding.money(positions[index].costBasis / held * sold)
            let realized = Rounding.money(gross - fill.fee - costRemoved)
            cash = Rounding.money(cash + gross - fill.fee)
            realizedPnL = Rounding.money(realizedPnL + realized)
            realizedToday = Rounding.money(realizedToday + realized)
            fill.realizedPnL = realized
            if closing {
                positions.remove(at: index)
                lastExitAt[id] = fill.time
            } else {
                positions[index].quantity = Rounding.round(held - sold, places: 9)
                positions[index].costBasis = Rounding.money(positions[index].costBasis - costRemoved)
                positions[index].lastPrice = fill.price
                positions[index].lastPriceTime = fill.time
            }
        }
        feesPaid = Rounding.money(feesPaid + fill.fee)
        notionalToday = Rounding.money(notionalToday + gross)
        lastFillAt[id] = fill.time
        return fill
    }

    /// Reprices positions from real quotes and records the equity point.
    public mutating func mark(quotes: [String: Quote], now: Date) {
        rollDayIfNeeded(now: now)
        for index in positions.indices {
            guard let quote = quotes[positions[index].id], quote.provenance.isRealMarketData || quote.provenance.kind == .fixture,
                  quote.last > 0 else { continue }
            positions[index].lastPrice = quote.last
            positions[index].lastPriceTime = quote.time
        }
        recordEquity(now: now)
    }

    /// Adds an equity point, keeping at most one per hour for older history.
    public mutating func recordEquity(now: Date) {
        let point = EquityPoint(time: now, equity: Rounding.money(equity), cash: cash)
        if let last = equityHistory.last, now.timeIntervalSince(last.time) < 3_600, equityHistory.count > 1 {
            equityHistory[equityHistory.count - 1] = point
        } else {
            equityHistory.append(point)
        }
        if equityHistory.count > 3_000 { equityHistory.removeFirst(equityHistory.count - 3_000) }
        peakEquity = max(peakEquity, point.equity)
    }
}
