//
//  SymbolSearch.swift
//  Stock Tracker
//
//  One search for the whole app (Search tab + "Add to watchlist" sheet), after
//  Apple Stocks / Perplexity Finance / Yahoo on Mobbin:
//  - US + ASX stocks and ETFs (Yahoo) and crypto (CoinGecko), searched together
//  - relevance order: exact ticker, then ticker prefix, then name; provider order breaks ties
//  - the list appears as soon as names arrive; prices fill in row by row
//  - every search ends in results, "no matches" or "search isn't available" — never a spinner
//  - recent searches; inline add/remove that respects the plan's watchlist limit
//

import SwiftUI
import Combine
import TradingCore

// MARK: - Model

enum SymbolMarket: String, Codable, CaseIterable, Sendable {
    /// `intl`: London, Frankfurt, Paris, Amsterdam, Zurich, Tokyo, Hong Kong, Singapore,
    /// Seoul and Mumbai listings, kept under their Yahoo symbol ("VOD.L", "7203.T").
    case us, asx, crypto, intl
}

/// A search result, independent of whether we have a live quote for it yet.
struct SymbolHit: Identifiable, Hashable, Codable, Sendable {
    let symbol: String          // display symbol: "BHP", "AAPL", "BTC"
    let name: String
    let kind: AssetKind
    /// "US", "ASX" ("" for crypto) — the same convention QuoteService routes on.
    let exchange: String
    /// CoinGecko id for crypto ("bitcoin"); empty for stocks.
    var coinID: String = ""
    var isETF: Bool? = nil

    var market: SymbolMarket {
        if kind == .crypto { return .crypto }
        if exchange == "International" { return .intl }
        return exchange == "ASX" ? .asx : .us
    }

    var id: String { "\(market.rawValue):\(symbol)" }

    /// Short label shown next to the ticker.
    var badge: String {
        switch market {
        case .crypto: return "Crypto"
        case .asx:    return "ASX"
        case .us:     return "US"
        case .intl:   return Venue.parse(yahooSymbol: symbol)?.venue.shortName ?? "Intl"
        }
    }

    init(symbol: String, name: String, kind: AssetKind, exchange: String, coinID: String = "", isETF: Bool? = nil) {
        self.symbol = symbol
        self.name = name
        self.kind = kind
        self.exchange = exchange
        self.coinID = coinID
        self.isETF = isETF
    }

    init(picked: PickedAsset) {
        self.init(symbol: picked.symbol, name: picked.name, kind: picked.kind,
                  exchange: picked.kind == .crypto ? "" : picked.exchange, coinID: picked.coinID)
    }

    /// An asset to track before (or without) a live quote. Price 0 = "not loaded".
    func placeholderAsset() -> Asset {
        Asset(symbol: symbol, name: name, price: 0, change: 0, changePercent: 0, volume: 0,
              kind: kind, exchange: kind == .crypto ? "" : exchange, isETF: isETF)
    }

    /// Whether `asset` is this listing (BHP on the ASX is not BHP on the NYSE).
    func matches(_ asset: Asset) -> Bool {
        if asset.quoteIdentity == placeholderAsset().quoteIdentity { return true }
        guard asset.symbol.uppercased() == symbol.uppercased(), asset.kind == kind else { return false }
        return asset.isUnresolvedUSQuote && market == .us
    }
}

enum SymbolSearchScope: String, CaseIterable, Hashable {
    case all, us, asx, intl, crypto

    var title: LocalizedStringKey {
        switch self {
        case .all:    return "All"
        case .us:     return "US"
        case .asx:    return "ASX"
        case .intl:   return "Global"
        case .crypto: return "Crypto"
        }
    }

    func includes(_ hit: SymbolHit) -> Bool {
        switch self {
        case .all:    return true
        case .us:     return hit.market == .us
        case .asx:    return hit.market == .asx
        case .crypto: return hit.market == .crypto
        case .intl:   return hit.market == .intl
        }
    }
}

// MARK: - Ranking (pure, testable)

