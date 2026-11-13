//
//  AppleStocksWatchlistView.swift
//  Stock Tracker
//
//  The Watchlist tab, after Apple Stocks / Yahoo Finance / Stake on Mobbin:
//  one card of rows (logo, ticker, name, today's sparkline against the previous
//  close, price, change), a title menu for switching and managing lists, sort,
//  native edit (multi-select delete + drag to reorder), swipe to remove or set
//  an alert, and honest empty / loading / "no live price" states.
//

import SwiftUI

// MARK: - Sort & filter

enum WatchlistSort: String, CaseIterable, Identifiable {
    case manual, biggestMove, gainers, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual:      return "My order"
        case .biggestMove: return "Biggest move today"
        case .gainers:     return "Today's change"
        case .name:        return "Name"
        }
    }

    var icon: String {
        switch self {
        case .manual:      return "hand.draw"
        case .biggestMove: return "arrow.up.arrow.down"
        case .gainers:     return "chart.line.uptrend.xyaxis"
        case .name:        return "textformat"
        }
    }
}

enum WatchlistFilter: String, CaseIterable, Identifiable {
    case all, stocks, crypto
    var id: String { rawValue }

    func includes(_ asset: Asset) -> Bool {
        switch self {
        case .all:    return true
        case .stocks: return asset.kind == .stock
        case .crypto: return asset.kind == .crypto
        }
    }
}

// MARK: - Watchlist

