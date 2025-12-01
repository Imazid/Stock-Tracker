import Foundation
import Combine

@MainActor
final class MarketData: ObservableObject {
    // Core datasets
    @Published var stocks: [Asset] = []
    @Published var crypto: [Asset] = []
    @Published var portfolio: [PortfolioHolding] = []
    
    // Extra state used by various screens
    @Published var watchlist: [Asset] = []
    @Published var newsArticles: [NewsArticle] = []
    @Published var portfolioHistory: [PortfolioSnapshot] = []
    
    // MARK: - Aggregated portfolio metrics
    
    /// Current total market value of the portfolio
    var totalPortfolioValue: Double {
        portfolio.reduce(0) { $0 + $1.currentValue }
    }
    
    /// Total cost basis for all holdings
    var totalCostBasis: Double {
        portfolio.reduce(0) { $0 + $1.costBasis }
    }
    
    /// Absolute profit/loss in currency
    var totalProfitLoss: Double {
        totalPortfolioValue - totalCostBasis
    }
    
    /// Profit/loss as a percentage of cost basis
    var totalProfitLossPercent: Double {
        guard totalCostBasis != 0 else { return 0 }
        return (totalProfitLoss / totalCostBasis) * 100.0
    }
    
    /// "Today's" absolute P/L based on last vs previous portfolioHistory point
    var dailyProfitLoss: Double {
        guard portfolioHistory.count >= 2 else { return 0 }
        let last = portfolioHistory[portfolioHistory.count - 1].totalValue
        let prev = portfolioHistory[portfolioHistory.count - 2].totalValue
        return last - prev
    }
    
    /// "Today's" P/L percentage relative to previous value
    var dailyProfitLossPercent: Double {
        guard portfolioHistory.count >= 2 else { return 0 }
        let last = portfolioHistory[portfolioHistory.count - 1].totalValue
        let prev = portfolioHistory[portfolioHistory.count - 2].totalValue
        guard prev != 0 else { return 0 }
        return (last - prev) / prev * 100.0
    }
    
    init() {
        loadMockData()
        generatePortfolioHistory()
        loadMockNews()
    }
    
    // MARK: - Mock bootstrap data
    
    private func loadMockData() {
        // Simple seed data so the UI has something to show
        stocks = [
            Asset(symbol: "AAPL", name: "Apple Inc.",  price: 189.95, change: 2.34,  changePercent: 1.25, volume: 52_340_000, kind: .stock),
            Asset(symbol: "GOOGL", name: "Alphabet Inc.", price: 141.80, change: -0.45, changePercent: -0.32, volume: 24_560_000, kind: .stock),
            Asset(symbol: "TSLA", name: "Tesla Inc.", price: 202.10, change: 5.10, changePercent: 2.59, volume: 89_000_000, kind: .stock),
            Asset(symbol: "MSFT", name: "Microsoft Corp.", price: 410.25, change: 1.12, changePercent: 0.27, volume: 29_000_000, kind: .stock)
        ]
        
        crypto = [
            Asset(symbol: "BTC", name: "Bitcoin",  price: 62_350.0, change: 450.0,  changePercent: 0.73, volume: 18_000.0,     kind: .crypto),
            Asset(symbol: "ETH", name: "Ethereum", price: 3_250.0,  change: -25.0,   changePercent: -0.76, volume: 240_000.0,   kind: .crypto),
            Asset(symbol: "SOL", name: "Solana",   price: 155.0,    change: 3.2,    changePercent: 2.11, volume: 5_600_000.0, kind: .crypto),
            Asset(symbol: "ADA", name: "Cardano",  price: 0.58,     change: 0.02,   changePercent: 3.56, volume: 90_000_000.0, kind: .crypto)
        ]
        
        portfolio = [
            PortfolioHolding(asset: stocks[0], shares: 10,  avgCost: 170),
            PortfolioHolding(asset: stocks[1], shares: 8,   avgCost: 130),
            PortfolioHolding(asset: crypto[0], shares: 0.3, avgCost: 50_000),
            PortfolioHolding(asset: crypto[1], shares: 1.5, avgCost: 2_900)
        ]
        
        // Default watchlist: first few assets
        watchlist = Array(stocks.prefix(4)) + Array(crypto.prefix(2))
    }
    