enum SymbolRanking {
    /// 0 exact ticker · 1 ticker prefix · 2 name prefix · 3 a word in the name starts with it · 4 other.
    static func score(_ hit: SymbolHit, query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 4 }
        let symbol = hit.symbol.lowercased()
        let name = hit.name.lowercased()
        if symbol == q { return 0 }
        if symbol.hasPrefix(q) { return 1 }
        if name.hasPrefix(q) { return 2 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 3 }
        return 4
    }

    /// Merges provider lists, removes duplicate listings and orders by relevance.
    /// Provider order (Yahoo's relevance, CoinGecko's market-cap rank) breaks ties,
    /// stocks before crypto.
    static func rank(stocks: [SymbolHit], crypto: [SymbolHit], query: String) -> [SymbolHit] {
        var seen = Set<String>()
        var ordered: [(hit: SymbolHit, score: Int, tie: Int)] = []
        for (i, hit) in stocks.enumerated() where seen.insert(hit.id).inserted {
            ordered.append((hit, score(hit, query: query), i))
        }
        // Coins only appear when their ticker or name really matches, and jump ahead of
        // stocks when the query *is* the coin ("bitcoin", "BTC" → Bitcoin, not a Bitcoin fund).
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        for (i, hit) in crypto.prefix(3).enumerated() where seen.insert(hit.id).inserted {
            var s = score(hit, query: query)
            guard s <= 2 else { continue }
            if hit.name.lowercased() == q || (s == 0 && hit.symbol.count >= 3) { s = -1 }
            ordered.append((hit, s, 1_000 + i))
        }
        return ordered
            .sorted { ($0.score, $0.tie) < ($1.score, $1.tie) }
            .map(\.hit)
    }
}

// MARK: - Recent searches

@MainActor
final class RecentSymbolStore: ObservableObject {
    static let shared = RecentSymbolStore()
    private let key = "symbol_search_recents_v1"
    private let limit = 8

