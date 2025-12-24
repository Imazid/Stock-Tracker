import Foundation
import Combine
import WidgetKit

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
    @Published var searchResults: [Asset] = []
    @Published var showAddSheet = false
    
    // MARK: - Aggregated portfolio metrics
    
    /// Current total market value of the portfolio
    var totalPortfolioValue: Double {
        portfolio.reduce(0) { $0 + $1.currentValue }
    }
    func refreshNews() async {
        // Replace with real API later
        try? await Task.sleep(nanoseconds: 800_000_000)
        // newsArticles = await NewsAPI.fetch()
    }
    // MARK: - Real-Time Search
    
    @Published var preferredCurrency: String = "USD"  // Default to USD
    @Published var usdToAudRate: Double = 1.505  // Fallback rate (1 USD ≈ 1.505 AUD as of Dec 2025)
    
    func updateExchangeRate() async {
        guard let url = URL(string: "https://api.exchangerate.host/latest?base=USD&symbols=AUD") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Double],
               let rate = rates["AUD"] {
                usdToAudRate = rate
            }
        } catch {
            print("Exchange rate fetch failed: \(error)")
        }
    }
    
    // Call this on app launch or daily
    func refreshExchangeRateIfNeeded() async {
        // Simple daily check using last update date (store in UserDefaults if needed)
        await updateExchangeRate()
    }
    // In MarketData.swift — replace your current searchAssets function with this:
    func searchAssets(query: String, kind: AssetKind) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        
        do {
            let results = try await APIService.shared.fetchSymbolSearch(query: query, kind: kind)
            
            let assets = try await withThrowingTaskGroup(of: Asset.self) { group in
                for result in results.prefix(10) {
                    group.addTask {
                        try await APIService.shared.fetchAssetDetails(
                            identifier: result.id,
                            kind: kind,
                            name: result.name
                        )
                    }
                }
                
                var collected: [Asset] = []
                for try await asset in group {
                    collected.append(asset)
                }
                return collected
            }
            
            self.searchResults = assets
        } catch {
            print("Search error: \(error)")
            self.searchResults = []
        }
    }
    
    /// Total cost basis (sum of shares * avgCost)
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
    
    /// “Today’s” absolute P/L based on last vs previous portfolioHistory point
    var dailyProfitLoss: Double {
        guard portfolioHistory.count >= 2 else { return 0 }
        let last = portfolioHistory[portfolioHistory.count - 1].totalValue
        let prev = portfolioHistory[portfolioHistory.count - 2].totalValue
        return last - prev
    }
    
    /// “Today’s” P/L percentage relative to previous value
    var dailyProfitLossPercent: Double {
        guard portfolioHistory.count >= 2 else { return 0 }
        let last = portfolioHistory[portfolioHistory.count - 1].totalValue
        let prev = portfolioHistory[portfolioHistory.count - 2].totalValue
        guard prev != 0 else { return 0 }
        return (last - prev) / prev * 100.0
    }
    
    // MARK: - Init
    
    init() {
        loadMockAssets()
        loadMockPortfolio()
        generatePortfolioHistory()
        loadMockNews()
        
        if portfolio.isEmpty {
                let mockAssets = MockMarketData.shared.mockStocks  // Use your updated mocks with current prices/exchanges
                
                let mockHoldings = mockAssets.map { asset in
                    PortfolioHolding(
                        asset: asset,
                        shares: 10.0,               // Example: 10 shares
                        avgCost: asset.price * 0.85 // Example: bought 15% cheaper for profit
                    )
                }
                
                portfolio = mockHoldings
            }
    }
    
    // MARK: - Price history
    
    /// Fetch price history from the API; if it fails, generate a local random-walk series.
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint] {
        do {
            return try await APIService.shared.fetchHistoricalData(symbol: asset.symbol, range: range)
        } catch {
            print("Failed to fetch price history for \(asset.symbol): \(error)")
            return generatePriceHistoryFallback(for: asset, range: range)
        }
    }
    
    
    
    /// Local synthetic history used as a fallback or for mock assets.
    func generatePriceHistoryFallback(for asset: Asset, range: TimeRange) -> [PricePoint] {
        let calendar = Calendar.current
        let now = Date()
        
        let numPoints: Int
        let component: Calendar.Component
        
        switch range {
        case .oneDay:
            numPoints = 24
            component = .hour
        case .oneWeek:
            numPoints = 7
            component = .day
        case .oneMonth:
            numPoints = 30
            component = .day
        case .threeMonths:
            numPoints = 13
            component = .weekOfYear
        case .sixMonths:
            numPoints = 26
            component = .weekOfYear
        case .ytd:
            numPoints = 12
            component = .month
        case .oneYear:
            numPoints = 12
            component = .month
        case .twoYears:
            numPoints = 24
            component = .month
        case .fiveYears:
            numPoints = 30
            component = .month
        case .tenYears:
            numPoints = 40
            component = .month
        case .all:
            numPoints = 60
            component = .month
        }
        
        let volatility = range.volatility
        
        var points: [PricePoint] = []
        var currentPrice = asset.price
        
        for i in 0..<numPoints {
            guard let date = calendar.date(byAdding: component, value: -i, to: now) else { continue }
            
            let randomChange = Double.random(in: (-volatility)...(volatility))
            let price = max(0.01, currentPrice * (1 + randomChange))
            
            points.append(PricePoint(date: date, price: price))
            currentPrice = price
        }
        
        return points.sorted { $0.date < $1.date }
    }
    
    /// Generates a synthetic time-series for the whole portfolio.
    private func generatePortfolioHistory() {
        portfolioHistory.removeAll()
        let calendar = Calendar.current
        let now = Date()
        
        let numPoints = 30
        var currentValue = max(totalPortfolioValue, 5000) // some baseline
        
        for i in 0..<numPoints {
            guard let date = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            
            let changePercent = Double.random(in: -0.03...0.03)
            currentValue = max(100, currentValue * (1 + changePercent))
            
            portfolioHistory.append(
                PortfolioSnapshot(date: date, totalValue: currentValue)
            )
        }
        
        portfolioHistory.sort { $0.date < $1.date }
    }
    
    // MARK: - Public API entry point
    
    func refreshFromAPI() async {
        await refreshAssetsFromAPI()
        await refreshNewsFromAPI()
        generatePortfolioHistory()
    }
    
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [Candle] {  // Changed return type
        let upper = symbol.uppercased()
        
        let (timeframe, multiplier): (String, Int) = {
            switch range {
            case .oneDay: return ("Minute", 1)  // Or 5 for 5-min bars in day trading
            case .oneWeek: return ("Hour", 1)
            default: return ("Day", 1)
            }
        }()
        
        // Existing URL setup...
        // Parse response bars into Candle
        let bars = try await APIService.shared.fetchBars(symbol: upper, timeframe: timeframe, multiplier: multiplier, range: range)
        return bars.map { bar in
            Candle(date: bar.date, open: bar.open, high: bar.high, low: bar.low, close: bar.close, volume: bar.volume)
        }
    }
    
    // MARK: - Quotes
    
    private func refreshAssetsFromAPI() async {
        // Update stocks using Alpaca
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
        
        // Propagate latest prices into portfolio and watchlist
        syncDerivedCollections()
    }
    
    /// Update portfolio holdings + watchlist to use latest `Asset` objects.
    private func syncDerivedCollections() {
        let allAssets = stocks + crypto
        let lookup = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.symbol, $0) })
        
        for index in portfolio.indices {
            let symbol = portfolio[index].asset.symbol
            if let updated = lookup[symbol] {
                portfolio[index].asset = updated
            }
        }
        
        for index in watchlist.indices {
            let symbol = watchlist[index].symbol
            if let updated = lookup[symbol] {
                watchlist[index] = updated
            }
        }
    }
    
    /// Keep old metadata but update live fields from API.
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
            beta: old.beta,
            exchange: "Binance"
        )
    }
    
    // MARK: - News
    
    private func refreshNewsFromAPI() async {
        do {
            let articles = try await APIService.shared.fetchNews()   // ← removed (for: symbols)
            self.newsArticles = articles
        } catch {
            print("Failed to fetch news: \(error)")
        }
    }
    
    // MARK: - Mock data
    
    private func loadMockAssets() {
        // Initial demo assets for UI
        stocks = [
            Asset(symbol: "AAPL", name: "Apple Inc.", price: 180.12, change: 1.24, changePercent: 0.69, volume: 55_000_000, kind: .stock, exchange: "NYSE"),
            Asset(symbol: "TSLA", name: "Tesla Inc.", price: 240.87, change: -2.45, changePercent: -1.01, volume: 38_000_000, kind: .stock, exchange: "NYSE"),
            Asset(symbol: "MSFT", name: "Microsoft Corporation", price: 350.54, change: 3.21, changePercent: 0.92, volume: 29_000_000, kind: .stock, exchange: "NYSE"),
            Asset(symbol: "NVDA", name: "NVIDIA Corporation", price: 480.90, change: 5.12, changePercent: 1.08, volume: 32_000_000, kind: .stock, exchange: "NYSE")
        ]
        
        crypto = [
            Asset(symbol: "BTC", name: "Bitcoin", price: 62_500, change: -1_200, changePercent: -1.88, volume: 18_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "ETH", name: "Ethereum", price: 3_200, change: 45, changePercent: 1.43, volume: 220_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "SOL", name: "Solana", price: 135, change: -3.4, changePercent: -2.45, volume: 1_800_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "ADA", name: "Cardano", price: 0.45, change: 0.01, changePercent: 2.3, volume: 75_000_000, kind: .crypto, exchange: "Binance")
        ]
    }
    
    private func loadMockPortfolio() {
        guard stocks.count >= 2, crypto.count >= 2 else { return }
        
        portfolio = [
            PortfolioHolding(asset: stocks[0], shares: 10,  avgCost: 170),
            PortfolioHolding(asset: stocks[1], shares: 8,   avgCost: 130),
            PortfolioHolding(asset: crypto[0], shares: 0.3, avgCost: 50_000),
            PortfolioHolding(asset: crypto[1], shares: 1.5, avgCost: 2_900)
        ]
        
        watchlist = Array(stocks.prefix(4)) + Array(crypto.prefix(2))
    }
    
    private func loadMockNews() {
        newsArticles = [
            NewsArticle(
                title: "Apple Announces New AI Features for iPhone",
                source: "Bloomberg",
                url: "https://example.com/aapl-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-3600),
                summary: "Apple unveils a suite of new AI-powered features for the upcoming iOS release.",
                relatedSymbols: ["AAPL"]
            ),
            NewsArticle(
                title: "Bitcoin Breaks Above $60K",
                source: "CoinDesk",
                url: "https://example.com/btc-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-7200),
                summary: "Bitcoin rallies past the $60,000 mark amid renewed institutional interest.",
                relatedSymbols: ["BTC"]
            ),
            NewsArticle(
                title: "Tesla Expands Production in Europe",
                source: "Reuters",
                url: "https://example.com/tsla-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-10_800),
                summary: "Tesla announces a new Gigafactory in Eastern Europe to boost production capacity.",
                relatedSymbols: ["TSLA"]
            )
        ]
    }
    
    // MARK: - Portfolio mutations
    
    func updateHolding(_ holding: PortfolioHolding, shares: Double, avgCost: Double) {
        guard let index = portfolio.firstIndex(where: { $0.id == holding.id }) else { return }
        portfolio[index].shares = shares
        
        portfolio[index].avgCost = avgCost
    }
    func addToPortfolio(asset: Asset, shares: Double, avgCost: Double) {
        let holding = PortfolioHolding(asset: asset, shares: shares, avgCost: avgCost)
        portfolio.append(holding)
    }
    
    func removeFromPortfolio(_ holding: PortfolioHolding) {
        portfolio.removeAll { $0.id == holding.id }
    }
    
    // MARK: - Watchlist mutations
    
    func removeFromWatchlist(_ asset: Asset) {
        watchlist.removeAll { $0.id == asset.id }
    }
    
    func addToWatchlist(_ asset: Asset) {
        if !watchlist.contains(where: { $0.symbol == asset.symbol }) {
            watchlist.append(asset)
            Task { await refreshFromAPI() }  // Update live prices
        }
    }
    
    func updateWidgetData() {
        let shared = UserDefaults(suiteName: "group.com.yourapp.stocktracker")!
        shared.set(totalPortfolioValue, forKey: "portfolioValue")
        shared.set(totalProfitLoss, forKey: "portfolioChange")
        shared.set(totalProfitLossPercent, forKey: "portfolioChangePercent")
        
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    // MARK: - Custom assets
    
    func addCustomAsset(symbol: String, name: String, price: Double, kind: AssetKind, exchange: String) {
        let asset = Asset(symbol: symbol, name: name, price: price, change: 0, changePercent: 0, volume: 0, kind: kind, exchange: exchange)
        switch kind {
        case .stock:
            stocks.append(asset)
        case .crypto:
            crypto.append(asset)
        }
    }
    
}
