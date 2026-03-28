import Foundation
import Combine
import OSLog
import WidgetKit

// MARK: - MarketData (coordinator)
//
// Owns all @Published state that views observe. Business logic is delegated to:
//   • QuoteService   — stock/crypto quotes, price history, S&P 500, exchange rates
//   • NewsService    — news fetching + pagination
//   • PortfolioService — persistence, history generation, mock data
//
// No view file needs to change: the public API surface is identical to before.

@MainActor
final class MarketData: ObservableObject {

    // MARK: - Published State

    @Published var stocks: [Asset] = []
    @Published var crypto: [Asset] = []
    @Published var portfolio: [PortfolioHolding] = []
    @Published var watchlist: [Asset] = []
    @Published var newsArticles: [NewsArticle] = []
    @Published var portfolioHistory: [PortfolioSnapshot] = []
    @Published var searchResults: [Asset] = []
    @Published var showAddSheet = false
    @Published var preferredCurrency: String = "USD"
    @Published var exchangeRates: [String: Double] = [
        "AUD": 1.505,
        "EUR": 0.922,
        "GBP": 0.792,
        "JPY": 149.50,
        "CAD": 1.362
    ]
    @Published var sp500Index: MarketIndex = MarketIndex(
        name: "S&P 500",
        symbol: "SPY",
        price: 4783.45,
        change: 0.0,
        changePercent: 0.0
    )
    @Published var sp500History: [PricePoint] = []
    @Published var marketSentiment: MarketSentiment = .bearish
    @Published var sentimentLastUpdated: Date = Date()
    /// Cached 1D mini-chart data keyed by symbol — persists across navigation so
    /// thumbnails never regenerate randomly when the user switches tabs and returns.
    var miniChartCache: [String: [PricePoint]] = [:]

    // News pagination state
    @Published var newsCurrentPage: Int = 1
    @Published var newsHasMore: Bool = true
    @Published var isFetchingNews: Bool = false
    @Published var lastQuoteRefreshDate: Date?
    @Published var isRefreshingQuotes: Bool = false
    @Published var portfolioGroups: [PortfolioGroup] = []
    @Published var activePortfolioIndex: Int = 0
    @Published var watchlistGroups: [WatchlistGroup] = []
    @Published var activeWatchlistIndex: Int = 0

    // MARK: - Domain Services (injectable for testing)

    private let quoteService: any QuoteServiceProtocol
    private let newsService: any NewsServiceProtocol
    private let portfolioService: any PortfolioServiceProtocol

    // MARK: - Constants

    static let supportedCurrencies = ["USD", "AUD", "EUR", "GBP", "JPY", "CAD"]

    // MARK: - Computed Portfolio Metrics

    var totalPortfolioValue: Double {
        portfolio.reduce(0) { $0 + $1.currentValue }
    }

    var totalCostBasis: Double {
        portfolio.reduce(0) { $0 + $1.costBasis }
    }

    var totalProfitLoss: Double {
        totalPortfolioValue - totalCostBasis
    }

    var totalProfitLossPercent: Double {
        guard totalCostBasis != 0 else { return 0 }
        return (totalProfitLoss / totalCostBasis) * 100.0
    }

    /// Real daily P&L — sum of (shares × asset.change) for every holding.
    /// `asset.change` is the dollar-per-share move fetched from the live API.
    var dailyProfitLoss: Double {
        portfolio.reduce(0) { $0 + $1.shares * $1.asset.change }
    }

    var dailyProfitLossPercent: Double {
        let prevCloseValue = totalPortfolioValue - dailyProfitLoss
        guard prevCloseValue > 0 else { return 0 }
        return (dailyProfitLoss / prevCloseValue) * 100.0
    }

    /// Backward-compat shim — prefer exchangeRates["AUD"] directly in new code.
    var usdToAudRate: Double { exchangeRates["AUD"] ?? 1.505 }

    // MARK: - Over-Limit Computed Properties

    var isOverWatchlistLimit: Bool {
        guard let limit = FeatureGate.maxWatchlistAssets(for: SubscriptionManager.shared.currentTier) else { return false }
        return watchlist.count > limit
    }

    var isOverPortfolioLimit: Bool {
        guard let limit = FeatureGate.maxPortfolioHoldings(for: SubscriptionManager.shared.currentTier) else { return false }
        return portfolio.count > limit
    }

    var activeWatchlistItems: [Asset] {
        guard let limit = FeatureGate.maxWatchlistAssets(for: SubscriptionManager.shared.currentTier) else { return watchlist }
        return Array(watchlist.prefix(limit))
    }

    var greyedOutWatchlistItems: [Asset] {
        guard let limit = FeatureGate.maxWatchlistAssets(for: SubscriptionManager.shared.currentTier) else { return [] }
        guard watchlist.count > limit else { return [] }
        return Array(watchlist.suffix(from: limit))
    }

