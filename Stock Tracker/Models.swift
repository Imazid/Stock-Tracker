import Foundation

// MARK: - Asset Kind

enum AssetKind: String, Codable, CaseIterable {
    case stock = "Stock"
    case crypto = "Crypto"
}

// MARK: - Time Range

enum TimeRange: String, CaseIterable {
    case oneDay      = "1D"
    case oneWeek     = "1W"
    case oneMonth    = "1M"
    case threeMonths = "3M"
    case sixMonths   = "6M"
    case ytd         = "YTD"
    case oneYear     = "1Y"
    case twoYears    = "2Y"
    case fiveYears   = "5Y"
    case tenYears    = "10Y"
    case all         = "All"
}

/// Used by the mock/random price history generator
extension TimeRange {
    var volatility: Double {
        switch self {
        case .oneDay:      return 0.01
        case .oneWeek:     return 0.02
        case .oneMonth:    return 0.03
        case .threeMonths: return 0.04
        case .sixMonths:   return 0.05
        case .ytd:         return 0.05
        case .oneYear:     return 0.06
        case .twoYears:    return 0.08
        case .fiveYears:   return 0.10
        case .tenYears:    return 0.12
        case .all:         return 0.15
        }
    }
}

// MARK: - Price Direction

enum PriceDirection {
    case up, down, unchanged
}

// MARK: - Asset

struct AssetPriceMove: Hashable, Codable {
    enum Source: String, Codable {
        case alpacaEquity, yahooEquity, coinGecko, alpacaCrypto

        var label: String {
            switch self {
            case .alpacaEquity: "Alpaca IEX"
            case .yahooEquity: "Yahoo Finance"
            case .coinGecko: "CoinGecko aggregate"
            case .alpacaCrypto: "Alpaca crypto"
            }
        }

        var reference: String {
            switch self {
            case .alpacaEquity, .yahooEquity: "Previous session close"
            case .coinGecko: "Price 24 hours earlier"
            case .alpacaCrypto: "Previous UTC daily close"
            }
        }
    }

    let source: Source
    let observedAt: Date
    let currency: String
    let last: Double
    let reference: Double

    init?(source: Source, observedAt: Date?, currency: String, last: Double, reference: Double?) {
        guard let observedAt, let reference, last.isFinite, last > 0, reference.isFinite, reference > 0 else { return nil }
        self.source = source
        self.observedAt = observedAt
        self.currency = currency
        self.last = last
        self.reference = reference
    }
}

struct Asset: Identifiable, Hashable, Codable {
    let id: UUID
    let symbol: String
    let name: String
    var price: Double
    var change: Double
    var changePercent: Double
    var volume: Double
    let kind: AssetKind
    
    // Optional company / asset statistics
    var marketCap: Double?
    var peRatio: Double?
    var eps: Double?
    var week52High: Double?
    var week52Low: Double?
    var avgVolume: Double?
    var dividend: Double?
    var beta: Double?
    let exchange: String
    var isETF: Bool?
    var priceMove: AssetPriceMove?
    
    init(
        id: UUID = UUID(),
        symbol: String,
        name: String,
        price: Double,
        change: Double,
        changePercent: Double,
        volume: Double,
        kind: AssetKind,
        marketCap: Double? = nil,
        peRatio: Double? = nil,
        eps: Double? = nil,
        week52High: Double? = nil,
        week52Low: Double? = nil,
        avgVolume: Double? = nil,
        dividend: Double? = nil,
        beta: Double? = nil,
        exchange: String,
        isETF: Bool? = nil,
        priceMove: AssetPriceMove? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.volume = volume
        self.kind = kind
        self.marketCap = marketCap
        self.peRatio = peRatio
        self.eps = eps
        self.week52High = week52High
        self.week52Low = week52Low
        self.avgVolume = avgVolume
        self.dividend = dividend
        self.beta = beta
        self.exchange = exchange
        self.isETF = isETF
        self.priceMove = priceMove
        
        
    }
    
    var isPositive: Bool { change >= 0 }

    /// Create an Asset from a MarketIndex for navigation into detail views.
    init(from index: MarketIndex) {
        let cryptoSymbols: Set<String> = ["BTC", "ETH"]
        self.init(
            symbol: index.symbol,
            name: index.name,
            price: index.price,
            change: index.change,
            changePercent: index.changePercent,
            volume: 0,
            kind: cryptoSymbols.contains(index.symbol) ? .crypto : .stock,
            exchange: ""
        )
    }
}


struct Candle: Identifiable {
    let id = UUID()
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?  // Optional for extended metrics
    
    var isBullish: Bool { close >= open }
}

// MARK: - Price History

// MARK: - Price Point (ONLY ONE IN THE ENTIRE PROJECT!)
struct PricePoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
    
    // Optional: for future OHLC support
    var open: Double { price }
    var high: Double { price * 1.01 }
    var low: Double { price * 0.99 }
    var close: Double { price }
}