    @Published private(set) var items: [SymbolHit] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SymbolHit].self, from: data) {
            items = saved
        }
    }

    func record(_ hit: SymbolHit) {
        items.removeAll { $0.id == hit.id }
        items.insert(hit, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Search model

@MainActor
final class SymbolSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, searching, results, empty, failed }

    @Published var query: String = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published var scope: SymbolSearchScope = .all
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var allHits: [SymbolHit] = []
    /// Live quotes by `SymbolHit.id`.
    @Published private(set) var quotes: [String: Asset] = [:]
    @Published private(set) var quoteFailed: Set<String> = []
    @Published private(set) var loadingQuote: Set<String> = []

    var hits: [SymbolHit] { allHits.filter(scope.includes) }

    private var searchTask: Task<Void, Never>?
    private var quoteTasks: [Task<Void, Never>] = []

    private let prefetchQuotes: Bool

    init(scope: SymbolSearchScope = .all, prefetchQuotes: Bool = true) {
        self.scope = scope
        self.prefetchQuotes = prefetchQuotes
    }

    func retry() { schedule(debounce: false) }

    private func schedule(debounce: Bool = true) {
        searchTask?.cancel()
        quoteTasks.forEach { $0.cancel() }
        quoteTasks.removeAll()
        loadingQuote.removeAll()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            phase = .idle
            allHits = []
            return
        }
        phase = .searching
        searchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await self?.run(q)
        }
    }

    /// Stocks and crypto are searched in parallel and merged as each answers, so a
    /// slow or rate-limited provider never holds the other's results hostage. Each
    /// provider gets a deadline, so every search ends in results, "no matches" or "failed".
    private func run(_ q: String) async {
        var stocks: [SymbolHit]?
        var crypto: [SymbolHit]?
        await withTaskGroup(of: (isStock: Bool, hits: [SymbolHit]?).self) { group in
            group.addTask { (true, await Self.withDeadline(seconds: 12) { await Self.stockHits(q) }) }
            group.addTask { (false, await Self.withDeadline(seconds: 8) { await Self.cryptoHits(q) }) }
            for await result in group {
                guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    group.cancelAll()
                    return
                }
                if result.isStock { stocks = result.hits } else { crypto = result.hits }
                let merged = SymbolRanking.rank(stocks: stocks ?? [], crypto: crypto ?? [], query: q)
                allHits = merged
                if !merged.isEmpty {
                    phase = .results
                    if prefetchQuotes { loadQuotes(for: Array(merged.prefix(8))) }
                }
            }
        }
        guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        // "No matches" only when the stock provider actually answered. Crypto is
        // matched locally and always answers, so it can't vouch for an empty result
        // ("apple" showed "No matches" while Yahoo was failing).
        if allHits.isEmpty {
            phase = stocks == nil ? .failed : .empty
        } else {
            phase = .results
        }
    }

    /// The operation's result, or nil if it takes longer than `seconds`.
    nonisolated static func withDeadline<T: Sendable>(seconds: Double,
                                                             _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// nil = the provider failed (offline, rate-limited); [] = it answered with nothing.
    private static func stockHits(_ q: String) async -> [SymbolHit]? {
        guard let results = try? await APIService.shared.fetchSymbolSearch(query: q, kind: .stock) else { return nil }
        return results.compactMap { r in
            if r.exchange == "ASX" {
                return SymbolHit(symbol: r.symbol, name: r.name, kind: .stock, exchange: "ASX", isETF: r.isETF)
            }
            // Exchanges the app can price through Yahoo and practice-trade: keep the suffixed symbol.
            if let (venue, _) = Venue.parse(yahooSymbol: r.symbol), venue != .asx {
                return SymbolHit(symbol: r.symbol.uppercased(), name: r.name, kind: .stock, exchange: "International", isETF: r.isETF)
            }
            // Other US listings only (the app quotes US via Alpaca); skip markets it can't price.
            guard r.currency.uppercased() == "USD", !r.symbol.contains("."),
                  usExchange(from: r.region) != nil else { return nil }
            return SymbolHit(symbol: r.symbol, name: r.name, kind: .stock, exchange: "US", isETF: r.isETF)
        }
    }

    /// Coins the app can actually price and refresh (mirrors `QuoteService.coinGeckoIDMap`).
    /// CoinGecko's search returns thousands of coins we can't quote (tokenised stocks,
    /// meme coins named after companies) and burns its ~10-calls-a-minute free budget,
    /// so crypto is matched locally: instant, offline, and every result gets a live price.
    static let supportedCoins: [SymbolHit] = [
        ("BTC", "Bitcoin", "bitcoin"), ("ETH", "Ethereum", "ethereum"), ("SOL", "Solana", "solana"),
        ("XRP", "XRP", "ripple"), ("BNB", "BNB", "binancecoin"), ("ADA", "Cardano", "cardano"),
        ("DOGE", "Dogecoin", "dogecoin"), ("LINK", "Chainlink", "chainlink"), ("AVAX", "Avalanche", "avalanche-2"),
        ("DOT", "Polkadot", "polkadot"), ("POL", "Polygon", "polygon-ecosystem-token"), ("LTC", "Litecoin", "litecoin"),
        ("UNI", "Uniswap", "uniswap"), ("ATOM", "Cosmos", "cosmos")
    ].map { SymbolHit(symbol: $0.0, name: $0.1, kind: .crypto, exchange: "", coinID: $0.2) }

    private static func cryptoHits(_ q: String) async -> [SymbolHit]? {
        let query = q.lowercased()
        return supportedCoins.filter { coin in
            coin.symbol.lowercased().hasPrefix(query)
                || coin.name.lowercased().hasPrefix(query)
                || coin.coinID.hasPrefix(query)
        }
    }

    /// Recognises US venues in Yahoo's `exchDisp` (we quote US listings via Alpaca).
    static func usExchange(from display: String) -> String? {
        let d = display.uppercased()
        if d.contains("NASDAQ") { return "NASDAQ" }
        if d.contains("ARCA") { return "NYSEARCA" }
        if d.contains("AMERICAN") || d.contains("AMEX") { return "NYSE AMERICAN" }
        if d.hasPrefix("NYSE") { return "NYSE" }
        if d.contains("BATS") || d.contains("CBOE") { return "BATS" }
        if d.contains("OTC") { return "OTC" }
        return nil
    }

    // MARK: Quotes

    private func loadQuotes(for hits: [SymbolHit]) {
        // CoinGecko's free tier allows ~10 calls a minute: price at most two coins per search.
        var cryptoBudget = 2
        let wanted = hits.filter { hit in
            guard quotes[hit.id] == nil, !quoteFailed.contains(hit.id), !loadingQuote.contains(hit.id) else { return false }
            if hit.market == .crypto {
                guard cryptoBudget > 0 else { return false }
                cryptoBudget -= 1
            }
            return true
        }
        guard !wanted.isEmpty else { return }
        loadingQuote.formUnion(wanted.map(\.id))
        quoteTasks.append(Task { [weak self] in
            await withTaskGroup(of: (String, Asset?).self) { group in
                for hit in wanted {
                    group.addTask { @MainActor in (hit.id, await Self.fetchQuote(for: hit)) }
                }
                for await (id, asset) in group {
                    guard let self else { return }
                    self.loadingQuote.remove(id)
                    if let asset, asset.price > 0 {
                        self.quotes[id] = asset
                    } else if !Task.isCancelled {
                        self.quoteFailed.insert(id)
                    }
                }
            }
        })
    }

    /// A quote for one hit, or nil. Prices come back in USD (the app's storage currency).
    func quote(for hit: SymbolHit) async -> Asset? {
        if let cached = quotes[hit.id] { return cached }
        loadingQuote.insert(hit.id)
        defer { loadingQuote.remove(hit.id) }
        let asset = await Self.fetchQuote(for: hit)
        if let asset, asset.price > 0 { quotes[hit.id] = asset }
        return asset
    }

    static func fetchQuote(for hit: SymbolHit) async -> Asset? {
        do {
            let quote: Asset
            switch hit.market {
            case .crypto:
                guard !hit.coinID.isEmpty else { return nil }
                quote = try await APIService.shared.fetchCryptoPrice(id: hit.coinID)
            case .asx:
                quote = try await APIService.shared.fetchYahooQuote(symbol: "\(hit.symbol).AX", name: hit.name)
            case .intl:
                quote = try await APIService.shared.fetchYahooQuote(symbol: hit.symbol, name: hit.name)
            case .us:
                quote = try await APIService.shared.fetchStockQuote(symbol: hit.symbol)
            }
            // Keep the listing's own identity (name, exchange, display symbol).
            return Asset(symbol: hit.symbol, name: hit.name, price: quote.price, change: quote.change,
                         changePercent: quote.changePercent, volume: quote.volume, kind: hit.kind,
                         marketCap: quote.marketCap, week52High: quote.week52High, week52Low: quote.week52Low,
                         exchange: hit.kind == .crypto ? "" : hit.exchange, isETF: quote.isETF ?? hit.isETF)
        } catch {
            return nil
        }
    }
}