    var activePortfolioHoldings: [PortfolioHolding] {
        guard let limit = FeatureGate.maxPortfolioHoldings(for: SubscriptionManager.shared.currentTier) else { return portfolio }
        return Array(portfolio.prefix(limit))
    }

    var greyedOutPortfolioHoldings: [PortfolioHolding] {
        guard let limit = FeatureGate.maxPortfolioHoldings(for: SubscriptionManager.shared.currentTier) else { return [] }
        guard portfolio.count > limit else { return [] }
        return Array(portfolio.suffix(from: limit))
    }

    // MARK: - Init

    init(
        quoteService: (any QuoteServiceProtocol)? = nil,
        newsService: (any NewsServiceProtocol)? = nil,
        portfolioService: (any PortfolioServiceProtocol)? = nil
    ) {
        // Create defaults inside the @MainActor body to satisfy Swift's actor isolation rules
        self.quoteService = quoteService ?? QuoteService()
        self.newsService = newsService ?? NewsService()
        self.portfolioService = portfolioService ?? PortfolioService()
        loadInitialData()
    }

    // MARK: - Startup

    private func loadInitialData() {
        let saved = portfolioService.load()
        preferredCurrency = saved.currency

        // Seed base asset lists (used for quote refreshes even when restoring from disk)
        let (mockStocks, mockCrypto) = portfolioService.mockAssets()

        if !saved.portfolio.isEmpty || !saved.watchlist.isEmpty {
            // Restore saved state
            watchlist = saved.watchlist
            portfolio = saved.portfolio
            if !saved.history.isEmpty { portfolioHistory = saved.history }
            stocks = mockStocks
            crypto = mockCrypto
        } else {
            // First launch — populate with mock data
            stocks = mockStocks
            crypto = mockCrypto
            let (mockPortfolio, mockWatchlist) = portfolioService.mockPortfolio(
                stocks: mockStocks,
                crypto: mockCrypto
            )
            portfolio = mockPortfolio
            watchlist = mockWatchlist
        }

        deduplicatePortfolio()

        // Ensure chart always has enough data points to render (need > 1)
        if portfolioHistory.count < 2 {
            portfolioHistory = portfolioService.seedInitialHistory(
                currentValue: totalPortfolioValue,
                costBasis: totalCostBasis
            )
        }

        // Ensure portfolio is never empty (edge-case guard)
        if portfolio.isEmpty {
            portfolio = stocks.map {
                PortfolioHolding(asset: $0, shares: 10, avgCost: $0.price * 0.85)
            }
        }

        newsArticles = newsService.mockArticles()

        // Initialize portfolio groups if empty
        if portfolioGroups.isEmpty {
            portfolioGroups = [PortfolioGroup(
                name: "Main Portfolio",
                emoji: "💼",
                holdings: portfolio,
                history: portfolioHistory
            )]
            activePortfolioIndex = 0
        }

        // Initialize watchlist groups
        let savedWatchlistGroups = portfolioService.loadWatchlistGroups()
        if savedWatchlistGroups.isEmpty {
            // First launch or migration: wrap existing watchlist into default group
            watchlistGroups = [WatchlistGroup(name: "My Watchlist", assets: watchlist)]
            activeWatchlistIndex = 0
        } else {
            watchlistGroups = savedWatchlistGroups
            let savedIndex = portfolioService.loadActiveWatchlistIndex()
            activeWatchlistIndex = min(savedIndex, watchlistGroups.count - 1)
            watchlist = watchlistGroups[activeWatchlistIndex].assets
        }

        // Refresh live prices and S&P 500 in the background immediately on launch
        Task { await fetchSP500History() }
        Task { await refreshFromAPI() }
        fetchMarketSentiment()

        // Start subscription-aware auto-refresh loop
        observeTierChanges()
        observeBlackTierIntervalChanges()
        scheduleAutoRefresh()
    }

    // MARK: - Public Refresh API

    func refreshFromAPI() async {
        await refreshAssetsFromAPI()
        await fetchSP500History()
        await refreshNewsFromAPI()
        portfolioHistory = portfolioService.appendCurrentSnapshot(
            to: portfolioHistory, currentValue: totalPortfolioValue
        )
        fetchMarketSentiment()
        saveToDisk()
        updateWidgetData()
        await LiveActivityManager.shared.updateAll(assets: stocks + crypto)
    }

    func refreshNews() async {
        await refreshNewsFromAPI()
    }

    // MARK: - Persistence

    func saveToDisk() {
        // Sync current holdings/history into the active portfolio group
        if portfolioGroups.indices.contains(activePortfolioIndex) {
            portfolioGroups[activePortfolioIndex].holdings = portfolio
            portfolioGroups[activePortfolioIndex].history = portfolioHistory
        }
        // Sync current watchlist into the active watchlist group
        if watchlistGroups.indices.contains(activeWatchlistIndex) {
            watchlistGroups[activeWatchlistIndex].assets = watchlist
        }
        portfolioService.save(
            watchlist: watchlist,
            portfolio: portfolio,
            history: portfolioHistory,
            currency: preferredCurrency,
            watchlistGroups: watchlistGroups,
            activeWatchlistIndex: activeWatchlistIndex
        )
    }