// MARK: - Portfolio

struct HoldingBrokerAccount: Codable, Equatable, Sendable {
    let account_id: String
    let label: String
    let institution: String
    var observed_at: String
    var tracking: Bool
}

struct PortfolioHolding: Identifiable, Codable {
    let id: UUID
    var asset: Asset
    var shares: Double
    var avgCost: Double
    let dateAdded: Date
    var transactions: [Transaction]
    var brokerAccount: HoldingBrokerAccount?
    var ledgerRevision: UUID?
    
    init(
        id: UUID = UUID(),
        asset: Asset,
        shares: Double,
        avgCost: Double,
        dateAdded: Date = Date(),
        transactions: [Transaction] = [],
        brokerAccount: HoldingBrokerAccount? = nil,
        ledgerRevision: UUID? = nil
    ) {
        self.id = id
        self.asset = asset
        self.shares = shares
        self.avgCost = avgCost
        self.dateAdded = dateAdded
        self.transactions = transactions
        self.brokerAccount = brokerAccount
        self.ledgerRevision = ledgerRevision
    }
    
    /// Current market value = current price * shares
    var currentValue: Double {
        asset.price * shares
    }
    
    /// Cost basis = average cost * shares
    var costBasis: Double {
        avgCost * shares
    }
    
    /// Unrealised P/L
    var profitLoss: Double {
        currentValue - costBasis
    }
    
    var profitLossPercent: Double {
        guard costBasis != 0 else { return 0 }
        return (profitLoss / costBasis) * 100.0
    }

    /// Replay of the transactions: realised profit from sales lives here.
    var ledger: PositionLedger { PositionLedger(transactions) }

    /// Profit already banked from sales (USD), after fees.
    var realizedGain: Double { ledger.realized }

    /// Unrealised on what's still held + realised on what was sold (USD).
    var totalReturn: Double { profitLoss + realizedGain }

    /// Everything ever paid for this holding: cost of what's held + cost of what was sold.
    var totalInvested: Double { costBasis + ledger.costOfSold }

    var totalReturnPercent: Double {
        guard totalInvested > 0 else { return 0 }
        return totalReturn / totalInvested * 100
    }
}

// MARK: - Transactions

nonisolated struct TradeProvenance: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case manualTrade = "manual_trade"
        case openingPosition = "opening_position"
        case csvPosition = "csv_position"
        case brokerPosition = "broker_position"
    }

    enum Conversion: String, Codable, Sendable {
        case usd
        case appReference = "app_reference"
        case appFallback = "app_fallback"
    }

    let source: Source
    let currency: String?
    let unitPrice: Double?
    let fees: Double?
    /// The app's multiplier for USD bookkeeping when recorded or edited.
    let usdPerUnit: Double?
    let conversion: Conversion?
    let conversionRecordedAt: String?

    func withAmounts(unitPrice: Double?, fees: Double?) -> Self {
        Self(source: source, currency: currency, unitPrice: unitPrice, fees: fees,
             usdPerUnit: usdPerUnit, conversion: conversion, conversionRecordedAt: conversionRecordedAt)
    }
}

struct Transaction: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let shares: Double
    let pricePerShare: Double
    let type: TransactionType
    /// Brokerage for this trade, USD. Added to the cost of a buy; taken off the proceeds of a sell.
    let fees: Double
    /// Average cost (USD) when a sale was recorded. Used only when the transaction list
    /// doesn't show how the shares were bought (older holdings, broker imports).
    let avgCostAtSale: Double?
    let provenance: TradeProvenance?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        shares: Double,
        pricePerShare: Double,
        type: TransactionType,
        fees: Double = 0,
        avgCostAtSale: Double? = nil,
        provenance: TradeProvenance? = nil
    ) {
        self.id = id
        self.date = date
        self.shares = shares
        self.pricePerShare = pricePerShare
        self.type = type
        self.fees = fees
        self.avgCostAtSale = avgCostAtSale
        self.provenance = provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        shares = try c.decode(Double.self, forKey: .shares)
        pricePerShare = try c.decode(Double.self, forKey: .pricePerShare)
        type = try c.decode(TransactionType.self, forKey: .type)
        // Added 2026-10-17; older saves don't have them.
        fees = try c.decodeIfPresent(Double.self, forKey: .fees) ?? 0
        avgCostAtSale = try c.decodeIfPresent(Double.self, forKey: .avgCostAtSale)
        provenance = try c.decodeIfPresent(TradeProvenance.self, forKey: .provenance)
    }

    /// Shares × price, before fees.
    var totalValue: Double {
        shares * pricePerShare
    }
}