    private func loadMockNews() {
        newsArticles = [
            NewsArticle(
                title: "Apple Announces New AI Features for iPhone",
                source: "TechCrunch",
                url: "https://techcrunch.com",
                imageURL: nil,
                publishedAt: Date(),
                summary: "Apple reveals new on-device AI features across the iPhone lineup.",
                relatedSymbols: ["AAPL"]
            ),
            NewsArticle(
                title: "Bitcoin Surges Past $60K as Institutional Interest Grows",
                source: "CoinDesk",
                url: "https://coindesk.com",
                imageURL: nil,
                publishedAt: Calendar.current.date(byAdding: .hour, value: -3, to: Date()) ?? Date(),
                summary: "Major institutions are increasing their exposure to BTC.",
                relatedSymbols: ["BTC"]
            ),
            NewsArticle(
                title: "Tesla Reports Record Deliveries This Quarter",
                source: "Bloomberg",
                url: "https://bloomberg.com",
                imageURL: nil,
                publishedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
                summary: "Tesla beats analyst expectations with record EV deliveries.",
                relatedSymbols: ["TSLA"]
            )
        ]
    }
    
    // MARK: - Public API integration entry point
    
    /// Refreshes quotes (stocks + crypto) and news using the live APIs.
    func refreshFromAPI() async {
        await refreshAssetsFromAPI()
        await refreshNewsFromAPI()
    }
    