    // MARK: - Multi-Portfolio

    func switchToPortfolio(index: Int) {
        guard portfolioGroups.indices.contains(index) else { return }
        // Save current holdings/history back to active group
        if portfolioGroups.indices.contains(activePortfolioIndex) {
            portfolioGroups[activePortfolioIndex].holdings = portfolio
            portfolioGroups[activePortfolioIndex].history = portfolioHistory
        }
        activePortfolioIndex = index
        portfolio = portfolioGroups[index].holdings
        portfolioHistory = portfolioGroups[index].history
    }

    func createPortfolio(name: String, emoji: String = "💼") {
        // Save current holdings/history back to active group before switching
        if portfolioGroups.indices.contains(activePortfolioIndex) {
            portfolioGroups[activePortfolioIndex].holdings = portfolio
            portfolioGroups[activePortfolioIndex].history = portfolioHistory
        }
        let newGroup = PortfolioGroup(name: name, emoji: emoji, holdings: [], history: [])
        portfolioGroups.append(newGroup)
        activePortfolioIndex = portfolioGroups.count - 1
        portfolio = []
        portfolioHistory = []
    }

    func deletePortfolio(at index: Int) {
        guard portfolioGroups.count > 1 else { return }
        portfolioGroups.remove(at: index)
        let newIndex = min(activePortfolioIndex, portfolioGroups.count - 1)
        activePortfolioIndex = newIndex
        portfolio = portfolioGroups[newIndex].holdings
        portfolioHistory = portfolioGroups[newIndex].history
        saveToDisk()
    }

    func renamePortfolio(at index: Int, to name: String) {
        guard portfolioGroups.indices.contains(index) else { return }
        portfolioGroups[index].name = name
        saveToDisk()
    }

    // MARK: - Quotes

    private func refreshAssetsFromAPI() async {
        isRefreshingQuotes = true
        stocks = await quoteService.refreshStockQuotes(for: stocks)
        crypto = await quoteService.refreshCryptoPrices(for: crypto)
        let synced = quoteService.syncCollections(
            portfolio: portfolio,
            watchlist: watchlist,
            stocks: stocks,
            crypto: crypto
        )
        portfolio = synced.portfolio
        watchlist = synced.watchlist

        // Sync prices for all non-active watchlist groups
        let allAssets = stocks + crypto
        for i in watchlistGroups.indices where i != activeWatchlistIndex {
            watchlistGroups[i].assets = watchlistGroups[i].assets.map { asset in
                allAssets.first(where: { $0.symbol == asset.symbol }) ?? asset
            }
        }

        isRefreshingQuotes = false
        lastQuoteRefreshDate = Date()
    }

    // MARK: - Watchlist Group Management

    func switchToWatchlist(index: Int) {
        guard watchlistGroups.indices.contains(index) else { return }
        watchlistGroups[activeWatchlistIndex].assets = watchlist
        activeWatchlistIndex = index
        watchlist = watchlistGroups[index].assets
    }

    func createWatchlist(name: String) {
        if let limit = SubscriptionManager.shared.currentTier.watchlistLimit,
           watchlistGroups.count >= limit { return }
        watchlistGroups[activeWatchlistIndex].assets = watchlist
        let newGroup = WatchlistGroup(name: name)
        watchlistGroups.append(newGroup)
        activeWatchlistIndex = watchlistGroups.count - 1
        watchlist = []
        saveToDisk()
    }

    func deleteWatchlist(at index: Int) {
        guard watchlistGroups.count > 1 else { return }
        watchlistGroups.remove(at: index)
        let newIndex = min(activeWatchlistIndex, watchlistGroups.count - 1)
        activeWatchlistIndex = newIndex
        watchlist = watchlistGroups[newIndex].assets
        saveToDisk()
    }

    func renameWatchlist(at index: Int, to name: String) {
        guard watchlistGroups.indices.contains(index) else { return }
        watchlistGroups[index].name = name
        saveToDisk()
    }

    // MARK: - Exchange Rates

    func updateExchangeRate() async {
        let currencies = MarketData.supportedCurrencies.filter { $0 != "USD" }
        let rates = await quoteService.fetchExchangeRates(for: currencies)
        for (code, rate) in rates {
            exchangeRates[code] = rate
        }
    }

    func refreshExchangeRateIfNeeded() async {
        await updateExchangeRate()
    }

    func formatPrice(_ value: Double) -> String {
        value.formattedPrice(in: preferredCurrency, rates: exchangeRates)
    }

    // MARK: - S&P 500

    func fetchSP500History() async {
        sp500History = await quoteService.fetchSP500History()
    }

    // MARK: - Dividend Backfill

