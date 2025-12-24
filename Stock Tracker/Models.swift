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

// MARK: - Asset

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
        exchange: String
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
        
        
    }
    
    var isPositive: Bool { change >= 0 }
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

struct PortfolioHolding: Identifiable, Codable {
    let id: UUID
    var asset: Asset
    var shares: Double
    var avgCost: Double
    let dateAdded: Date
    var transactions: [Transaction]
    
    init(
        id: UUID = UUID(),
        asset: Asset,
        shares: Double,
        avgCost: Double,
        dateAdded: Date = Date(),
        transactions: [Transaction] = []
    ) {
        self.id = id
        self.asset = asset
        self.shares = shares
        self.avgCost = avgCost
        self.dateAdded = dateAdded
        self.transactions = transactions
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
}

// MARK: - Transactions

struct Transaction: Identifiable, Codable {
    let id: UUID
    let date: Date
    let shares: Double
    let pricePerShare: Double
    let type: TransactionType
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        shares: Double,
        pricePerShare: Double,
        type: TransactionType
    ) {
        self.id = id
        self.date = date
        self.shares = shares
        self.pricePerShare = pricePerShare
        self.type = type
    }
    
    var totalValue: Double {
        shares * pricePerShare
    }
}

enum TransactionType: String, Codable {
    case buy = "Buy"
    case sell = "Sell"
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

struct PortfolioSnapshot: Identifiable {
    let id = UUID()
    let date: Date
    let totalValue: Double
}

// MARK: - Market Index
struct MarketIndex: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let price: Double
    let change: Double
    let changePercent: Double
    
    var isPositive: Bool { change >= 0 }
}