struct AppleStocksWatchlistView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var insightService: AIInsightService
    @EnvironmentObject var alertManager: PriceAlertManager
    @Environment(\.theme) private var theme

    @AppStorage("watchlist_sort") private var sortRaw: String = WatchlistSort.manual.rawValue
    @State private var filter: WatchlistFilter = .all
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()

    @State private var addScope: AddScope?
    @State private var showAlerts = false
    @State private var paywallFeature: PaywallFeature?
    @State private var detailAsset: Asset?
    @State private var alertAsset: Asset?
    @State private var portfolioAsset: Asset?

    @State private var naming: Naming?
    @State private var nameDraft = ""
    @State private var confirmDeleteList = false

    @State private var spotlightText: String?
    @State private var spotlightLoading = false

    private struct AddScope: Identifiable { let scope: SymbolSearchScope; var id: String { scope.rawValue } }
    private struct PaywallFeature: Identifiable { let name: String; var id: String { name } }
    private enum Naming { case create, rename }

    private var sort: WatchlistSort { WatchlistSort(rawValue: sortRaw) ?? .manual }
    private var isEditing: Bool { editMode.isEditing }

    private var listName: String {
        let i = marketData.activeWatchlistIndex
        return marketData.watchlistGroups.indices.contains(i) ? marketData.watchlistGroups[i].name : "Watchlist"
    }

    private var hasBothKinds: Bool {
        marketData.watchlist.contains { $0.kind == .stock } && marketData.watchlist.contains { $0.kind == .crypto }
    }

    private var visibleAssets: [Asset] {
        let filtered = marketData.watchlist.filter(filter.includes)
        guard !isEditing else { return filtered }
        switch sort {
        case .manual:      return filtered
        case .biggestMove: return filtered.sorted { abs($0.changePercent) > abs($1.changePercent) }
        case .gainers:     return filtered.sorted { $0.changePercent > $1.changePercent }
        case .name:        return filtered.sorted { $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending }
        }
    }

    private var followedMarkets: [StockExchangeMarket] {
        let stocks = marketData.watchlist.filter { $0.kind == .stock }
        var result: [StockExchangeMarket] = []
        if stocks.contains(where: { QuoteService.isASX($0) }) { result.append(.asx) }
        if stocks.contains(where: { !QuoteService.isASX($0) }) { result.append(.us) }
        return result
    }

    private var overLimitCount: Int {
        guard let limit = FeatureGate.maxWatchlistAssets(for: subscriptionManager.currentTier) else { return 0 }
        return max(0, marketData.watchlist.count - limit)
    }

    private var activeAlertCount: Int { alertManager.alerts.filter(\.isActive).count }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                headerSection

                if overLimitCount > 0 {
                    Section { overLimitBanner }
                        .listRowBackground(theme.warningColor.opacity(0.12))
                }

                if marketData.watchlist.isEmpty {
                    emptySection(
                        icon: "star",
                        title: "Add your first stock",
                        message: "Search US and ASX stocks, ETFs and crypto, then follow their prices and today's moves here.",
                        action: "Add symbols",
                        scope: .all
                    )
                } else if visibleAssets.isEmpty {
                    emptySection(
                        icon: filter == .crypto ? "bitcoinsign.circle" : "chart.line.uptrend.xyaxis",
                        title: filter == .crypto ? "No crypto on this list" : "No stocks on this list",
                        message: filter == .crypto ? "Add Bitcoin, Ethereum and more to track them 24/7."
                                                   : "Add US or ASX stocks and ETFs.",
                        action: filter == .crypto ? "Add crypto" : "Add stocks",
                        scope: filter == .crypto ? .crypto : .all
                    )
                } else {
                    rowsSection
                }

                if subscriptionManager.currentTier != .free && !marketData.watchlist.isEmpty && !isEditing {
                    Section {
                        watchlistSpotlightCard
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .environment(\.editMode, $editMode)
            .refreshable { await marketData.refreshFromAPI() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if isEditing { editBar.transition(.opacity) }
            }
            .onChange(of: marketData.activeWatchlistIndex) { _, _ in
                selection.removeAll()
                filter = .all
            }
            .onChange(of: hasBothKinds) { _, both in
                if !both { filter = .all }
            }
        }
        .sheet(item: $addScope) { item in
            AddSymbolsSheet(initialScope: item.scope)
                .environmentObject(marketData)
                .environmentObject(subscriptionManager)
        }
        .sheet(isPresented: $showAlerts) {
            PriceAlertsView()
                .environmentObject(marketData)
                .environmentObject(alertManager)
                .environmentObject(subscriptionManager)
        }
        .sheet(item: $detailAsset) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
        .sheet(item: $alertAsset) { asset in
            AddPriceAlertSheet(asset: asset)
                .environmentObject(marketData)
                .environmentObject(alertManager)
                .environmentObject(subscriptionManager)
        }
        .sheet(item: $portfolioAsset) { AddToPortfolioSheet(asset: $0) }
        .sheet(item: $paywallFeature) { feature in
            PaywallView(requiredTier: .pro, featureName: feature.name)
                .environmentObject(subscriptionManager)
        }
        .alert(naming == .rename ? "Rename list" : "New list", isPresented: Binding(
            get: { naming != nil },
            set: { if !$0 { naming = nil } }
        )) {
            TextField("Name", text: $nameDraft)
                .accessibilityIdentifier("watchlist.nameField")
            Button(naming == .rename ? "Save" : "Create") { commitName() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming == .rename ? "Give this list a new name." : "Lists keep different ideas apart, like “Dividends” or “Tech”.")
        }
        .confirmationDialog("Delete “\(listName)”?", isPresented: $confirmDeleteList, titleVisibility: .visible) {
            Button("Delete list", role: .destructive) {
                dsAnimate { marketData.deleteWatchlist(at: marketData.activeWatchlistIndex) }
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(marketData.watchlist.count) symbols on it will be removed from this list. Your other lists and holdings aren't affected.")
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    listMenu
                    Spacer(minLength: DS.Space.s)
                    if isEditing {
                        Button { endEditing() } label: {
                            Text("Done")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(DS.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("watchlist.done")
                    } else {
                        circleButton("bell", label: "Price alerts", id: "watchlist.alerts", badge: activeAlertCount) {
                            showAlerts = true
                        }
                        circleButton("plus", label: "Add symbols", id: "watchlist.add") {
                            addScope = AddScope(scope: filter == .crypto ? .crypto : .all)
                        }
                    }
                }

                if !followedMarkets.isEmpty {
                    MarketStatusView(markets: followedMarkets)
                }

                if !marketData.watchlist.isEmpty {
                    HStack(spacing: DS.Space.s) {
                        if hasBothKinds {
                            ForEach(WatchlistFilter.allCases) { f in filterChip(f) }
                        } else {
                            RefreshStatusBadge()
                        }
                        Spacer(minLength: 0)
                        if !isEditing {
                            sortMenu
                            Button { beginEditing() } label: {
                                Text("Edit")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DS.accent)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("watchlist.edit")
                        }
                    }
                }
            }
            .padding(.top, DS.Space.s)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.xs, bottom: 0, trailing: DS.Space.xs))
        .selectionDisabled()
    }

    private var listMenu: some View {
        Menu {
            Section("Lists") {
                ForEach(Array(marketData.watchlistGroups.enumerated()), id: \.element.id) { index, group in
                    Button {
                        Haptics.select()
                        dsAnimate { marketData.switchToWatchlist(index: index) }
                        Task { await marketData.refreshFromAPI() }
                    } label: {
                        if index == marketData.activeWatchlistIndex {
                            Label("\(group.name) · \(group.assets.count)", systemImage: "checkmark")
                        } else {
                            Text("\(group.name) · \(group.assets.count)")
                        }
                    }
                }
            }
            Button("New list…", systemImage: "plus") { startCreate() }
            Button("Rename “\(listName)”…", systemImage: "pencil") {
                nameDraft = listName
                naming = .rename
            }
            if marketData.watchlistGroups.count > 1 {
                Button("Delete “\(listName)”…", systemImage: "trash", role: .destructive) {
                    confirmDeleteList = true
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(listName)
                    .font(DS.display(.title))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(listName), list menu")
        .accessibilityHint("Switch, create, rename or delete lists")
        .accessibilityIdentifier("watchlist.listMenu")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortRaw) {
                ForEach(WatchlistSort.allCases) { option in
                    Label(option.title, systemImage: option.icon).tag(option.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(sort == .manual ? theme.secondaryText : DS.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort, \(sort.title)")
        .accessibilityIdentifier("watchlist.sort")
    }

    private func filterChip(_ f: WatchlistFilter) -> some View {
        let isOn = f == filter
        let count = marketData.watchlist.filter(f.includes).count
        let title: String = {
            switch f {
            case .all: return "All"
            case .stocks: return "Stocks"
            case .crypto: return "Crypto"
            }
        }()
        return Button {
            Haptics.select()
            dsAnimate(DS.quick) { filter = f }
        } label: {
            Text("\(title) \(count)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOn ? theme.invertedPrimaryText : theme.primaryText)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 34)
                .background(Capsule().fill(isOn ? theme.primaryText : theme.subtleFill))
                .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(isOn ? 0 : 0.6), lineWidth: 0.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("watchlist.filter.\(f.rawValue)")
    }

    private func circleButton(_ icon: String, label: String, id: String, badge: Int = 0,
                              action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.subtleFill))
                .overlay(Circle().strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(DS.accent))
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(badge > 0 ? "\(label), \(badge) active" : label)
        .accessibilityIdentifier(id)
    }

    // MARK: Rows

    private var rowsSection: some View {
        let mover: ((IndexSet, Int) -> Void)? = isEditing ? { move(from: $0, to: $1) } : nil
        return Section {
            ForEach(visibleAssets) { asset in
                watchRow(asset)
            }
            .onMove(perform: mover)
        } header: {
            summaryHeader
        }
    }

    private func watchRow(_ asset: Asset) -> some View {
        Group {
            if isEditing {
                // No button in edit mode, so a tap selects the row.
                WatchlistRow(asset: asset, isEditing: true)
            } else {
                Button {
                    Haptics.tap()
                    detailAsset = asset
                } label: {
                    WatchlistRow(asset: asset)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(theme.subtleFill)
        .accessibilityIdentifier("watchlist.row.\(asset.symbol)")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { remove(asset) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { alertAsset = asset } label: {
                Label("Alert", systemImage: "bell")
            }
            .tint(DS.accent)
        }
        .contextMenu { rowMenu(asset) }
    }

    @ViewBuilder
    private func rowMenu(_ asset: Asset) -> some View {
        Button { alertAsset = asset } label: { Label("Set price alert", systemImage: "bell") }
        Button { portfolioAsset = asset } label: { Label("Add to portfolio", systemImage: "briefcase") }
        ShareLink(item: shareText(for: asset)) { Label("Share", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { remove(asset) } label: { Label("Remove from \(listName)", systemImage: "trash") }
    }

    private var summaryHeader: some View {
        let loaded = visibleAssets.filter { $0.price > 0 }
        let up = loaded.filter { $0.changePercent >= 0.005 }.count
        let down = loaded.filter { $0.changePercent <= -0.005 }.count
        // One Text, so at large sizes it wraps like a sentence instead of in fragments.
        let count = visibleAssets.count == 1 ? "1 symbol" : "\(visibleAssets.count) symbols"
        // Non-breaking spaces keep "3 up" and "2 down today" whole ("3 up 2 / down today" before).
        let upText = Text("\(up)\u{00A0}up").foregroundStyle(up > 0 ? theme.positiveColor : theme.secondaryText)
        let downText = Text("\(down)\u{00A0}down").foregroundStyle(down > 0 ? theme.negativeColor : theme.secondaryText)
        let summary = loaded.isEmpty ? Text(count) : Text("\(count) · \(upText) · \(downText)\u{00A0}today")
        return HStack(spacing: DS.Space.s) {
            summary
            Spacer()
            if hasBothKinds { RefreshStatusBadge() }
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .foregroundStyle(theme.secondaryText)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watchlist.summary")
    }

    private func emptySection(icon: String, title: LocalizedStringKey, message: LocalizedStringKey,
                              action: LocalizedStringKey, scope: SymbolSearchScope) -> some View {
        Section {
            EmptyStateCard(
                systemImage: icon,
                title: title,
                message: message,
                primaryTitle: action,
                primaryAction: { addScope = AddScope(scope: scope) }
            )
            .accessibilityIdentifier("watchlist.empty")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: DS.Space.s, leading: 0, bottom: DS.Space.s, trailing: 0))
        .selectionDisabled()
    }

    private var overLimitBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warningColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(overLimitCount) over your plan's limit")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text("Remove some, or upgrade to keep them all updating.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button { paywallFeature = PaywallFeature(name: "More watchlist items") } label: {
                Text("Upgrade")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .selectionDisabled()
    }

    private var editBar: some View {
        HStack {
            Button(role: .destructive) {
                let count = selection.count
                dsAnimate { marketData.removeMultipleFromWatchlist(selection) }
                selection.removeAll()
                Haptics.success()
                AccessibilityNotification.Announcement("Removed \(count)").post()
            } label: {
                Text(selection.isEmpty ? "Select to remove" : "Remove \(selection.count)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selection.isEmpty ? theme.secondaryText : theme.negativeColor)
                    .frame(minHeight: 44)
            }
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("watchlist.deleteSelected")
            Spacer()
            Text("Drag ≡ to reorder")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, DS.Space.s)
        .background(.bar)
    }

    // MARK: Actions

    private func beginEditing() {
        Haptics.tap()
        selection.removeAll()
        dsAnimate { editMode = .active }
    }

    private func endEditing() {
        Haptics.tap()
        selection.removeAll()
        dsAnimate { editMode = .inactive }
    }

    private func remove(_ asset: Asset) {
        Haptics.tap()
        dsAnimate { marketData.removeFromWatchlist(asset) }
        AccessibilityNotification.Announcement("Removed \(asset.symbol)").post()
    }

    /// Moves within the filtered rows map back to positions in the full list.
    private func move(from source: IndexSet, to destination: Int) {
        let shown = marketData.watchlist.enumerated().filter { filter.includes($0.element) }
        let sourceIndices = IndexSet(source.compactMap { shown.indices.contains($0) ? shown[$0].offset : nil })
        let target: Int = destination < shown.count
            ? shown[destination].offset
            : (shown.last?.offset ?? marketData.watchlist.count - 1) + 1
        marketData.moveWatchlistItem(from: sourceIndices, to: target)
        if sort != .manual { sortRaw = WatchlistSort.manual.rawValue }
        Haptics.select()
    }

    private func startCreate() {
        let tier = subscriptionManager.currentTier
        if let limit = tier.watchlistLimit, marketData.watchlistGroups.count >= limit {
            paywallFeature = PaywallFeature(name: "Multiple watchlists")
        } else {
            nameDraft = ""
            naming = .create
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { naming = nil }
        guard !trimmed.isEmpty else { return }
        switch naming {
        case .create:
            dsAnimate { marketData.createWatchlist(name: trimmed) }
            filter = .all
        case .rename:
            marketData.renameWatchlist(at: marketData.activeWatchlistIndex, to: trimmed)
        case .none:
            break
        }
        Haptics.success()
    }

    private func shareText(for asset: Asset) -> String {
        guard asset.price > 0 else { return "\(asset.symbol) — \(asset.name)" }
        return "\(asset.symbol) (\(asset.name)) is \(marketData.formatPrice(asset.price)), "
            + String(format: "%@%.2f%% today.", asset.changePercent >= 0 ? "+" : "−", abs(asset.changePercent))
    }

    // MARK: AI spotlight (Pro / Black)

    private var watchlistSpotlightCard: some View {
        let tier = subscriptionManager.currentTier
        let cacheKey = "watchlist_spotlight_\(insightService.todayString)"
        return AIInsightCard(
            title: "Market Spotlight",
            icon: "sparkles",
            insightText: insightService.cached(cacheKey)?.text ?? spotlightText,
            isLoading: spotlightLoading,
            isLocked: tier == .free,
            tier: tier,
            onGenerate: { await loadWatchlistSpotlight() },
            onRegenerate: { await loadWatchlistSpotlight(force: true) }
        )
    }

    private func loadWatchlistSpotlight(force: Bool = false) async {
        let movers = marketData.watchlist
            .filter { $0.price > 0 }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(3)
        guard !movers.isEmpty else { return }
        spotlightLoading = true
        defer { spotlightLoading = false }

        let tier = subscriptionManager.currentTier
        let cacheKey = "watchlist_spotlight_\(insightService.todayString)"
        let moverDetails = movers.map { a in
            var detail = "\(a.symbol): \(marketData.formatPrice(a.price)) (\(String(format: "%+.1f%%", a.changePercent)))"
            if let pe = a.peRatio, pe > 0 { detail += ", P/E \(String(format: "%.1f", pe))" }
            if a.volume > 0, let avg = a.avgVolume, avg > 0, a.volume / avg > 1.5 {
                detail += ", vol \(String(format: "%.1fx", a.volume / avg)) avg"
            }
            return detail
        }.joined(separator: ". ")

        let systemPrompt = "For each stock, write ONE sentence about what's notable today. Be factual. Format: SYMBOL: sentence."
        let userPrompt = "Top movers on my watchlist: \(moverDetails). Give a brief 1-sentence insight for each."
        let result = force
            ? await insightService.regenerateInsight(key: cacheKey, type: .watchlistSpotlight,
                                                     systemPrompt: systemPrompt, userPrompt: userPrompt,
                                                     tier: tier, ttl: Constants.AI.dailyCacheTTL)
            : await insightService.generateInsight(key: cacheKey, type: .watchlistSpotlight,
                                                   systemPrompt: systemPrompt, userPrompt: userPrompt,
                                                   tier: tier, ttl: Constants.AI.dailyCacheTTL)
        if let result { spotlightText = result }
    }
}

// MARK: - Row

struct WatchlistRow: View {
    let asset: Asset
    /// In edit mode the selection circle and drag handle need the room: drop the sparkline.
    var isEditing = false
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @State private var series: MiniSeries?

    private var isLoaded: Bool { asset.price > 0 }
    private var hasNoQuote: Bool { !isLoaded && marketData.quoteFailures.contains(asset.symbol) }
    private var shownSeries: MiniSeries? { series ?? MiniSeriesStore.shared.cached(for: asset) }

    var body: some View {
        AdaptiveQuoteRow {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(asset.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        if asset.kind == .stock && QuoteService.isASX(asset) {
                            SymbolExchangeBadge(text: "ASX")
                        }
                    }
                    Text(asset.name)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        } numbers: { stacked in
            HStack(spacing: DS.Space.m) {
                if !isEditing && !stacked {
                    DSSparkline(values: shownSeries?.values ?? [], baseline: shownSeries?.baseline)
                        .frame(width: 52, height: 26)
                }
                priceColumn(stacked: stacked)
                    .frame(minWidth: isEditing || stacked ? 0 : 86, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .task(id: asset.price) {
            guard isLoaded else { return }
            if let fresh = await MiniSeriesStore.shared.series(for: asset) { series = fresh }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens details")
    }

    @ViewBuilder
    private func priceColumn(stacked: Bool) -> some View {
        if hasNoQuote {
            Text("No live price")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
        } else if isLoaded {
            QuoteNumbers(price: marketData.formatPrice(asset.price),
                         percent: asset.changePercent, stacked: stacked)
                .priceFlash(value: asset.price)
        } else {
            QuoteNumbersSkeleton(stacked: stacked)
        }
    }

    private var accessibilityText: String {
        var parts = [asset.symbol, asset.name]
        if isLoaded {
            parts.append(marketData.formatPrice(asset.price))
            let pct = abs(asset.changePercent)
            parts.append(pct < 0.005 ? "unchanged today"
                         : String(format: "%@ %.2f percent today", asset.changePercent >= 0 ? "up" : "down", pct))
        } else {
            parts.append(hasNoQuote ? "no live price" : "loading price")
        }
        return parts.joined(separator: ", ")
    }
}

/// Today's sparkline per symbol, so rows don't refetch (or flash) as they scroll.
@MainActor
final class MiniSeriesStore {
    static let shared = MiniSeriesStore()
    private var entries: [String: (series: MiniSeries, price: Double, at: Date)] = [:]

    private func key(_ asset: Asset) -> String { "\(asset.kind.rawValue):\(asset.exchange):\(asset.symbol)" }

    func cached(for asset: Asset) -> MiniSeries? { entries[key(asset)]?.series }

    /// Cached while fresh (same price, under 2 minutes old); otherwise refetched.
    func series(for asset: Asset) async -> MiniSeries? {
        let k = key(asset)
        if let e = entries[k], e.price == asset.price, Date().timeIntervalSince(e.at) < 120 {
            return e.series
        }
        guard let fresh = await PriceHistoryService.shared.miniSeries(for: asset) else {
            return entries[k]?.series
        }
        entries[k] = (fresh, asset.price, Date())
        return fresh
    }
}

// MARK: - Shared helpers kept for other screens


/// Seeds the detail screen from a quote until the live profile loads.
func detailedStock(from asset: Asset) -> DetailedStock {
    let price = asset.price
    let changePercent = asset.changePercent
    let changeAmount = price * (changePercent / 100.0)
    let previousClose = price - changeAmount

    // Only what we actually know. Unknown numbers are 0 / nil and render as "—";
    // the detail view fills them in when the live profile loads. Never invent
    // market data — it would be shown (and fed to AI analysis) as if real.
    let exchange = asset.kind == .crypto ? "Crypto" : (asset.exchange.isEmpty ? "—" : asset.exchange)
    let marketCap: Double = asset.marketCap ?? 0
    let volume = Int(asset.volume)
    let avgVolume = Int(asset.avgVolume ?? 0)
    let sharesOutstanding: Double = 0
    let week52High = asset.week52High ?? 0
    let week52Low = asset.week52Low ?? 0
    let beta: Double? = asset.beta
    let dividendYield: Double? = asset.dividend.map { $0 / 100 }   // Asset stores percent; DetailedStock a fraction

    return DetailedStock(
        symbol: asset.symbol,
        name: asset.name,
        exchange: exchange,
        currentPrice: price,
        dayChange: changeAmount,
        dayChangePercent: changePercent,
        preMarketPrice: nil,
        afterHoursPrice: nil,
        previousClose: previousClose,
        marketCap: marketCap,
        enterpriseValue: nil,
        volume: volume,
        avgVolume: avgVolume,
        float: nil,
        sharesOutstanding: sharesOutstanding,
        peRatio: nil,
        forwardPE: nil,
        pegRatio: nil,
        priceToBook: nil,
        priceToSales: nil,
        revenue: nil,
        grossMargin: nil,
        operatingMargin: nil,
        profitMargin: nil,
        freeCashFlow: nil,
        debtToEquity: nil,
        revenueGrowthYoY: nil,
        earningsGrowthYoY: nil,
        epsGrowth: nil,
        dividendYield: dividendYield,
        annualDividend: nil,
        payoutRatio: nil,
        beta: beta,
        week52High: week52High,
        week52Low: week52Low,
        shortInterest: nil
    )
}

//
//  MockStockData.swift
//  Stock Tracker
//

import Foundation

extension DetailedStock {
    static var applePreview: DetailedStock {
        DetailedStock(
            symbol: "AAPL",
            name: "Apple Inc.",
            exchange: "NASDAQ",

            // Price & Performance
            currentPrice: 178.72,
            dayChange: 2.34,
            dayChangePercent: 1.33,
            preMarketPrice: 178.90,
            afterHoursPrice: nil,
            previousClose: 176.38,

            // Market Stats
            marketCap: 2_780_000_000_000,
            enterpriseValue: 2_850_000_000_000,
            volume: 52_840_000,
            avgVolume: 58_200_000,
            float: 15_400_000_000,
            sharesOutstanding: 15_550_000_000,

            // Valuation
            peRatio: 29.42,
            forwardPE: 26.78,
            pegRatio: 2.34,
            priceToBook: 45.67,
            priceToSales: 7.23,

            // Financial Health
            revenue: 383_285_000_000,
            grossMargin: 0.434,
            operatingMargin: 0.298,
            profitMargin: 0.256,
            freeCashFlow: 99_584_000_000,
            debtToEquity: 1.78,

            // Growth
            revenueGrowthYoY: 0.029,
            earningsGrowthYoY: 0.134,
            epsGrowth: 0.162,

            // Dividends
            dividendYield: 0.0048,
            annualDividend: 0.96,
            payoutRatio: 0.148,

            // Risk
            beta: 1.24,
            week52High: 199.62,
            week52Low: 164.08,
            shortInterest: 0.068
        )
    }

    static var teslaPreview: DetailedStock {
        DetailedStock(
            symbol: "TSLA",
            name: "Tesla, Inc.",
            exchange: "NASDAQ",

            // Price & Performance
            currentPrice: 242.84,
            dayChange: -3.67,
            dayChangePercent: -1.49,
            preMarketPrice: nil,
            afterHoursPrice: 243.12,
            previousClose: 246.51,

            // Market Stats
            marketCap: 771_000_000_000,
            enterpriseValue: 780_000_000_000,
            volume: 98_450_000,
            avgVolume: 102_300_000,
            float: 2_890_000_000,
            sharesOutstanding: 3_175_000_000,

            // Valuation
            peRatio: 76.34,
            forwardPE: 62.18,
            pegRatio: 3.87,
            priceToBook: 12.45,
            priceToSales: 8.12,

            // Financial Health
            revenue: 96_773_000_000,
            grossMargin: 0.187,
            operatingMargin: 0.096,
            profitMargin: 0.153,
            freeCashFlow: 4_443_000_000,
            debtToEquity: 0.37,

            // Growth
            revenueGrowthYoY: 0.189,
            earningsGrowthYoY: 0.234,
            epsGrowth: 0.287,

            // Dividends
            dividendYield: nil,
            annualDividend: nil,
            payoutRatio: nil,

            // Risk
            beta: 2.18,
            week52High: 299.29,
            week52Low: 138.80,
            shortInterest: 0.032
        )
    }
}

extension StockPosition {
    static var applePosition: StockPosition {
        StockPosition(
            symbol: "AAPL",
            shares: 50.0,
            avgCost: 165.40
        )
    }

    static var teslaPosition: StockPosition {
        StockPosition(
            symbol: "TSLA",
            shares: 25.0,
            avgCost: 220.50
        )
    }
}