    /// Fetch price history for charts, falling back to a local mock if API fails.
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint] {
        do {
            return try await APIService.shared.fetchHistoricalData(symbol: asset.symbol, range: range)
        } catch {
            print("Failed to fetch historical data for \(asset.symbol): \(error)")
            return generatePriceHistoryFallback(for: asset, range: range)
        }
    }
    
    // MARK: - Quotes
    
    private func refreshAssetsFromAPI() async {
        // Update stocks using AlphaVantage
        for index in stocks.indices {
            let current = stocks[index]
            do {
                let apiAsset = try await APIService.shared.fetchStockQuote(symbol: current.symbol)
                stocks[index] = mergedAsset(old: current, api: apiAsset)
            } catch {
                print("Failed to fetch stock quote for \(current.symbol): \(error)")
            }
        }
        
        // Update crypto using CoinGecko
        let idMap: [String: String] = [
            "BTC": "bitcoin",
            "ETH": "ethereum",
            "SOL": "solana",
            "ADA": "cardano"
        ]
        
        for index in crypto.indices {
            let current = crypto[index]
            guard let id = idMap[current.symbol] else { continue }
            do {
                let apiAsset = try await APIService.shared.fetchCryptoPrice(id: id)
                crypto[index] = mergedAsset(old: current, api: apiAsset)
            } catch {
                print("Failed to fetch crypto price for \(current.symbol): \(error)")
            }
        }
    }
    
    /// Keeps your local metadata (marketCap, beta, etc.) but updates live fields.
    private func mergedAsset(old: Asset, api: Asset) -> Asset {
        Asset(
            id: old.id,
            symbol: old.symbol,
            name: old.name,
            price: api.price,
            change: api.change,
            changePercent: api.changePercent,
            volume: api.volume,
            kind: old.kind,
            marketCap: old.marketCap,
            peRatio: old.peRatio,
            eps: old.eps,
            week52High: old.week52High,
            week52Low: old.week52Low,
            avgVolume: old.avgVolume,
            dividend: old.dividend,
            beta: old.beta
        )
    }
    
    // MARK: - News
    
    private func refreshNewsFromAPI() async {
        let symbols: [String]
        if !watchlist.isEmpty {
            symbols = Array(Set(watchlist.map { $0.symbol }))
        } else {
            symbols = Array(Set(stocks.map { $0.symbol }))
        }
        
        guard !symbols.isEmpty else { return }
        
        do {
            newsArticles = try await APIService.shared.fetchNews(for: symbols)
        } catch {
            print("Failed to fetch news: \(error)")
            // Keep whatever mock / previous news we had
        }
    }
    
    // MARK: - Price history fallback (local random walk)
    
    private func generatePriceHistoryFallback(for asset: Asset, range: TimeRange) -> [PricePoint] {
        let calendar = Calendar.current
        let now = Date()
        
        let (days, interval) = getTimeParameters(for: range)
        let basePrice = asset.price
        let volatility = asset.kind == .crypto ? 0.05 : 0.02
        
        var allPoints: [PricePoint] = []
        
        for i in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -days + i, to: now) else { continue }
            let randomChange = Double.random(in: -volatility...volatility)
            let price = basePrice * (1 + randomChange * Double(days - i) / Double(days))
            allPoints.append(PricePoint(date: date, price: price))
        }
        
        if interval <= 1 {
            return allPoints
        }
        
        return allPoints.enumerated()
            .filter { index, _ in index % interval == 0 }
            .map { $0.element }
    }
    
    private func getTimeParameters(for range: TimeRange) -> (days: Int, interval: Int) {
        switch range {
        case .oneDay: return (1, 1)
        case .oneWeek: return (7, 1)
        case .oneMonth: return (30, 1)
        case .threeMonths: return (90, 2)
        case .sixMonths: return (180, 3)
        case .ytd:
            let startOfYear = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date()))!
            let days = Calendar.current.dateComponents([.day], from: startOfYear, to: Date()).day ?? 0
            return (max(days, 1), max(1, days / 60))
        case .oneYear: return (365, 7)
        case .twoYears: return (730, 14)
        case .fiveYears: return (1825, 30)
        case .tenYears: return (3650, 60)
        case .all: return (5475, 90)
        }
    }
    
    // MARK: - Portfolio history (for portfolio chart)
    
    private func generatePortfolioHistory() {
        let calendar = Calendar.current
        let now = Date()
        let baseValue = portfolio.reduce(0.0) { $0 + $1.costBasis }
        
        guard baseValue > 0 else { return }
        
        for i in 0..<90 {
            let date = calendar.date(byAdding: .day, value: -90 + i, to: now)!
            let randomChange = Double.random(in: -0.02...0.03)
            let value = baseValue * (1 + randomChange * Double(i) / 90.0)
            portfolioHistory.append(PortfolioSnapshot(date: date, totalValue: value))
        }
    }
    
    // MARK: - Watchlist / portfolio management helpers
    
    func addToWatchlist(_ asset: Asset) {
        if !watchlist.contains(where: { $0.symbol == asset.symbol }) {
            watchlist.append(asset)
        }
    }
    
    func removeFromWatchlist(_ asset: Asset) {
        watchlist.removeAll { $0.symbol == asset.symbol }
    }
    
    func addToPortfolio(asset: Asset, shares: Double, avgCost: Double) {
        let holding = PortfolioHolding(asset: asset, shares: shares, avgCost: avgCost)
        portfolio.append(holding)
    }
    
    func removeFromPortfolio(_ holding: PortfolioHolding) {
        portfolio.removeAll { $0.id == holding.id }
    }
    
    func addCustomAsset(symbol: String, name: String, price: Double, kind: AssetKind) {
        let asset = Asset(symbol: symbol, name: name, price: price, change: 0, changePercent: 0, volume: 0, kind: kind)
        switch kind {
        case .stock:
            stocks.append(asset)
        case .crypto:
            crypto.append(asset)
        }
    }
}