/// A position replayed from its transactions in date order (average-cost method).
/// Realised profit is computed here — never stored — so editing or deleting any
/// transaction re-derives it.
struct PositionLedger {
    private(set) var shares = 0.0
    /// Cost of the shares still held (USD, fees included).
    private(set) var cost = 0.0
    /// Profit banked from sales (USD): (sale price − average cost) × quantity − fees.
    private(set) var realized = 0.0
    /// What the sold shares had cost (USD) — the denominator for a realised %.
    private(set) var costOfSold = 0.0
    /// Sale proceeds after fees (USD).
    private(set) var proceeds = 0.0
    private(set) var sellCount = 0
    /// Realised profit of each sale, by transaction id (USD).
    private(set) var realizedBySale: [UUID: Double] = [:]
    /// Sales whose cost isn't known (no earlier buys, no recorded basis, or cost left blank).
    private(set) var unknownBasisSells = 0

    var avgCost: Double { shares > 0 ? cost / shares : 0 }

    init(_ transactions: [Transaction]) {
        for t in transactions.sorted(by: { $0.date < $1.date }) {
            switch t.type {
            case .buy:
                shares += t.shares
                cost += t.shares * t.pricePerShare + t.fees
            case .sell:
                sellCount += 1
                let covered = shares + 1e-9 >= t.shares
                let basis: Double? = covered && shares > 0 ? cost / shares : t.avgCostAtSale
                // A cost of 0 is the app's "cost not entered" — the gain is unknown, not the whole sale.
                if let basis, basis > 0 {
                    let gain = (t.pricePerShare - basis) * t.shares - t.fees
                    realized += gain
                    realizedBySale[t.id] = gain
                    costOfSold += basis * t.shares
                    proceeds += t.shares * t.pricePerShare - t.fees
                } else {
                    unknownBasisSells += 1
                }
                let n = min(t.shares, shares)
                if shares > 0 { cost -= cost / shares * n }
                shares -= n
                if shares <= 1e-9 { shares = 0; cost = 0 }
            }
        }
    }
}

/// A holding that was sold down to zero. Kept so its realised profit still counts
/// in the portfolio's total return and the trades can be looked back on.
struct ClosedPosition: Identifiable, Codable {
    /// The id the holding had while it was open.
    let id: UUID
    let asset: Asset
    let transactions: [Transaction]
    let openedAt: Date
    let closedAt: Date

    var ledger: PositionLedger { PositionLedger(transactions) }
    var realizedGain: Double { ledger.realized }
    var realizedPercent: Double {
        let base = ledger.costOfSold
        return base > 0 ? realizedGain / base * 100 : 0
    }
}

enum TransactionType: String, Codable {
    case buy = "Buy"
    case sell = "Sell"
}


// MARK: - Chat Message (for AI Agent)
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    var role: String? = nil
}
// MARK: - News

struct NewsArticle: Identifiable {
    let id = UUID()
    let title: String
    let source: String
    let url: String
    let imageURL: String?
    let publishedAt: Date
    let summary: String
    let relatedSymbols: [String]
}

// MARK: - Portfolio Snapshot (for portfolio performance chart)

struct PortfolioSnapshot: Identifiable, Codable {
    let id = UUID()
    let date: Date
    let totalValue: Double

    var utcDay: String { String(date.ISO8601Format().prefix(10)) }
    
    enum CodingKeys: String, CodingKey {
        case date
        case totalValue
    }
    
    init(date: Date, totalValue: Double) {
        self.date = date
        self.totalValue = totalValue
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(Date.self, forKey: .date)
        self.totalValue = try container.decode(Double.self, forKey: .totalValue)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(totalValue, forKey: .totalValue)
    }
}

// MARK: - Portfolio Group

struct PortfolioGroup: Identifiable, Codable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    var id: UUID
    var name: String
    var emoji: String
    var holdings: [PortfolioHolding]
    var history: [PortfolioSnapshot]
    /// Holdings sold down to zero (their realised profit still counts).
    var closedPositions: [ClosedPosition]

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "💼",
        holdings: [PortfolioHolding] = [],
        history: [PortfolioSnapshot] = [],
        closedPositions: [ClosedPosition] = []
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.holdings = holdings
        self.history = history
        self.closedPositions = closedPositions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        holdings = try c.decode([PortfolioHolding].self, forKey: .holdings)
        history = try c.decode([PortfolioSnapshot].self, forKey: .history)
        // Added 2026-10-17; older saves don't have it.
        closedPositions = try c.decodeIfPresent([ClosedPosition].self, forKey: .closedPositions) ?? []
    }
}

// MARK: - Watchlist Group

struct WatchlistGroup: Identifiable, Codable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var assets: [Asset]
    var savedDates: [String: Date]?

    init(id: UUID = UUID(), name: String, assets: [Asset] = [], savedDates: [String: Date]? = nil) {
        self.id = id
        self.name = name
        self.assets = assets
        self.savedDates = savedDates
    }
}

// MARK: - Market Index
struct MarketIndex: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let price: Double
    let change: Double
    let changePercent: Double
    var sparkline: [Double] = []

    var isPositive: Bool { change >= 0 }
}