// MARK: - Watchlist membership

@MainActor
enum WatchlistMembership {
    enum Outcome { case added, removed, limitReached, conflict }

    static func asset(for hit: SymbolHit, in marketData: MarketData) -> Asset? {
        marketData.watchlist.first { hit.matches($0) }
    }

    /// Adds `hit` (with its quote if we have one) or removes it if it's already there.
    static func toggle(_ hit: SymbolHit, quote: Asset?, marketData: MarketData,
                       tier: SubscriptionTier) -> Outcome {
        if let existing = asset(for: hit, in: marketData) {
            marketData.removeFromWatchlist(existing)
            return .removed
        }
        let candidate = quote ?? hit.placeholderAsset()
        if marketData.isOnWatchlist(candidate) {
            return .conflict
        }
        if let limit = tier.maxWatchlistAssets, marketData.watchlist.count >= limit {
            return .limitReached
        }
        marketData.addToWatchlist(candidate)
        return .added
    }
}

// MARK: - Search view (used inside a NavigationStack)

struct SymbolSearchView: View {
    enum Mode { case browse, add }

    let mode: Mode
    @ObservedObject var model: SymbolSearchModel

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.theme) private var theme
    @ObservedObject private var recents = RecentSymbolStore.shared

    @State private var detailAsset: Asset?
    @State private var showLimitPaywall = false
    @State private var notice: String?

    private var listName: String {
        let i = marketData.activeWatchlistIndex
        return marketData.watchlistGroups.indices.contains(i) ? marketData.watchlistGroups[i].name : "your watchlist"
    }

    var body: some View {
        ZStack {
            content.transition(.opacity)
        }
        .motionSafeAnimation(DS.quick, value: model.phase)
        .dsScreenBackground()
        .searchable(text: $model.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: mode == .add ? "Add a stock, ETF or crypto" : "Stocks, ETFs and crypto")
        .searchScopes($model.scope, activation: .onSearchPresentation) {
            ForEach(SymbolSearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .sheet(item: $detailAsset) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
        .sheet(isPresented: $showLimitPaywall) {
            PaywallView(requiredTier: .pro, featureName: "More watchlist items")
                .environmentObject(subscriptionManager)
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.invertedPrimaryText)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
                    .background(Capsule().fill(theme.primaryText))
                    .padding(.bottom, DS.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("search.notice")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleList
        case .searching where model.allHits.isEmpty:
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in SearchRowSkeleton() }
                }
                .dsCard(padding: 0)
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.m)
                .loadingSkeleton("Searching for assets")
                .accessibilityIdentifier("search.searching")
            }
            .scrollDismissesKeyboard(.immediately)
        case .failed:
            stateMessage(icon: "wifi.exclamationmark",
                         title: "Search isn't available right now",
                         message: "Check your connection and try again.",
                         id: "search.failed",
                         action: ("Try again", { model.retry() }))
        case .empty:
            stateMessage(icon: "magnifyingglass",
                         title: "No matches for “\(model.query.trimmingCharacters(in: .whitespaces))”",
                         message: "Try a ticker like BHP or AAPL, or a company or coin name.",
                         id: "search.noResults")
        default:
            resultsList
        }
    }

    // MARK: Idle: recents + popular

    private var idleList: some View {
        List {
            if !recents.items.isEmpty {
                Section {
                    ForEach(recents.items) { hit in
                        row(hit, identifierPrefix: "search.recent")
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button {
                            Haptics.tap()
                            dsAnimate { recents.clear() }
                        } label: {
                            Text("Clear")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(DS.accent)
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.recents.clear")
                    }
                }
            }
            ForEach(popularSections) { section in
                Section(section.title) {
                    ForEach(section.hits) { hit in
                        row(hit, identifierPrefix: "search.popular")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private struct PopularSection: Identifiable {
        let title: String
        let hits: [SymbolHit]
        var id: String { title }
    }

    private var popularSections: [PopularSection] {
        let asx = PopularSection(title: "Popular on the ASX", hits: OnboardingCatalog.asx.prefix(5).map { SymbolHit(picked: $0) })
        let us = PopularSection(title: "Popular in the US", hits: OnboardingCatalog.us.prefix(5).map { SymbolHit(picked: $0) })
        let crypto = PopularSection(title: "Popular crypto", hits: OnboardingCatalog.crypto.prefix(4).map { SymbolHit(picked: $0) })
        let sections = Locale.current.region?.identifier == "AU" ? [asx, us, crypto] : [us, asx, crypto]
        return sections
            .map { PopularSection(title: $0.title, hits: $0.hits.filter(model.scope.includes)) }
            .filter { !$0.hits.isEmpty }
    }

    // MARK: Results

    private var resultsList: some View {
        List {
            Section {
                ForEach(model.hits) { hit in
                    row(hit, identifierPrefix: "search.result")
                }
            } header: {
                if model.phase == .searching {
                    Text("Searching…")
                } else if model.hits.isEmpty {
                    Text("No \(model.scope == .crypto ? "crypto" : model.scope == .asx ? "ASX" : "US") matches — try All")
                } else {
                    Text(model.hits.count == 1 ? "1 result" : "\(model.hits.count) results")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ hit: SymbolHit, identifierPrefix: String) -> some View {
        SymbolResultRow(
            hit: hit,
            quote: model.quotes[hit.id] ?? cachedAsset(for: hit),
            isLoadingQuote: model.loadingQuote.contains(hit.id),
            isInWatchlist: WatchlistMembership.asset(for: hit, in: marketData) != nil,
            listName: listName,
            rowIdentifier: "\(identifierPrefix).\(hit.market.rawValue).\(hit.symbol)",
            onOpen: { open(hit) },
            onToggle: { toggle(hit) }
        )
        .listRowBackground(theme.subtleFill)
    }

    /// A price we already track (watchlist, holdings, catalog) — used for idle rows.
    private func cachedAsset(for hit: SymbolHit) -> Asset? {
        let pools = marketData.watchlist + marketData.portfolio.map(\.asset) + marketData.stocks + marketData.crypto
        return pools.first { hit.matches($0) && $0.price > 0 }
    }

    // MARK: Actions

    private func open(_ hit: SymbolHit) {
        if mode == .add {
            toggle(hit)
            return
        }
        recents.record(hit)
        Task {
            if let cached = cachedAsset(for: hit) {
                detailAsset = cached
            } else {
                let fetched = await model.quote(for: hit)
                detailAsset = fetched ?? hit.placeholderAsset()
            }
        }
    }

    private func toggle(_ hit: SymbolHit) {
        let outcome = WatchlistMembership.toggle(hit, quote: model.quotes[hit.id] ?? cachedAsset(for: hit),
                                                 marketData: marketData, tier: subscriptionManager.currentTier)
        switch outcome {
        case .added:
            Haptics.success()
            recents.record(hit)
            show("Added \(hit.symbol) to \(listName)")
        case .removed:
            Haptics.tap()
            show("Removed \(hit.symbol) from \(listName)")
        case .limitReached:
            Haptics.warning()
            showLimitPaywall = true
        case .conflict:
            Haptics.warning()
            show("\(hit.symbol) from another market is already on this list")
        }
    }

    private func show(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        dsAnimate { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if notice == text { dsAnimate { notice = nil } }
        }
    }

    // MARK: States

    private func stateMessage(icon: String, title: String, message: String?, id: String,
                              action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.0) {
                    Haptics.tap()
                    action.1()
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .frame(maxWidth: 220)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DS.Space.xxl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Result row

struct SymbolResultRow: View {
    let hit: SymbolHit
    let quote: Asset?
    let isLoadingQuote: Bool
    let isInWatchlist: Bool
    let listName: String
    let rowIdentifier: String
    let onOpen: () -> Void
    let onToggle: () -> Void

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Button(action: {
                Haptics.tap()
                onOpen()
            }) {
                AdaptiveQuoteRow {
                    HStack(spacing: DS.Space.m) {
                        TickerLogo(symbol: hit.symbol, kind: hit.kind, exchange: hit.market == .asx ? "ASX" : "", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(hit.symbol)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(theme.primaryText)
                                    .lineLimit(1)
                                SymbolExchangeBadge(text: hit.badge)
                            }
                            Text(hit.name)
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                } numbers: { stacked in
                    priceColumn(stacked: stacked)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.99))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier(rowIdentifier)

            Button(action: onToggle) {
                Image(systemName: isInWatchlist ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isInWatchlist ? DS.accent : theme.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .motionSafeAnimation(DS.quick, value: isInWatchlist)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(isInWatchlist ? "Remove \(hit.symbol) from \(listName)" : "Add \(hit.symbol) to \(listName)")
            .accessibilityIdentifier("\(rowIdentifier).toggle")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func priceColumn(stacked: Bool) -> some View {
        if let quote, quote.price > 0 {
            QuoteNumbers(price: marketData.formatPrice(quote.price), percent: quote.changePercent,
                         stacked: stacked, priceFont: .subheadline.weight(.semibold).monospacedDigit())
        } else if isLoadingQuote {
            QuoteNumbersSkeleton(stacked: stacked)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(hit.symbol), \(hit.name), \(hit.badge)"]
        if let quote, quote.price > 0 {
            parts.append(marketData.formatPrice(quote.price))
            parts.append(String(format: "%@ %.2f percent today", quote.changePercent >= 0 ? "up" : "down", abs(quote.changePercent)))
        }
        if isLoadingQuote && quote == nil { parts.append("loading price") }
        if isInWatchlist { parts.append("on \(listName)") }
        return parts.joined(separator: ", ")
    }
}

/// Small exchange label ("ASX", "NASDAQ", "Crypto").
struct SymbolExchangeBadge: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.secondaryText.opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }
}
