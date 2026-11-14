import Foundation
import Combine
import OSLog
import WidgetKit

// MARK: - MarketData (coordinator)
//
// Owns all @Published state that views observe. Business logic is delegated to:
//   • QuoteService   — stock/crypto quotes, price history, S&P 500, exchange rates
//   • NewsService    — news fetching + pagination
//   • PortfolioService — persistence, history generation, starter assets
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
    @Published var showAddSheet = false
    @Published var preferredCurrency: String = "USD"
    @Published var exchangeRates: [String: Double] = [
        "AUD": 1.505,
        "EUR": 0.922,
        "GBP": 0.792,
        "JPY": 149.50,
        "CAD": 1.362
    ] {
        // Mirror for the network layer, which converts non-USD quotes on the way in.
        didSet { FXRates.shared.update(exchangeRates) }
    }
    @Published private(set) var verifiedFXRates: [String: Double] = ["USD": 1]
    /// Live S&P 500 level (^GSPC). Zero until the first refresh — never a placeholder level.
    @Published var sp500Index: MarketIndex = MarketIndex(
        name: "S&P 500",
        symbol: "^GSPC",
        price: 0,
        change: 0,
        changePercent: 0
    )
    @Published var sp500History: [PricePoint] = []
    @Published var marketSentiment: MarketSentiment = .bearish
    @Published var sentimentLastUpdated: Date = Date()
    /// Cached 1D mini-chart data keyed by symbol — persists across navigation so
    /// thumbnails never regenerate randomly when the user switches tabs and returns.
    var miniChartCache: [String: [PricePoint]] = [:]
    /// Real portfolio series for widgets (rebuilt from price history; empty = widget shows "no chart yet").
    private var widgetDaySeries: [Double] = []
    private var widgetWeekDaily: [Double] = []

    // News pagination state
    @Published var newsCurrentPage: Int = 1
    @Published var newsHasMore: Bool = true
    @Published var isFetchingNews: Bool = false
    @Published var lastQuoteRefreshDate: Date?
    @Published var isRefreshingQuotes: Bool = false
    @Published var portfolioGroups: [PortfolioGroup] = []
    @Published var activePortfolioIndex: Int = 0

    var allTrackedHoldings: [PortfolioHolding] {
        portfolio + portfolioGroups.enumerated().flatMap { index, group in
            index == activePortfolioIndex ? [] : group.holdings
        }
    }

    @Published var watchlistGroups: [WatchlistGroup] = []
    @Published var activeWatchlistIndex: Int = 0

    // MARK: - Price Direction Tracking

    /// Not @Published: no view reads it, and publishing it set-then-cleared re-rendered
    /// every MarketData observer twice per refresh.
    var priceDirections: [String: PriceDirection] = [:]
    /// Listings whose latest quote failed — UI shows "No live price" instead of a stale number.
    @Published private var quoteFailures: Set<String> = []
    private var previousPrices: [String: Double] = [:]

    func quoteFailed(for asset: Asset) -> Bool { quoteFailures.contains(asset.quoteIdentity) }

    // MARK: - External Managers (wired by Stock_TrackerApp)

    var alertManager: PriceAlertManager? {
        didSet {
            // The launch refresh starts in init and can finish before the app wires
            // this up in onAppear — free plans have no auto-refresh, so those fresh
            // prices would otherwise never be checked against alerts this session.
            if hasFreshQuotes, let alertManager, oldValue !== alertManager, !Self.backgroundChecksOnly {
                alertManager.checkAlerts(for: watchlist + portfolio.map(\.asset) + alertOnlyAssets)
            }
        }
    }
    /// Set once a refresh has finished this session (prices aren't just last session's).
    private var hasFreshQuotes = false
    /// Live quotes for alert symbols that aren't on the watchlist or in the portfolio
    /// (alerts set from Search or a stock page). Without these, such alerts never fired.
    @Published private(set) var alertOnlyAssets: [Asset] = []

    #if DEBUG
    /// UI tests: `-UITestBackgroundOnly` turns off in-app alert checks so a test proves
    /// the background-refresh path (`BackgroundRefresh.run`) fires alerts on its own.
    static let backgroundChecksOnly = ProcessInfo.processInfo.arguments.contains("-UITestBackgroundOnly")
    #else
    static let backgroundChecksOnly = false
    #endif
    var notificationScheduler: NotificationScheduler?

    // MARK: - Domain Services (injectable for testing)

    private let quoteService: any QuoteServiceProtocol
    private let newsService: any NewsServiceProtocol
    private let portfolioService: any PortfolioServiceProtocol

    // MARK: - Constants

    static let supportedCurrencies = ["USD", "AUD", "EUR", "GBP", "JPY", "CAD"]
    /// Every currency a followed listing can be quoted in, so Yahoo prices convert to USD
    /// correctly (London, Zurich, Hong Kong, Singapore, Seoul and Mumbai included).
    static let quoteCurrencies = ["AUD", "EUR", "GBP", "JPY", "CAD", "CHF", "HKD", "SGD", "KRW", "INR", "NZD"]

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

    /// Holdings in the active portfolio that were sold down to zero.
    var closedPositions: [ClosedPosition] {
        portfolioGroups.indices.contains(activePortfolioIndex) ? portfolioGroups[activePortfolioIndex].closedPositions : []
    }

    /// Profit banked from sales (USD): open holdings' partial sales + closed positions.
    var totalRealizedGain: Double {
        portfolio.reduce(0) { $0 + $1.realizedGain } + closedPositions.reduce(0) { $0 + $1.realizedGain }
    }

    /// Unrealised (holdings with a known cost) + realised, USD.
    var totalReturn: Double {
        let priced = portfolio.filter { $0.costBasis > 0 }
        return priced.reduce(0) { $0 + $1.profitLoss } + totalRealizedGain
    }

    /// Everything paid for what's held (with a known cost) plus what was sold, USD.
    var totalInvestedAllTime: Double {
        portfolio.filter { $0.costBasis > 0 }.reduce(0) { $0 + $1.costBasis }
            + portfolio.reduce(0) { $0 + $1.ledger.costOfSold }
            + closedPositions.reduce(0) { $0 + $1.ledger.costOfSold }
    }

    var totalReturnPercent: Double {
        let base = totalInvestedAllTime
        return base > 0 ? totalReturn / base * 100 : 0
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
        FXRates.shared.update(exchangeRates)
        let saved = portfolioService.load()
        preferredCurrency = saved.currency

        // Seed base asset lists (used for quote refreshes even when restoring from disk)
        (stocks, crypto) = portfolioService.starterAssets()

        if !saved.portfolio.isEmpty || !saved.watchlist.isEmpty {
            // Restore saved state
            watchlist = saved.watchlist
            portfolio = saved.portfolio
            if !saved.history.isEmpty { portfolioHistory = saved.history }
        } else {
            // First launch — start empty. A finance app must never show someone
            // holdings they don't own; onboarding fills the watchlist with their
            // picks and the portfolio with what they add or connect.
            portfolio = []
            watchlist = []
        }

        mergeTrackedAssetsIntoCanonicalCollections()

        migrateASXValuesToUSDIfNeeded()

        // No seeded history and no placeholder headlines: charts are rebuilt from
        // real prices (PriceHistoryService) and News shows a loading state until
        // real articles arrive.
        newsArticles = []

        // Restore every portfolio (only the active one used to survive a relaunch).
        let savedGroups = DataPersistenceManager.shared.loadPortfolioGroups()
        if !savedGroups.groups.isEmpty {
            portfolioGroups = savedGroups.groups
            activePortfolioIndex = min(max(savedGroups.activeIndex, 0), portfolioGroups.count - 1)
            // The active portfolio's own store is authoritative for its holdings.
            portfolioGroups[activePortfolioIndex].holdings = portfolio
            portfolioGroups[activePortfolioIndex].history = portfolioHistory
        }

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
            saveToDisk()
        } else {
            watchlistGroups = savedWatchlistGroups
            let savedIndex = portfolioService.loadActiveWatchlistIndex()
            activeWatchlistIndex = min(savedIndex, watchlistGroups.count - 1)
            watchlist = watchlistGroups[activeWatchlistIndex].assets
        }

        // Refresh live prices and S&P 500 in the background immediately on launch
        Task { await fetchSP500History() }
        Task {
            await refreshFromAPI()
            await refreshDividendYieldsIfNeeded()
            await refreshWidgetSeries()
        }
        fetchMarketSentiment()

        // Start subscription-aware auto-refresh loop
        observeTierChanges()
        observeBlackTierIntervalChanges()
        scheduleAutoRefresh()
    }

    // MARK: - Public Refresh API

    func refreshFromAPI() async {
        // Snapshot prices before refresh for direction tracking
        let allBeforeRefresh = watchlist + portfolio.map(\.asset)
        for asset in allBeforeRefresh {
            previousPrices[asset.symbol] = asset.price
        }

        await refreshAssetsFromAPI()

        // Compute price directions after refresh
        let allAfterRefresh = watchlist + portfolio.map(\.asset)
        var newDirections: [String: PriceDirection] = [:]
        for asset in allAfterRefresh {
            if let oldPrice = previousPrices[asset.symbol] {
                if asset.price > oldPrice {
                    newDirections[asset.symbol] = .up
                } else if asset.price < oldPrice {
                    newDirections[asset.symbol] = .down
                }
            }
        }
        if !newDirections.isEmpty {
            priceDirections = newDirections
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                priceDirections = [:]
            }
        }

        // Check price alerts and significant movements against freshly updated prices
        let allAssets = watchlist + portfolio.map(\.asset)
        hasFreshQuotes = true
        await refreshAlertOnlyQuotes()
        if !Self.backgroundChecksOnly {
            alertManager?.checkAlerts(for: allAssets + alertOnlyAssets)
        }
        notificationScheduler?.checkSignificantMovements(for: allAssets)

        // Independent of each other — no reason to wait for one before the next.
        async let index: Void = refreshSP500Index()
        async let history: Void = fetchSP500History()
        async let news: Void = refreshNewsFromAPI()
        _ = await (index, history, news)
        portfolioHistory = portfolioService.appendCurrentSnapshot(
            to: portfolioHistory, currentValue: totalPortfolioValue
        )
        fetchMarketSentiment()
        saveToDisk()
        updateWidgetData()
        Task { await refreshWidgetSeries() }
        await LiveActivityManager.shared.updateAll(assets: stocks + crypto)

        // Update daily summary notification with latest portfolio data
        notificationScheduler?.scheduleDailySummary(
            portfolioValue: totalPortfolioValue,
            dailyPL: totalProfitLoss,
            dailyPLPercent: totalProfitLossPercent
        )
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
        DataPersistenceManager.shared.savePortfolioGroups(portfolioGroups, activeIndex: activePortfolioIndex)
        portfolioService.save(
            watchlist: watchlist,
            portfolio: portfolio,
            history: portfolioHistory,
            currency: preferredCurrency,
            watchlistGroups: watchlistGroups,
            activeWatchlistIndex: activeWatchlistIndex
        )
    }

    /// Reloads all in-memory state from local Keychain/UserDefaults.
    /// Called after sign-out to revert from cloud-merged data to local-only data.
    func reloadFromDisk() {
        let saved = portfolioService.load()
        preferredCurrency = saved.currency

        if !saved.portfolio.isEmpty || !saved.watchlist.isEmpty {
            watchlist = saved.watchlist
            portfolio = saved.portfolio
            if !saved.history.isEmpty { portfolioHistory = saved.history }
        }

        // Reload watchlist groups
        let savedWatchlistGroups = portfolioService.loadWatchlistGroups()
        if savedWatchlistGroups.isEmpty {
            watchlistGroups = [WatchlistGroup(name: "My Watchlist", assets: watchlist)]
            activeWatchlistIndex = 0
        } else {
            watchlistGroups = savedWatchlistGroups
            let savedIndex = portfolioService.loadActiveWatchlistIndex()
            activeWatchlistIndex = min(savedIndex, watchlistGroups.count - 1)
            watchlist = watchlistGroups[activeWatchlistIndex].assets
        }

        mergeTrackedAssetsIntoCanonicalCollections()
        updateWidgetData()
        AppLogger.persist.info("Reloaded local data from disk after sign-out")
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
        saveToDisk()
        Task { await refreshFromAPI() }
    }

    /// Creates and switches to a new portfolio. Returns false when the plan's limit is reached.
    @discardableResult
    func createPortfolio(name: String, emoji: String = "💼") -> Bool {
        guard SubscriptionManager.shared.canAddPortfolio(currentCount: portfolioGroups.count) else { return false }
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
        saveToDisk()

        // Referral qualification: portfolio created
        Task { await ReferralManager.shared.reportQualificationEvent(.portfolioCreated) }
        return true
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
        defer { isRefreshingQuotes = false }
        mergeTrackedAssetsIntoCanonicalCollections()
        // Stocks and crypto from different providers, at the same time.
        async let freshStocks = quoteService.refreshStockQuotes(for: stocks)
        async let freshCrypto = quoteService.refreshCryptoPrices(for: crypto)
        (stocks, crypto) = await (freshStocks, freshCrypto)
        let synced = quoteService.syncCollections(
            portfolio: portfolio,
            watchlist: watchlist,
            stocks: stocks,
            crypto: crypto
        )
        portfolio = synced.portfolio
        watchlist = synced.watchlist
        quoteFailures = Set((stocks + crypto).filter { quoteService.quoteFailed(for: $0) }.map(\.quoteIdentity))

        for index in portfolioGroups.indices where index != activePortfolioIndex {
            portfolioGroups[index].holdings = quoteService.syncCollections(
                portfolio: portfolioGroups[index].holdings,
                watchlist: [],
                stocks: stocks,
                crypto: crypto
            ).portfolio
        }

        // Sync prices for all non-active watchlist groups
        let allAssets = stocks + crypto
        for i in watchlistGroups.indices where i != activeWatchlistIndex {
            watchlistGroups[i].assets = watchlistGroups[i].assets.map { asset in
                guard let quote = allAssets.first(where: { $0.quoteIdentity == asset.quoteIdentity }) else { return asset }
                return quoteService.mergedAsset(old: asset, api: quote)
            }
        }

        lastQuoteRefreshDate = Date()
    }

    /// Ensures portfolio/watchlist assets participate in the shared refresh pipeline.
    /// Without this, synced/imported holdings can be left at a stale or zero price.
    /// Fetches one asset's live quote and applies it everywhere that symbol appears.
    func refreshQuote(for asset: Asset) async {
        let refreshed: Asset? = asset.kind == .crypto
            ? (await quoteService.refreshCryptoPrices(for: [asset])).first
            : (await quoteService.refreshStockQuotes(for: [asset])).first
        guard let fresh = refreshed, fresh.price > 0, !quoteService.quoteFailed(for: asset) else {
            quoteFailures.insert(asset.quoteIdentity)   // shown as "No live price", not a silent stale value
            return
        }
        quoteFailures.remove(asset.quoteIdentity)
        func apply(_ old: Asset) -> Asset { quoteService.mergedAsset(old: old, api: fresh) }
        for i in portfolio.indices where portfolio[i].asset.quoteIdentity == asset.quoteIdentity {
            portfolio[i].asset = apply(portfolio[i].asset)
        }
        for group in portfolioGroups.indices where group != activePortfolioIndex {
            for index in portfolioGroups[group].holdings.indices
            where portfolioGroups[group].holdings[index].asset.quoteIdentity == asset.quoteIdentity {
                let old = portfolioGroups[group].holdings[index].asset
                portfolioGroups[group].holdings[index].asset = apply(old)
            }
        }
        for i in watchlist.indices where watchlist[i].quoteIdentity == asset.quoteIdentity {
            watchlist[i] = apply(watchlist[i])
        }
        if asset.kind == .crypto {
            for i in crypto.indices where crypto[i].quoteIdentity == asset.quoteIdentity { crypto[i] = apply(crypto[i]) }
        } else {
            for i in stocks.indices where stocks[i].quoteIdentity == asset.quoteIdentity { stocks[i] = apply(stocks[i]) }
        }
        saveToDisk()
        updateWidgetData()
    }

    private func mergeTrackedAssetsIntoCanonicalCollections() {
        for asset in allTrackedHoldings.filter({ $0.shares > 0 }).map(\.asset) + watchlist {
            upsertTrackedAsset(asset)
        }
    }

    private func upsertTrackedAsset(_ asset: Asset) {
        switch asset.kind {
        case .stock:
            upsert(asset, into: &stocks)
        case .crypto:
            upsert(asset, into: &crypto)
        }
    }

    private func upsert(_ asset: Asset, into collection: inout [Asset]) {
        if let index = collection.firstIndex(where: { $0.quoteIdentity == asset.quoteIdentity }) {
            // Prefer a non-zero price when reconciling local/synced/imported copies.
            if collection[index].price <= 0 && asset.price > 0 {
                collection[index] = asset
            }
        } else {
            collection.append(asset)
        }
    }

    // MARK: - Watchlist Group Management

    func switchToWatchlist(index: Int) {
        guard watchlistGroups.indices.contains(index) else { return }
        watchlistGroups[activeWatchlistIndex].assets = watchlist
        activeWatchlistIndex = index
        watchlist = watchlistGroups[index].assets
        saveToDisk()
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
        let currencies = MarketData.quoteCurrencies
        let rates = await quoteService.fetchExchangeRates(for: currencies)
        for (code, rate) in rates {
            exchangeRates[code] = rate
            if rate.isFinite, rate > 0 { verifiedFXRates[code] = rate }
        }
    }

    /// Rebuilds the widgets' portfolio charts from real price history.
    func refreshWidgetSeries() async {
        guard !portfolio.isEmpty else {
            widgetDaySeries = []
            widgetWeekDaily = []
            updateWidgetData()
            return
        }
        let live = totalPortfolioValue
        let prevClose = live - dailyProfitLoss
        if let day = try? await PriceHistoryService.shared.portfolioSeries(
            holdings: portfolio, range: .oneDay, liveValue: live, previousCloseValue: prevClose) {
            widgetDaySeries = ChartShaper.downsample(day.points, to: 40).map(\.price)
        }
        if let month = try? await PriceHistoryService.shared.portfolioSeries(
            holdings: portfolio, range: .oneMonth, liveValue: live, previousCloseValue: prevClose) {
            // Last value of each calendar day, newest 7 days.
            let calendar = Calendar.current
            var perDay: [(Date, Double)] = []
            for p in month.points {
                let day = calendar.startOfDay(for: p.date)
                if let last = perDay.last, last.0 == day { perDay[perDay.count - 1] = (day, p.price) }
                else { perDay.append((day, p.price)) }
            }
            widgetWeekDaily = perDay.suffix(7).map(\.1)
        }
        updateWidgetData()
    }

    /// Light refresh for background runs: only symbols with an active alert, then check them.
    func refreshForAlertCheck() async {
        let symbols = Set(alertManager?.alerts.filter(\.isActive).map(\.symbol) ?? [])
        guard !symbols.isEmpty else { return }
        var seen = Set<String>()
        let targets = (portfolio.map(\.asset) + watchlist).filter { symbols.contains($0.symbol) && seen.insert($0.symbol).inserted }
        for asset in targets { await refreshQuote(for: asset) }
        await refreshAlertOnlyQuotes()
        alertManager?.checkAlerts(for: watchlist + portfolio.map(\.asset) + alertOnlyAssets)
    }

    /// Prices the alert symbols nothing else is tracking.
    func refreshAlertOnlyQuotes() async {
        let tracked = Set((watchlist + portfolio.map(\.asset)).map(\.symbol))
        var seen = Set<String>()
        let wanted = (alertManager?.alerts ?? [])
            .filter { $0.isActive && !tracked.contains($0.symbol) && seen.insert($0.symbol).inserted }
            .map(\.quoteAsset)
        guard !wanted.isEmpty else {
            if !alertOnlyAssets.isEmpty { alertOnlyAssets = [] }
            return
        }
        let service = QuoteService()
        let stocks = wanted.filter { $0.kind == .stock }
        let coins = wanted.filter { $0.kind == .crypto }
        var fresh: [Asset] = []
        if !stocks.isEmpty { fresh += await service.refreshStockQuotes(for: stocks) }
        if !coins.isEmpty { fresh += await service.refreshCryptoPrices(for: coins) }
        // Keep the last good price for any symbol whose quote failed this time.
        let previous = Dictionary(alertOnlyAssets.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        alertOnlyAssets = wanted.map { want in
            if let got = fresh.first(where: { $0.symbol == want.symbol }), got.price > 0 { return got }
            return previous[want.symbol] ?? want
        }
    }

    /// Real S&P 500 level and day change from Yahoo (^GSPC).
    func refreshSP500Index() async {
        guard let quote = try? await APIService.shared.fetchYahooQuote(symbol: "^GSPC", name: "S&P 500") else { return }
        sp500Index = MarketIndex(name: "S&P 500", symbol: "^GSPC", price: quote.price,
                                 change: quote.change, changePercent: quote.changePercent)
    }

    /// Converts an amount typed in the person's display currency into USD for storage.
    func usd(fromDisplay amount: Double) -> Double {
        amount * (FXRates.shared.toUSDFactor(from: preferredCurrency) ?? 1)
    }

    /// Converts a stored USD amount into the display currency (e.g. to prefill a field).
    func display(fromUSD amount: Double) -> Double {
        preferredCurrency == "USD" ? amount : amount * (exchangeRates[preferredCurrency] ?? 1)
    }

    /// Unambiguous symbol for the display currency ("A$", "US$", "€") for input fields.
    var displayCurrencySymbol: String {
        switch preferredCurrency {
        case "USD": return "US$"
        case "AUD": return "A$"
        case "CAD": return "C$"
        default:
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = preferredCurrency
            return f.currencySymbol ?? preferredCurrency
        }
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
    /// Called after FMP enrichment so the Portfolio tab's Income section has data.
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

    /// Latest-session (1D) history for a row sparkline. Shaped and cached by
    /// `PriceHistoryService` (60s TTL); empty when unavailable — rows then show
    /// no sparkline rather than an invented one.
    func fetchMiniChartHistory(for asset: Asset) async -> [PricePoint] {
        if let points = try? await PriceHistoryService.shared.history(for: asset, range: .oneDay) {
            miniChartCache[asset.symbol] = points
            return points
        }
        return miniChartCache[asset.symbol] ?? []
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
            // Keep previously fetched articles on failure; never fall back to placeholders.
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

    // MARK: - Portfolio Deduplication

    /// One-time fix for data saved before ASX quotes were converted to USD on the
    /// way in: ASX costs were stored as AUD numbers next to USD prices. Converting
    /// them keeps each holding's return correct now that its price is USD.
    private func migrateASXValuesToUSDIfNeeded() {
        let key = "fx_usd_normalised_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard let aud = exchangeRates["AUD"], aud > 0 else { return }
        var changed = false
        for i in portfolio.indices where portfolio[i].asset.exchange == "ASX" {
            guard portfolio[i].transactions.allSatisfy({ $0.provenance == nil }) else { continue }
            portfolio[i].avgCost /= aud
            portfolio[i].transactions = portfolio[i].transactions.map {
                Transaction(id: $0.id, date: $0.date, shares: $0.shares, pricePerShare: $0.pricePerShare / aud, type: $0.type,
                            fees: $0.fees / aud, avgCostAtSale: $0.avgCostAtSale.map { $0 / aud })
            }
            changed = true
        }
        if changed {
            AppLogger.persist.info("Converted saved ASX cost bases from AUD to USD")
            saveToDisk()
        }

        // Price-alert targets for ASX symbols were AUD numbers too. (MarketData is
        // created before PriceAlertManager, so the manager loads the converted list.)
        let asxSymbols = Set((portfolio.map(\.asset) + watchlist).filter { $0.exchange == "ASX" }.map(\.symbol))
        let alerts = DataPersistenceManager.shared.loadPriceAlerts()
        if alerts.contains(where: { asxSymbols.contains($0.symbol) }) {
            let converted = alerts.map { a -> PriceAlert in
                guard asxSymbols.contains(a.symbol) else { return a }
                return PriceAlert(id: a.id, symbol: a.symbol, assetName: a.assetName, targetPrice: a.targetPrice / aud,
                                  condition: a.condition, isActive: a.isActive, createdAt: a.createdAt,
                                  repeats: a.repeats, isArmed: a.isArmed, lastTriggeredAt: a.lastTriggeredAt,
                                  kind: a.kind, exchange: a.exchange)
            }
            DataPersistenceManager.shared.savePriceAlerts(converted)
        }
    }

    // MARK: - Portfolio Mutations

    @discardableResult
    func addToPortfolio(asset: Asset, shares: Double, avgCost: Double, date: Date = Date(),
                        feesUSD: Double = 0, provenance: TradeProvenance? = nil) -> HoldingChange {
        let transaction = Transaction(
            date: date,
            shares: shares,
            pricePerShare: avgCost,
            type: .buy,
            fees: feesUSD,
            provenance: provenance
        )

        let index = portfolio.firstIndex {
            $0.brokerAccount?.tracking != true && $0.asset.symbol == asset.symbol &&
                $0.asset.kind == asset.kind && $0.asset.exchange == asset.exchange
        }
        var holding: PortfolioHolding
        if let index {
            // Merge into existing holding with weighted average cost
            holding = portfolio[index]
            let totalCost = (holding.shares * holding.avgCost) + (shares * avgCost) + feesUSD
            holding.shares += shares
            holding.avgCost = holding.shares > 0 ? totalCost / holding.shares : 0
            holding.asset = asset
            holding.transactions.append(transaction)
        } else {
            // New holding with initial transaction
            holding = PortfolioHolding(
                asset: asset,
                shares: shares,
                avgCost: avgCost + feesUSD / shares,
                transactions: [transaction]
            )
        }
        guard SyncManager.shared.queuePortfolioChange(holding, changed: [transaction.id]) else {
            return .invalid("Couldn’t save the portfolio change on this device.")
        }
        upsertTrackedAsset(asset)
        if let index { portfolio[index] = holding } else { portfolio.append(holding) }
        saveToDisk()
        updateWidgetData()
        // Price it now, not on the next refresh cycle — until then a manually added
        // holding is valued at its cost and every total/chart is wrong.
        Task { await refreshQuote(for: asset) }

        // Referral qualification: first holding (only fires for the very first holding)
        if portfolio.count == 1 {
            Task { await ReferralManager.shared.reportQualificationEvent(.firstHolding) }
        }
        return .ok
    }

    // MARK: - Validated holdings API
    //
    // Use these from UI: they enforce plan limits, store costs in USD (the app's
    // money invariant — see FXRates) and never let a position go negative.

    enum HoldingChange: Equatable {
        case ok
        case limitReached(Int)
        case invalid(String)
    }

    /// Whether another *new* holding (not a top-up of an existing one) fits the plan.
    func canAddHolding(symbol: String, kind: AssetKind) -> Bool {
        if portfolio.contains(where: { $0.brokerAccount?.tracking != true && $0.asset.symbol == symbol && $0.asset.kind == kind }) { return true }
        return SubscriptionManager.shared.canAddPortfolioHolding(currentCount: portfolio.count)
    }

    /// Adds a buy. `costPerUnit` is in `costCurrency` — normally the asset's own
    /// trading currency (AUD for ASX, USD for US/crypto), as on a broker statement.
    @discardableResult
    func addHolding(asset: Asset, shares: Double, costPerUnit: Double,
                    costCurrency: String = "USD", date: Date = Date(),
                    source: TradeProvenance.Source = .openingPosition,
                    sourceCostKnown: Bool = true, fees: Double? = nil) -> HoldingChange {
        guard shares > 0, shares.isFinite else { return .invalid("Enter how many you own.") }
        guard costPerUnit >= 0, costPerUnit.isFinite else { return .invalid("Enter what you paid per unit.") }
        let brokerage = fees ?? 0
        guard brokerage.isFinite, brokerage >= 0 else { return .invalid("Enter valid fees, or leave them blank.") }
        guard canAddHolding(symbol: asset.symbol, kind: asset.kind) else {
            return .limitReached(SubscriptionManager.shared.currentTier.maxPortfolioHoldings ?? portfolio.count)
        }
        let factor = FXRates.shared.toUSDFactor(from: costCurrency) ?? 1
        let usdCost = costPerUnit * factor
        let usdFees = brokerage * factor
        guard usdCost.isFinite, usdFees.isFinite else { return .invalid("Enter a smaller price or fee.") }
        let provenance = tradeProvenance(source: source, currency: costCurrency, unitPrice: sourceCostKnown ? costPerUnit : nil,
                                         fees: fees, factor: factor)
        return addToPortfolio(asset: asset, shares: shares, avgCost: usdCost, date: date,
                              feesUSD: usdFees, provenance: provenance)
    }

    func tradeProvenance(source: TradeProvenance.Source, currency: String?, unitPrice: Double?,
                         fees: Double?, factor: Double) -> TradeProvenance {
        let code = currency?.uppercased()
        guard let code, code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }),
              factor.isFinite, factor > 0, unitPrice != nil || fees != nil else {
            return TradeProvenance(source: source, currency: nil, unitPrice: nil, fees: nil,
                                   usdPerUnit: nil, conversion: nil, conversionRecordedAt: nil)
        }
        let conversion: TradeProvenance.Conversion
        if code == "USD" {
            conversion = .usd
        } else if let verified = verifiedFXRates[code], 1 / verified == factor {
            conversion = .appReference
        } else {
            conversion = .appFallback
        }
        return TradeProvenance(source: source, currency: code, unitPrice: unitPrice, fees: fees,
                               usdPerUnit: factor, conversion: conversion,
                               conversionRecordedAt: Date.now.ISO8601Format())
    }

    /// Records a buy or sell on an existing holding. A sell can't exceed what's
    /// held; selling everything removes the holding.
    @discardableResult
    func recordTransaction(holdingID: UUID, type: TransactionType, shares: Double,
                           pricePerUnit: Double, priceCurrency: String = "USD", fees: Double = 0,
                           date: Date = Date()) -> HoldingChange {
        guard let i = portfolio.firstIndex(where: { $0.id == holdingID }) else { return .invalid("That holding no longer exists.") }
        guard shares > 0, shares.isFinite else { return .invalid("Enter a quantity above zero.") }
        guard pricePerUnit >= 0, pricePerUnit.isFinite else { return .invalid("Enter a valid price.") }
        guard fees >= 0, fees.isFinite else { return .invalid("Enter valid fees, or leave them blank.") }
        let held = portfolio[i].shares
        if type == .sell, shares > held + 1e-9 {
            return .invalid("You can sell at most \(held.formatted(.number.precision(.fractionLength(0...8)))).")
        }
        let factor = FXRates.shared.toUSDFactor(from: priceCurrency) ?? 1
        let usd = pricePerUnit * factor
        let feesUSD = fees * factor
        let provenance = tradeProvenance(source: .manualTrade, currency: priceCurrency, unitPrice: pricePerUnit,
                                         fees: fees, factor: factor)
        // A sale remembers the average cost it was made at, so its realised profit is
        // known even when the list doesn't show how the shares were bought.
        let tx = Transaction(date: date, shares: shares, pricePerShare: usd, type: type, fees: feesUSD,
                             avgCostAtSale: type == .sell ? portfolio[i].avgCost : nil,
                             provenance: provenance)
        var holding = portfolio[i]
        switch type {
        case .buy:
            let total = held * portfolio[i].avgCost + shares * usd + feesUSD
            holding.shares = held + shares
            holding.avgCost = total / holding.shares
        case .sell:
            holding.shares = max(held - shares, 0)
        }
        holding.transactions.append(tx)
        let closes = type == .sell && holding.shares <= 1e-9
        if closes { holding.shares = 0 }
        guard SyncManager.shared.queuePortfolioChange(holding, changed: [tx.id], archived: closes,
                                                    closedAt: closes ? date : nil) else {
            return .invalid("Couldn’t save the portfolio change on this device.")
        }
        if closes {
            closePosition(holding)
        } else {
            portfolio[i] = holding
            saveToDisk()
            updateWidgetData()
        }
        return .ok
    }

    /// Deletes one transaction and rebuilds the position from those that remain.
    @discardableResult
    func deleteTransaction(holdingID: UUID, transactionID: UUID) -> HoldingChange {
        guard let i = portfolio.firstIndex(where: { $0.id == holdingID }) else { return .invalid("That holding no longer exists.") }
        guard let deleted = portfolio[i].transactions.first(where: { $0.id == transactionID }) else {
            return .invalid("That transaction no longer exists.")
        }
        let remaining = portfolio[i].transactions.filter { $0.id != transactionID }
        guard !remaining.isEmpty else { return .invalid("A holding needs at least one transaction — remove the holding instead.") }
        let rebuilt = Self.position(from: remaining)
        guard rebuilt.shares > 1e-9 else { return .invalid("Removing this would leave a negative position.") }
        var holding = portfolio[i]
        holding.transactions = remaining
        holding.shares = rebuilt.shares
        holding.avgCost = rebuilt.avgCost
        guard SyncManager.shared.queuePortfolioChange(holding, deleted: [deleted]) else {
            return .invalid("Couldn’t save the portfolio change on this device.")
        }
        portfolio[i] = holding
        saveToDisk()
        updateWidgetData()
        return .ok
    }

    /// Shares held and average cost (USD, buy fees included) from a transaction list, in date order.
    static func position(from transactions: [Transaction]) -> (shares: Double, avgCost: Double) {
        let ledger = PositionLedger(transactions)
        return (ledger.shares, ledger.avgCost)
    }

    /// A holding sold down to zero leaves the list but keeps its trades, so its
    /// realised profit still counts in total return ("Closed positions").
    private func closePosition(_ holding: PortfolioHolding) {
        if portfolioGroups.indices.contains(activePortfolioIndex) {
            let closed = ClosedPosition(
                id: holding.id,
                asset: holding.asset,
                transactions: holding.transactions,
                openedAt: holding.transactions.map(\.date).min() ?? holding.dateAdded,
                closedAt: holding.transactions.map(\.date).max() ?? Date()
            )
            portfolioGroups[activePortfolioIndex].closedPositions.removeAll { $0.id == closed.id }
            portfolioGroups[activePortfolioIndex].closedPositions.insert(closed, at: 0)
        }
        removeLocalHolding(holding)
    }

    /// Forgets a closed position — its realised profit leaves the totals.
    func removeClosedPosition(id: UUID) {
        guard portfolioGroups.indices.contains(activePortfolioIndex) else { return }
        DataPersistenceManager.shared.hideSyncedClosedPosition(id)
        portfolioGroups[activePortfolioIndex].closedPositions.removeAll { $0.id == id }
        saveToDisk()
    }

    func applySyncedClosedPositions(_ positions: [ClosedPosition], reset: Bool = false) {
        guard portfolioGroups.indices.contains(activePortfolioIndex) else { return }
        if reset {
            for index in portfolioGroups.indices { portfolioGroups[index].closedPositions.removeAll() }
        }
        let known = Set(portfolioGroups.flatMap { $0.closedPositions.map(\.id) })
        let hidden = DataPersistenceManager.shared.hiddenSyncedClosedPositions()
        let incoming = positions.filter { !known.contains($0.id) && !hidden.contains($0.id) }
        guard reset || !incoming.isEmpty else { return }
        portfolioGroups[activePortfolioIndex].closedPositions.append(contentsOf: incoming)
        portfolioGroups[activePortfolioIndex].closedPositions.sort { $0.closedAt > $1.closedAt }
        saveToDisk()
    }

    /// Fills in dividend yields for stock holdings that don't have one yet.
    /// US: FMP TTM ratios. ASX (not on FMP's free plan): the last 12 months of
    /// dividends from Yahoo's chart events ÷ today's price — cash dividends only,
    /// franking credits aren't included.
    func refreshDividendYieldsIfNeeded() async {
        let targets: [Asset] = portfolio.map(\.asset).filter { (a: Asset) -> Bool in
            a.kind == .stock && a.dividend == nil
        }
        // In parallel and applied as each lands: a slow or rate-limited FMP lookup
        // must not hold ASX yields (a different provider) behind it.
        await withTaskGroup(of: (String, Double?).self) { group in
            for asset in targets {
                group.addTask { (asset.symbol, await self.dividendYieldPercent(for: asset)) }
            }
            for await (symbol, yield) in group {
                if let yield { updateAssetDividend(symbol: symbol, yieldPercent: yield) }
            }
        }
    }

    /// Trailing dividend yield in percent, or nil if it couldn't be found.
    private func dividendYieldPercent(for asset: Asset) async -> Double? {
        if QuoteService.isASX(asset) {
            guard asset.price > 0, let perShareUSD = await asxTrailingDividendUSD(asset.symbol) else { return nil }
            return perShareUSD / asset.price * 100
        }
        guard let ratios = await FMPService.shared.fetchRatios(symbol: asset.symbol),
              let yield = ratios.dividendYield else { return nil }
        // FMP reports a fraction (0.0045); Asset stores percent.
        return yield < 1 ? yield * 100 : yield
    }

    /// Trailing-12-month dividend per share (USD) for an ASX listing, 0 if it paid
    /// none, nil if Yahoo couldn't be reached. Cached for 6 hours per symbol — quote
    /// refreshes reset `Asset.dividend`, and Yahoo shares one rate bucket.
    private func asxTrailingDividendUSD(_ symbol: String) async -> Double? {
        let key = "asx_dividend_ttm_v1"
        let now = Date().timeIntervalSince1970
        var cache = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        if let hit = cache[symbol], hit.count == 2, now - hit[1] < 6 * 3600 { return hit[0] }
        guard let facts = try? await APIService.shared.fetchYahooListingFacts(
            symbol: QuoteService.finnhubASXSymbol(for: symbol)) else { return nil }
        let perShare = facts.trailing12MonthDividendUSD ?? 0
        cache[symbol] = [perShare, now]
        UserDefaults.standard.set(cache, forKey: key)
        return perShare
    }

    @discardableResult
    func removeFromPortfolio(_ holding: PortfolioHolding) -> Bool {
        var archived = holding
        if archived.brokerAccount?.tracking == true {
            archived.brokerAccount?.observed_at = Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        guard SyncManager.shared.queuePortfolioChange(archived, archived: true) else { return false }
        removeLocalHolding(holding)
        return true
    }

    func saveBrokerHoldings(_ holdings: [PortfolioHolding]) -> Bool {
        let current = Set(portfolio.map(\.id))
        let changes = holdings.map { holding in
            PortfolioLedgerChange(revision: UUID(), holding: holding,
                changed: [],
                deleted: [], archivedAt: nil, closedAt: nil)
        }
        guard SyncManager.shared.queuePortfolioChanges(changes) else { return false }
        let replacements = Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })
        portfolio = portfolio.map { replacements[$0.id] ?? $0 } + holdings.filter { !current.contains($0.id) }
        for holding in holdings where holding.shares > 0 { upsertTrackedAsset(holding.asset) }
        saveToDisk()
        updateWidgetData()
        Task {
            for holding in holdings where holding.shares > 0 && !current.contains(holding.id) {
                await refreshQuote(for: holding.asset)
            }
        }
        return true
    }

    private func removeLocalHolding(_ holding: PortfolioHolding) {
        portfolio.removeAll { $0.id == holding.id }
        if portfolio.isEmpty {
            // Reset chart and history when all holdings removed
            portfolioHistory = []
        } else {
            // Record the new (lower) total so the chart reflects the deletion
            portfolioHistory = portfolioService.appendCurrentSnapshot(
                to: portfolioHistory, currentValue: totalPortfolioValue
            )
        }
        saveToDisk()
        updateWidgetData()
    }

    func updateHolding(_ holding: PortfolioHolding, shares: Double, avgCost: Double) {
        guard let index = portfolio.firstIndex(where: { $0.id == holding.id }) else { return }
        var updated = portfolio[index]
        updated.shares = shares
        updated.avgCost = avgCost
        guard SyncManager.shared.queuePortfolioChange(updated) else { return }
        portfolio[index] = updated
        saveToDisk()
        updateWidgetData()
    }

    // MARK: - Watchlist Mutations

    func addToWatchlist(_ asset: Asset) {
        guard !watchlist.contains(where: { $0.symbol == asset.symbol }) else { return }
        upsertTrackedAsset(asset)
        watchlist.append(asset)
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
        // Price just this one. A full refresh per add re-quoted everything and reloaded
        // Home's index cards: six onboarding picks = six refreshes at once (~60 requests).
        Task { await refreshQuote(for: asset) }
    }

    func removeFromWatchlist(_ asset: Asset) {
        watchlist.removeAll { $0.id == asset.id }
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn {
            Task { await SyncManager.shared.softDeleteWatchlistAsset(symbol: asset.symbol) }
        }
    }

    func removeMultipleFromWatchlist(_ ids: Set<UUID>) {
        let removedSymbols = watchlist.filter { ids.contains($0.id) }.map(\.symbol)
        watchlist.removeAll { ids.contains($0.id) }
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn {
            Task { await SyncManager.shared.softDeleteWatchlistAssets(symbols: removedSymbols) }
        }
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
    /// Describes today's market from the S&P 500's real day change only. (It used
    /// to blend in the person's *all-time* return and a never-updated index value,
    /// and was labelled like a fear-and-greed index.)
    func fetchMarketSentiment() {
        guard sp500Index.price > 0 else { return }
        let blended = sp500Index.changePercent

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
        let localAssets = Dictionary((watchlist + stocks + crypto).map { ($0.quoteIdentity, $0) }, uniquingKeysWith: { first, _ in first })
        let listedTypes = Dictionary((portfolio.map(\.asset) + stocks + watchlist).compactMap { asset in
            asset.isETF.map { (asset.quoteIdentity, $0) }
        }, uniquingKeysWith: { first, _ in first })
        watchlist = remoteWatchlist.map { asset in
            guard let live = localAssets[asset.quoteIdentity], live.price > 0 else { return asset }
            var a = asset
            a.price = live.price
            a.change = live.change
            a.changePercent = live.changePercent
            a.volume = live.volume
            return a
        }
        // Preserve live market data for portfolio assets
        portfolio = remotePortfolio.map { holding in
            var h = holding
            h.asset.isETF = h.asset.isETF ?? listedTypes[h.asset.quoteIdentity]
            guard let live = localAssets[h.asset.quoteIdentity], live.price > 0 else { return h }
            h.asset.price = live.price
            h.asset.change = live.change
            h.asset.changePercent = live.changePercent
            h.asset.volume = live.volume
            return h
        }
        if !remoteHistory.isEmpty { portfolioHistory = remoteHistory }
        saveToDisk()
        updateWidgetData()
    }

    func refreshSyncedQuotesIfNeeded() async {
        guard portfolio.contains(where: { $0.shares > 0 && hasNoLivePrice($0.asset) }) else { return }
        await updateExchangeRate()
        await refreshAssetsFromAPI()
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
        upsertTrackedAsset(asset)
    }

    // MARK: - Widget

    func updateWidgetData() {
        guard let shared = UserDefaults(suiteName: Constants.Widget.appGroup) else { return }

        // Widgets show the same currency as the app (all stored values are USD).
        shared.set(preferredCurrency, forKey: "displayCurrency")
        shared.set(preferredCurrency == "USD" ? 1.0 : (exchangeRates[preferredCurrency] ?? 1.0), forKey: "displayRate")

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
        // Sparkline: today's real portfolio series (see refreshWidgetSeries); never synthesised.
        let historyValues: [Double] = widgetDaySeries
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
            // Real cached mini chart only; the widget hides the sparkline when empty.
            let sparkPts: [Double] = {
                if let cached = miniChartCache[top.asset.symbol], cached.count >= 2 {
                    return Array(cached.suffix(24).map(\.price))
                }
                return []
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
        // Weekly values: one real value per trading day, last 7 (see refreshWidgetSeries).
        let weeklyVals = widgetWeekDaily
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