    /// Updates `Asset.dividend` (yield %) for a symbol across stocks, portfolio, and watchlist.
    /// Called after FMP enrichment so PortfolioIntelligenceView's DividendsSection has data.
    func updateAssetDividend(symbol: String, yieldPercent: Double) {
        for i in stocks.indices where stocks[i].symbol == symbol {
            stocks[i].dividend = yieldPercent
        }
        for i in portfolio.indices where portfolio[i].asset.symbol == symbol {
            portfolio[i].asset.dividend = yieldPercent
        }
        for i in watchlist.indices where watchlist[i].symbol == symbol {
            watchlist[i].dividend = yieldPercent
        }
    }

    // MARK: - Price History

    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint] {
        await quoteService.fetchPriceHistory(for: asset, range: range)
    }

    /// Fetch 1D price history for a watchlist thumbnail.
    /// Returns the cached result immediately on repeat calls so thumbnails
    /// show stable data when the user navigates away and returns.
    func fetchMiniChartHistory(for asset: Asset) async -> [PricePoint] {
        if let cached = miniChartCache[asset.symbol], !cached.isEmpty {
            return cached
        }
        let points = await quoteService.fetchPriceHistory(for: asset, range: .oneDay)
        if !points.isEmpty {
            miniChartCache[asset.symbol] = points
        }
        return points
    }

    func generatePriceHistoryFallback(for asset: Asset, range: TimeRange) -> [PricePoint] {
        quoteService.generatePriceHistoryFallback(for: asset, range: range)
    }

    func fetchHistoricalData(for asset: Asset, range: TimeRange) async throws -> [Candle] {
        try await quoteService.fetchHistoricalData(for: asset, range: range)
    }

    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [Candle] {
        try await quoteService.fetchHistoricalData(symbol: symbol, range: range)
    }

    // MARK: - News

    func refreshNewsFromAPI() async {
        guard !isFetchingNews else { return }
        isFetchingNews = true
        defer { isFetchingNews = false }
        do {
            let articles = try await newsService.fetchPage(1)
            newsArticles = articles
            newsCurrentPage = 1
            newsHasMore = articles.count >= Constants.Pagination.newsPageSize
        } catch {
            AppLogger.news.error("News fetch failed: \(error)")
            // Keep existing articles (mock or previously fetched) on failure.
            // 426 means the plan requires a server-side proxy for device requests.
            if newsArticles.isEmpty {
                newsArticles = newsService.mockArticles()
            }
            newsHasMore = false
        }
    }

    func fetchNextNewsPage() async {
        guard newsHasMore, !isFetchingNews else { return }
        isFetchingNews = true
        defer { isFetchingNews = false }
        let nextPage = newsCurrentPage + 1
        do {
            let articles = try await newsService.fetchPage(nextPage)
            if articles.isEmpty {
                newsHasMore = false
            } else {
                newsArticles.append(contentsOf: articles)
                newsCurrentPage = nextPage
                newsHasMore = articles.count >= Constants.Pagination.newsPageSize
            }
        } catch {
            AppLogger.news.error("News page \(nextPage) fetch failed: \(error)")
        }
    }

    // MARK: - Stale Check (tab-switch refresh)

    /// Refreshes only if data is stale (>30s since last quote refresh or never refreshed).
    func refreshIfStale() {
        guard let last = lastQuoteRefreshDate else {
            Task { await refreshFromAPI() }
            return
        }
        if Date().timeIntervalSince(last) > 30 {
            Task { await refreshFromAPI() }
        }
    }

    // MARK: - Auto-Refresh

    /// Recurring background task that fires quote refreshes on a subscription-tier interval.
    private var autoRefreshTask: Task<Void, Never>?
    private var tierObserver: AnyCancellable?
    private var intervalObserver: AnyCancellable?

    /// Starts (or restarts) the auto-refresh loop based on the current subscription tier.
    /// Free tier = no timer (manual only). Pro = 60 s. Black = user-configurable (default 30 s).
    func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard let interval = SubscriptionManager.shared.currentTier.autoRefreshInterval else {
            AppLogger.refresh.debug("Auto-refresh disabled (free tier)")
            return
        }

        AppLogger.refresh.debug("Auto-refresh scheduled every \(Int(interval))s")
        autoRefreshTask = Task(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await refreshFromAPI()
            }
        }
    }

    /// Observes subscription tier changes and reschedules the auto-refresh loop.
    private func observeTierChanges() {
        tierObserver = SubscriptionManager.shared.$currentTier
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleAutoRefresh() }
    }

    /// Observes Black tier refresh interval changes from Settings and reschedules.
    func observeBlackTierIntervalChanges() {
        intervalObserver = NotificationCenter.default.publisher(for: .blackTierRefreshIntervalChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleAutoRefresh() }
    }

    // MARK: - Search (debounced)

    private var searchTask: Task<Void, Never>?

    func searchAssets(query: String, kind: AssetKind) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(Constants.Network.searchDebouncems))
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmed, kind: kind)
        }
    }

    private func performSearch(query: String, kind: AssetKind) async {
        do {
            let results = try await APIService.shared.fetchSymbolSearch(query: query, kind: kind)
            let assets = await withTaskGroup(of: Asset?.self) { group in
                for result in results.prefix(Constants.Network.searchDetailPrefetch) {
                    group.addTask {
                        try? await APIService.shared.fetchAssetDetails(
                            identifier: result.id,
                            kind: kind,
                            name: result.name,
                            exchange: result.exchange
                        )
                    }
                }
                var collected: [Asset] = []
                for await asset in group { if let asset { collected.append(asset) } }
                return collected
            }
            guard !Task.isCancelled else { return }
            searchResults = assets
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.search.error("Search error: \(error)")
            searchResults = []
        }
    }

    // MARK: - Portfolio Deduplication

    private func deduplicatePortfolio() {
        let grouped = Dictionary(grouping: portfolio, by: { $0.asset.symbol })
        var hasDuplicates = false

        for holdings in grouped.values where holdings.count > 1 {
            hasDuplicates = true
            break
        }
        guard hasDuplicates else { return }

        var merged: [PortfolioHolding] = []
        var removedIDs: [UUID] = []

        for (_, holdings) in grouped {
            if holdings.count == 1 {
                merged.append(holdings[0])
                continue
            }

            var totalShares: Double = 0
            var totalCost: Double = 0
            var allTransactions: [Transaction] = []
            var bestAsset = holdings[0].asset
            let earliestDate = holdings.compactMap({ $0.dateAdded as Date? }).min() ?? Date()

            for h in holdings {
                totalShares += h.shares
                totalCost += h.shares * h.avgCost

                if h.transactions.isEmpty {
                    allTransactions.append(Transaction(
                        date: h.dateAdded,
                        shares: h.shares,
                        pricePerShare: h.avgCost,
                        type: .buy
                    ))
                } else {
                    allTransactions.append(contentsOf: h.transactions)
                }

                if h.asset.price > bestAsset.price { bestAsset = h.asset }
            }

            let avgCost = totalShares > 0 ? totalCost / totalShares : 0
            let keepID = holdings[0].id
            merged.append(PortfolioHolding(
                id: keepID,
                asset: bestAsset,
                shares: totalShares,
                avgCost: avgCost,
                dateAdded: earliestDate,
                transactions: allTransactions.sorted(by: { $0.date < $1.date })
            ))

            // Track removed IDs for sync cleanup
            for h in holdings.dropFirst() {
                removedIDs.append(h.id)
            }
        }

        portfolio = merged
        saveToDisk()
        AppLogger.portfolio.info("Deduplicated portfolio: merged to \(self.portfolio.count) holdings")

        // Soft-delete removed holdings from Supabase
        if SyncManager.shared.isSignedIn && !removedIDs.isEmpty {
            Task {
                for id in removedIDs {
                    await SyncManager.shared.softDeleteHolding(id: id)
                }
            }
        }
    }

    // MARK: - Portfolio Mutations

    func addToPortfolio(asset: Asset, shares: Double, avgCost: Double) {
        let transaction = Transaction(
            date: Date(),
            shares: shares,
            pricePerShare: avgCost,
            type: .buy
        )

        if let index = portfolio.firstIndex(where: { $0.asset.symbol == asset.symbol }) {
            // Merge into existing holding with weighted average cost
            let existing = portfolio[index]
            let totalCost = (existing.shares * existing.avgCost) + (shares * avgCost)
            let totalShares = existing.shares + shares
            portfolio[index].shares = totalShares
            portfolio[index].avgCost = totalShares > 0 ? totalCost / totalShares : 0
            portfolio[index].asset = asset
            portfolio[index].transactions.append(transaction)
        } else {
            // New holding with initial transaction
            portfolio.append(PortfolioHolding(
                asset: asset,
                shares: shares,
                avgCost: avgCost,
                transactions: [transaction]
            ))
        }

        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    func removeFromPortfolio(_ holding: PortfolioHolding) {
        portfolio.removeAll { $0.id == holding.id }
        // Record the new (lower) total so the chart reflects the deletion
        portfolioHistory = portfolioService.appendCurrentSnapshot(
            to: portfolioHistory, currentValue: totalPortfolioValue
        )
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn {
            Task { await SyncManager.shared.softDeleteHolding(id: holding.id) }
        }
    }

    func updateHolding(_ holding: PortfolioHolding, shares: Double, avgCost: Double) {
        guard let index = portfolio.firstIndex(where: { $0.id == holding.id }) else { return }
        portfolio[index].shares = shares
        portfolio[index].avgCost = avgCost
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    // MARK: - Watchlist Mutations

    func addToWatchlist(_ asset: Asset) {
        guard !watchlist.contains(where: { $0.symbol == asset.symbol }) else { return }
        watchlist.append(asset)
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
        Task { await refreshFromAPI() }
    }

    func removeFromWatchlist(_ asset: Asset) {
        watchlist.removeAll { $0.id == asset.id }
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    func removeMultipleFromWatchlist(_ ids: Set<UUID>) {
        watchlist.removeAll { ids.contains($0.id) }
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    func moveWatchlistItem(from source: IndexSet, to destination: Int) {
        // Manual move since we don't import SwiftUI in this file
        let moving = source.sorted().reversed().map { watchlist.remove(at: $0) }.reversed()
        let insertAt = min(destination, watchlist.count)
        watchlist.insert(contentsOf: moving, at: insertAt)
        saveToDisk()
    }

    // MARK: - Market Sentiment

    /// Fetches (or simulates) the current market sentiment.
    /// Call once on launch and whenever a full refresh occurs.
    ///
    /// Derives market sentiment from real S&P 500 daily change and portfolio performance.
    func fetchMarketSentiment() {
        let spChange = sp500Index.changePercent

        // Blend portfolio momentum if we have holdings
        let portfolioChange = totalProfitLossPercent
        let hasPortfolio = !portfolio.isEmpty
        // Weight: 70% S&P 500 + 30% portfolio (if available)
        let blended = hasPortfolio ? (spChange * 0.7 + portfolioChange * 0.3) : spChange

        let newSentiment: MarketSentiment
        switch blended {
        case _ where blended <= -2.0: newSentiment = .veryBearish
        case _ where blended <= -0.5: newSentiment = .bearish
        case _ where blended <   0.5: newSentiment = .neutral
        case _ where blended <   2.0: newSentiment = .bullish
        default:                      newSentiment = .veryBullish
        }

        self.marketSentiment      = newSentiment
        self.sentimentLastUpdated = Date()
    }

    // MARK: - Remote sync apply (called by SyncManager after pull/merge)

    func applyRemoteSync(watchlist remoteWatchlist: [Asset], portfolio remotePortfolio: [PortfolioHolding], history remoteHistory: [PortfolioSnapshot]) {
        // Preserve live market data for assets already known locally
        // Use init(_:uniquingKeysWith:) to avoid fatal error on duplicate symbols
        let localAssets = Dictionary((watchlist + stocks + crypto).map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        watchlist = remoteWatchlist.map { asset in
            guard let live = localAssets[asset.symbol], live.price > 0 else { return asset }
            var a = asset
            a.price = live.price
            a.change = live.change
            a.changePercent = live.changePercent
            return a
        }
        // Preserve live market data for portfolio assets
        portfolio = remotePortfolio.map { holding in
            guard let live = localAssets[holding.asset.symbol], live.price > 0 else { return holding }
            var h = holding
            h.asset.price = live.price
            h.asset.change = live.change
            h.asset.changePercent = live.changePercent
            return h
        }
        if !remoteHistory.isEmpty { portfolioHistory = remoteHistory }
        saveToDisk()
        updateWidgetData()
    }

    // MARK: - Custom Assets

    func addCustomAsset(symbol: String, name: String, price: Double, kind: AssetKind, exchange: String) {
        let asset = Asset(
            symbol: symbol,
            name: name,
            price: price,
            change: 0,
            changePercent: 0,
            volume: 0,
            kind: kind,
            exchange: exchange
        )
        switch kind {
        case .stock: stocks.append(asset)
        case .crypto: crypto.append(asset)
        }
    }

    // MARK: - Widget

    func updateWidgetData() {
        guard let shared = UserDefaults(suiteName: Constants.Widget.appGroup) else { return }

        // Legacy keys (kept for backward compat with old widget builds)
        shared.set(totalPortfolioValue,      forKey: "portfolioValue")
        shared.set(totalProfitLoss,          forKey: "portfolioChange")
        shared.set(totalProfitLossPercent,   forKey: "portfolioChangePercent")

        // --- Portfolio data (extended with sparkline) ---
        let topHoldings = portfolio.sorted { $0.currentValue > $1.currentValue }.prefix(5)
        let widgetHoldings = topHoldings.map { h in
            [
                "id": h.id.uuidString,
                "symbol": h.asset.symbol,
                "name": h.asset.name,
                "price": h.asset.price,
                "changePercent": h.asset.changePercent,
                "value": h.currentValue,
                "profitLossPercent": h.profitLossPercent
            ] as [String: Any]
        }
        // Sparkline: last 20 portfolio history points (or current value repeated if insufficient).
        let historyValues: [Double] = {
            let pts = portfolioHistory.suffix(20).map(\.totalValue)
            guard pts.count >= 2 else {
                // Synthesise a flat baseline so the chart always renders.
                return Array(repeating: totalPortfolioValue, count: 20)
            }
            return Array(pts)
        }()
        let portfolioDict: [String: Any] = [
            "totalValue": totalPortfolioValue,
            "totalChange": totalProfitLoss,
            "totalChangePercent": totalProfitLossPercent,
            "dailyChange": dailyProfitLoss,
            "dailyChangePercent": dailyProfitLossPercent,
            "holdings": widgetHoldings,
            "sparklinePoints": historyValues
        ]
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(portfolioDict)) {
            shared.set(data, forKey: "portfolioData")
        }

        // --- Watchlist data (top 8 by absolute change%) + per-asset sparkline ---
        let topWatchlist = watchlist.sorted { abs($0.changePercent) > abs($1.changePercent) }.prefix(8)
        let watchlistItems = topWatchlist.map { a -> [String: Any] in
            var dict: [String: Any] = [
                "id": a.id.uuidString, "symbol": a.symbol, "name": a.name,
                "price": a.price, "change": a.change, "changePercent": a.changePercent
            ]
            // Per-asset sparkline: last 12 points from miniChartCache
            if let cached = miniChartCache[a.symbol], cached.count >= 2 {
                dict["sparklinePoints"] = Array(cached.suffix(12).map(\.price))
            }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(["items": watchlistItems])) {
            shared.set(data, forKey: "watchlistData")
        }

        // --- Market data — SPY as S&P 500 proxy ---
        let isOpen = isMarketCurrentlyOpen()
        let indexAsset: [String: Any] = [
            "id": sp500Index.id.uuidString,
            "symbol": sp500Index.symbol,
            "name": sp500Index.name,
            "price": sp500Index.price,
            "change": sp500Index.change,
            "changePercent": sp500Index.changePercent
        ]
        let marketDict: [String: Any] = ["isMarketOpen": isOpen, "indices": [indexAsset]]
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(marketDict)) {
            shared.set(data, forKey: "marketData")
        }

        // --- Alerts data ---
        let savedAlerts = DataPersistenceManager.shared.loadPriceAlerts()
        let alertDicts: [[String: Any]] = savedAlerts.filter { $0.isActive }.map { alert in
            let currentPrice = watchlist.first(where: { $0.symbol == alert.symbol })?.price
                ?? portfolio.first(where: { $0.asset.symbol == alert.symbol })?.asset.price
                ?? 0
            return [
                "id": alert.id.uuidString,
                "symbol": alert.symbol,
                "targetPrice": alert.targetPrice,
                "currentPrice": currentPrice,
                "condition": alert.condition.rawValue.lowercased()
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(["alerts": alertDicts])) {
            shared.set(data, forKey: "alertsData")
        }

        // --- Sentiment data ---
        // Derived from the existing marketSentiment property (set by QuoteService after S&P 500 refresh).
        // Mapping is modular: swap this helper to plug in a Fear & Greed index API later.
        let (sentimentKey, sentimentLabel, sentimentSymbol) = widgetSentimentComponents(from: marketSentiment)
        let sentimentDict: [String: Any] = [
            "sentiment": sentimentKey,
            "changePercent": sp500Index.changePercent,
            "label": sentimentLabel,
            "sfSymbol": sentimentSymbol
        ]
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(sentimentDict)) {
            shared.set(data, forKey: "sentimentData")
        }

        // --- Top performer ---
        if let top = portfolio.max(by: { $0.asset.changePercent < $1.asset.changePercent }) {
            // Attempt to pull cached mini chart for this symbol; fall back to synthetic walk.
            let sparkPts: [Double] = {
                if let cached = miniChartCache[top.asset.symbol], cached.count >= 2 {
                    return Array(cached.suffix(8).map(\.price))
                }
                // Synthetic 8-point walk from avgCost → current price.
                let start = max(top.avgCost, 0.01)
                let end = top.asset.price
                return (0..<8).map { i in
                    start + (end - start) * (Double(i) / 7.0) + Double.random(in: -start * 0.005...start * 0.005)
                }
            }()
            let topDict: [String: Any] = [
                "symbol": top.asset.symbol,
                "name": top.asset.name,
                "changePercent": top.asset.changePercent,
                "currentValue": top.currentValue,
                "price": top.asset.price,
                "sparklinePoints": sparkPts
            ]
            if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(topDict)) {
                shared.set(data, forKey: "topPerformerData")
            }
        }

        // --- Premium data (Pro / Black tier features) ---
        let tier = SubscriptionManager.shared.currentTier.rawValue
        // Allocation slices (top 4 holdings + "Other" bucket).
        let totalVal = max(totalPortfolioValue, 1)
        let sortedHoldings = portfolio.sorted { $0.currentValue > $1.currentValue }
        var slices: [[String: Any]] = sortedHoldings.prefix(4).map { h in
            let pct = (h.currentValue / totalVal) * 100
            let (r, g, b) = widgetColor(for: h.asset.symbol)
            return ["symbol": h.asset.symbol, "name": h.asset.name,
                    "percent": pct, "colorR": r, "colorG": g, "colorB": b]
        }
        if sortedHoldings.count > 4 {
            let otherPct = sortedHoldings.dropFirst(4).reduce(0) { $0 + ($1.currentValue / totalVal) * 100 }
            slices.append(["symbol": "Other", "name": "Other",
                           "percent": otherPct, "colorR": 0.5, "colorG": 0.5, "colorB": 0.5])
        }
        // Risk score: simple concentration-weighted metric (placeholder; replace with beta model later).
        let riskScore = widgetRiskScore(holdings: Array(sortedHoldings.prefix(5)), totalValue: totalVal)
        // Weekly values (last 7 portfolio snapshots).
        let weeklyVals = portfolioHistory.suffix(7).map(\.totalValue)
        let weeklyChangePct: Double = {
            guard let first = weeklyVals.first, first > 0, let last = weeklyVals.last else { return 0 }
            return ((last - first) / first) * 100
        }()
        let premiumDict: [String: Any] = [
            "tier": tier,
            "allocationSlices": slices,
            "riskScore": riskScore,
            "weeklyChangePercent": weeklyChangePct,
            "weeklyValues": Array(weeklyVals)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(premiumDict)) {
            shared.set(data, forKey: "premiumData")
        }

        // --- News data (top 5 articles for widget) ---
        let isoFormatter = ISO8601DateFormatter()
        let newsArticleDicts: [[String: Any]] = newsArticles.prefix(5).enumerated().map { i, article in
            var dict: [String: Any] = [
                "id": "\(i)",
                "title": article.title,
                "source": article.source,
                "publishedAt": isoFormatter.string(from: article.publishedAt)
            ]
            if let first = article.relatedSymbols.first {
                dict["relatedSymbol"] = first
            }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(["articles": newsArticleDicts])) {
            shared.set(data, forKey: "newsData")
        }

        // --- Calendar data (placeholder — populated when earnings API is available) ---
        // Events are written here when upcomingEarnings is populated via FMPService.
        // For now, write an empty array so the widget shows "No Events" gracefully.
        if let calData = shared.data(forKey: "calendarData"), !calData.isEmpty {
            // Keep existing calendar data if present
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: sanitizedForJSON(["events": [] as [[String: Any]]])) {
                shared.set(data, forKey: "calendarData")
            }
        }

        // Timestamp
        shared.set(isoFormatter.string(from: Date()), forKey: "lastUpdated")

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Maps the app's 5-level MarketSentiment enum to a 3-bucket widget representation.
    private func widgetSentimentComponents(from sentiment: MarketSentiment) -> (key: String, label: String, symbol: String) {
        switch sentiment {
        case .veryBullish, .bullish:
            return ("bullish", "Bullish Sentiment", "chart.line.uptrend.xyaxis")
        case .neutral:
            return ("neutral", "Neutral Sentiment", "minus.circle")
        case .bearish, .veryBearish:
            return ("bearish", "Bearish Sentiment", "chart.line.downtrend.xyaxis")
        }
    }

    /// Deterministic colour per symbol so widget allocation slices are visually stable.
    private func widgetColor(for symbol: String) -> (Double, Double, Double) {
        let palette: [(Double, Double, Double)] = [
            (0.4, 0.6, 1.0),   // blue
            (0.6, 0.3, 0.9),   // purple
            (0.2, 0.8, 0.4),   // green
            (0.9, 0.6, 0.1),   // orange
            (0.9, 0.3, 0.4)    // red
        ]
        let idx = abs(symbol.hashValue) % palette.count
        return palette[idx]
    }

    /// Placeholder risk score: higher concentration in fewer assets = higher risk.
    private func widgetRiskScore(holdings: [PortfolioHolding], totalValue: Double) -> Double {
        guard holdings.count > 1 else { return holdings.isEmpty ? 0 : 100 }
        // Herfindahl–Hirschman Index normalised to 0–100.
        let weights = holdings.map { $0.currentValue / totalValue }
        let hhi = weights.reduce(0) { $0 + $1 * $1 }   // 1/n (equal weight) → 1.0 (all in one)
        let n = Double(holdings.count)
        let hhiMin = 1.0 / n
        let denom = 1.0 - hhiMin
        guard denom > 0 else { return 100 }
        let score = (hhi - hhiMin) / denom * 100
        return min(max(score, 0), 100)
    }

    /// Recursively replaces NaN/Inf with 0 in dictionaries and arrays before JSON serialization.
    private func sanitizedForJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { sanitizedForJSON($0) }
        } else if let array = value as? [Any] {
            return array.map { sanitizedForJSON($0) }
        } else if let d = value as? Double, d.isNaN || d.isInfinite {
            return 0.0
        } else {
            return value
        }
    }

    private func isMarketCurrentlyOpen() -> Bool {
        // NYSE hours: Mon–Fri 09:30–16:00 ET
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        guard weekday >= 2, weekday <= 6 else { return false }  // Mon=2 … Fri=6
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let minutes = hour * 60 + minute
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
    }
}
