//
//  AppleStocksWatchlistView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct AppleStocksWatchlistView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var filter: AssetKind = .stock
    @State private var selectedAsset: Asset?
    @State private var showSearchSheet = false
    @State private var showAlerts = false
    @State private var assetToAddToPortfolio: Asset?
    @State private var showPortfolioPaywall = false
    @State private var showCreateWatchlist = false
    @State private var showWatchlistPaywall = false
    @State private var showWatchlistDropdown = false
    @EnvironmentObject var insightService: AIInsightService
    @State private var spotlightText: String?
    @State private var spotlightLoading = false
    @State private var isEditing = false
    @State private var selectedForDeletion: Set<UUID> = []

    private var activeWatchlistName: String {
        let idx = marketData.activeWatchlistIndex
        guard marketData.watchlistGroups.indices.contains(idx) else { return "Watchlist" }
        return marketData.watchlistGroups[idx].name
    }

    private var topMovers: [Asset] {
        marketData.watchlist
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(5)
            .map { $0 }
    }

    private var filteredAssets: [Asset] {
        marketData.watchlist.filter { $0.kind == filter }
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack(alignment: .top) {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerView
                            .padding(.horizontal)

                        WatchlistStatsCard()
                            .padding(.horizontal)

                        // AI Watchlist Spotlight (Pro/Black only)
                        if subscriptionManager.currentTier != .free {
                            watchlistSpotlightCard
                                .padding(.horizontal)
                        }

                        if !topMovers.isEmpty {
                            TopMoversSection(movers: Array(topMovers))
                                .padding(.horizontal)
                        }

                        Picker("Asset Type", selection: $filter) {
                            Text("Stocks").tag(AssetKind.stock)
                            Text("Crypto").tag(AssetKind.crypto)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        // Over-limit banner
                        if marketData.isOverWatchlistLimit {
                            overLimitBanner(theme: theme)
                                .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Your \(filter == .stock ? "Stocks" : "Crypto")")
                                    .font(.title2.bold())
                                    .foregroundColor(theme.primaryText)
                                Spacer()

                                if isEditing && !selectedForDeletion.isEmpty {
                                    Button {
                                        motionSafeWithAnimation {
                                            marketData.removeMultipleFromWatchlist(selectedForDeletion)
                                        }
                                        selectedForDeletion.removeAll()
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    } label: {
                                        Text("Delete (\(selectedForDeletion.count))")
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.red)
                                            .clipShape(Capsule())
                                    }
                                }

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isEditing.toggle()
                                        if !isEditing { selectedForDeletion.removeAll() }
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    Text(isEditing ? "Done" : "Edit")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal)

                            if filteredAssets.isEmpty {
                                EmptyWatchlistCard(kind: filter)
                            } else if isEditing {
                                // Edit mode: checkboxes + drag reorder
                                List {
                                    ForEach(marketData.watchlist.filter { $0.kind == filter }) { asset in
                                        HStack(spacing: 12) {
                                            Button {
                                                if selectedForDeletion.contains(asset.id) {
                                                    selectedForDeletion.remove(asset.id)
                                                } else {
                                                    selectedForDeletion.insert(asset.id)
                                                }
                                            } label: {
                                                Image(systemName: selectedForDeletion.contains(asset.id)
                                                    ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundColor(selectedForDeletion.contains(asset.id) ? .red : .secondary)
                                            }
                                            .buttonStyle(.plain)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(asset.symbol)
                                                    .font(.subheadline.weight(.semibold))
                                                Text(asset.name)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            Image(systemName: "line.3.horizontal")
                                                .foregroundColor(.secondary)
                                                .font(.subheadline)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .onMove { source, destination in
                                        // Map filtered indices back to the full watchlist
                                        let filtered = marketData.watchlist.enumerated().filter { $0.element.kind == filter }
                                        let sourceIndices = IndexSet(source.compactMap { filtered.indices.contains($0) ? filtered[$0].offset : nil })
                                        let destIndex: Int = {
                                            if destination < filtered.count {
                                                return filtered[destination].offset
                                            }
                                            return (filtered.last?.offset ?? marketData.watchlist.count - 1) + 1
                                        }()
                                        marketData.moveWatchlistItem(from: sourceIndices, to: destIndex)
                                    }
                                }
                                .listStyle(.plain)
                                .frame(minHeight: CGFloat(filteredAssets.count) * 56)
                                .environment(\.editMode, .constant(.active))
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(filteredAssets) { asset in
                                        EnhancedWatchlistRow(asset: asset)
                                            .id(asset.id)
                                            .accessibilityHint("Swipe left to add to portfolio, swipe right to remove")
                                            .onTapGesture {
                                                selectedAsset = asset
                                            }
                                            // LEFT SWIPE → Add to Portfolio (Pro only)
                                            .swipeActions(edge: .leading) {
                                                Button {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    if subscriptionManager.currentTier.hasPortfolioAccess {
                                                        assetToAddToPortfolio = asset
                                                    } else {
                                                        showPortfolioPaywall = true
                                                    }
                                                } label: {
                                                    Label("Portfolio", systemImage: "briefcase.fill")
                                                }
                                                .tint(.blue)
                                            }
                                            // RIGHT SWIPE → Remove
                                            .swipeActions(edge: .trailing) {
                                                Button(role: .destructive) {
                                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                    motionSafeWithAnimation {
                                                        marketData.removeFromWatchlist(asset)
                                                    }
                                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                                } label: {
                                                    Label("Remove", systemImage: "trash.fill")
                                                }
                                            }
                                            .contextMenu {
                                                Button {
                                                    if subscriptionManager.currentTier.hasPortfolioAccess {
                                                        assetToAddToPortfolio = asset
                                                    } else {
                                                        showPortfolioPaywall = true
                                                    }
                                                } label: {
                                                    Label("Add to Portfolio", systemImage: "briefcase")
                                                }

                                                Button {
                                                    shareAsset(asset)
                                                } label: {
                                                    Label("Share", systemImage: "square.and.arrow.up")
                                                }

                                                Divider()

                                                Button(role: .destructive) {
                                                    motionSafeWithAnimation {
                                                        marketData.removeFromWatchlist(asset)
                                                    }
                                                } label: {
                                                    Label("Remove", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }

                        Spacer(minLength: 120)
                    }
                    .padding(.top)
                }
                .refreshable { await marketData.refreshFromAPI() }

            }
            .navigationTitle("Watchlist")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showSearchSheet) { SearchSheet(kind: filter) }
            .sheet(isPresented: $showAlerts) { PriceAlertsView() }
            .sheet(item: $selectedAsset) { asset in
                AppleStocksDetailView(
                    stock: detailedStock(from: asset),
                    asset: asset,
                    position: nil
                )
            }
            .sheet(item: $assetToAddToPortfolio) { AddToPortfolioSheet(asset: $0) }
            .sheet(isPresented: $showPortfolioPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Portfolio Tracking")
                    .environmentObject(subscriptionManager)
            }
            .sheet(isPresented: $showCreateWatchlist) {
                CreateWatchlistSheet()
                    .environmentObject(marketData)
            }
            .sheet(isPresented: $showWatchlistPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Multiple Watchlists")
                    .environmentObject(subscriptionManager)
            }
            .alert("Rename Watchlist", isPresented: Binding(
                get: { renameTargetIndex != nil },
                set: { if !$0 { renameTargetIndex = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let i = renameTargetIndex {
                        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { marketData.renameWatchlist(at: i, to: trimmed) }
                    }
                    renameTargetIndex = nil
                }
                Button("Cancel", role: .cancel) { renameTargetIndex = nil }
            }
        }
    }

    private var headerView: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            // Top row: dropdown trigger + bell
            HStack(alignment: .center) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        showWatchlistDropdown.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        Text(activeWatchlistName)
                            .font(.title2.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(showWatchlistDropdown ? -180 : 0))
                            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: showWatchlistDropdown)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button { showAlerts = true } label: {
                    Image(systemName: "bell.fill")
                        .font(.title2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, Color(red: 1.0, green: 0.4, blue: 0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.18), Color(red: 1.0, green: 0.4, blue: 0.2).opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.orange.opacity(0.25), lineWidth: 1))
                }
            }

            // Inline expanding pills
            if showWatchlistDropdown {
                watchlistPillsRow
                    .padding(.top, 14)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }

            // Slogan — always visible, below the dropdown
            Text("Track your favourite assets")
                .font(.largeTitle.bold())
                .foregroundColor(theme.primaryText)
                .padding(.top, 4)

            RefreshStatusBadge()
                .padding(.top, 6)
        }
    }

    private var watchlistPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(marketData.watchlistGroups.enumerated()), id: \.1.id) { index, group in
                    let isActive = index == marketData.activeWatchlistIndex
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            marketData.switchToWatchlist(index: index)
                            showWatchlistDropdown = false
                        }
                    } label: {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(isActive ? .white : .secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(isActive ? appTheme.accentColor : (colorScheme == .dark ? Color(.systemGray5) : Color(red: 0.929, green: 0.910, blue: 0.878)))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            // Rename handled via alert on MarketData directly
                            renameWatchlistAlert(index: index, current: group.name)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        if marketData.watchlistGroups.count > 1 {
                            Button(role: .destructive) {
                                withAnimation { marketData.deleteWatchlist(at: index) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                // New watchlist pill
                Button {
                    showWatchlistDropdown = false
                    let tier = subscriptionManager.currentTier
                    if let limit = tier.watchlistLimit, marketData.watchlistGroups.count >= limit {
                        showWatchlistPaywall = true
                    } else if !tier.canAddWatchlist {
                        showWatchlistPaywall = true
                    } else {
                        showCreateWatchlist = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("New")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(colorScheme == .dark ? Color(.systemGray5) : Color(red: 0.929, green: 0.910, blue: 0.878))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @State private var renameTargetIndex: Int? = nil
    @State private var renameText = ""
    private func renameWatchlistAlert(index: Int, current: String) {
        renameTargetIndex = index
        renameText = current
    }

    private func shareAsset(_ asset: Asset) {
        let text = "\(asset.symbol) is at \(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))! 📈"
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(activityVC, animated: true)
    }

    // MARK: - Over-Limit Banner

    @ViewBuilder
    private func overLimitBanner(theme: Theme) -> some View {
        let overCount = marketData.watchlist.count - (FeatureGate.maxWatchlistAssets(for: subscriptionManager.currentTier) ?? Int.max)
        if overCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(overCount) item\(overCount == 1 ? "" : "s") over your plan limit")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Remove items or upgrade your plan.")
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button("Upgrade") {
                    showPortfolioPaywall = true
                }
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .cornerRadius(8)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
        }
    }

    // MARK: - AI Watchlist Spotlight

    private var watchlistSpotlightCard: some View {
        let tier = subscriptionManager.currentTier
        let isLocked = tier == .free
        let cacheKey = "watchlist_spotlight_\(insightService.todayString)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? spotlightText
        return AIInsightCard(
            title: "Market Spotlight",
            icon: "sparkles",
            insightText: cachedText,
            isLoading: spotlightLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadWatchlistSpotlight() },
            onRegenerate: { await loadWatchlistSpotlight(force: true) }
        )
    }

    private func loadWatchlistSpotlight(force: Bool = false) async {
        guard !marketData.watchlist.isEmpty else { return }
        spotlightLoading = true
        defer { spotlightLoading = false }

        let tier = subscriptionManager.currentTier
        let cacheKey = "watchlist_spotlight_\(insightService.todayString)"

        let movers = marketData.watchlist
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(3)

        let moverDetails = movers.map { a in
            var detail = "\(a.symbol): \(String(format: "$%.2f", a.price)) (\(String(format: "%+.1f%%", a.changePercent)))"
            if let pe = a.peRatio, pe > 0 { detail += ", P/E \(String(format: "%.1f", pe))" }
            if a.volume > 0 && a.avgVolume ?? 0 > 0 {
                let volRatio = a.volume / (a.avgVolume ?? 1)
                if volRatio > 1.5 { detail += ", vol \(String(format: "%.1fx", volRatio)) avg" }
            }
            return detail
        }.joined(separator: ". ")

        let systemPrompt = "For each stock, write ONE sentence about what's notable today. Be factual. Format: SYMBOL: sentence."
        let userPrompt = "Top movers on my watchlist: \(moverDetails). Give a brief 1-sentence insight for each."

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .watchlistSpotlight,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .watchlistSpotlight,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { spotlightText = text }
    }
}


// MARK: - Top Movers Section
struct TopMoversSection: View {
    let movers: [Asset]
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Movers")
                .font(.title2.bold())
                .foregroundColor(theme.primaryText)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(movers) { asset in
                        TopMoverCard(asset: asset)
                            .frame(width: 210)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct TopMoverCard: View {
    let asset: Asset
    @State private var isLoading = true
    @State private var miniHistory: [PricePoint] = []
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var lineColor: Color { asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isLoading {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 80, height: 12)
                            .cornerRadius(4)
                            .shimmering()

                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 120, height: 16)
                            .cornerRadius(6)
                            .shimmering()
                    } else {
                        Text(asset.symbol)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(asset.name)
                            .font(.subheadline.bold())
                            .foregroundColor(theme.primaryText)
                    }
                }
                Spacer()
                Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                    .foregroundColor(lineColor)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if isLoading {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 100, height: 28)
                        .cornerRadius(8)
                        .shimmering()

                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 60, height: 20)
                        .cornerRadius(6)
                        .shimmering()
                } else {
                    Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.title2.bold())
                        .foregroundColor(theme.primaryText)

                    Text("\(asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f%%", asset.changePercent))")
                        .font(.title3.bold())
                        .foregroundColor(lineColor)
                }
            }

            if isLoading {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 60)
                    .shimmering()
            } else {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let prices = miniHistory.map(\.price)

                    if prices.count >= 2 {
                        let minP = prices.min()!
                        let maxP = prices.max()!
                        let range = max(maxP - minP, maxP * 0.001)
                        let step = w / CGFloat(prices.count - 1)

                        Path { path in
                            for (i, price) in prices.enumerated() {
                                let x = CGFloat(i) * step
                                let normalized = CGFloat((price - minP) / range)
                                let y = h - (normalized * h * 0.85 + h * 0.075)
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: colorScheme == .dark ? lineColor.opacity(0.6) : lineColor.opacity(0.04), radius: 8)
                        .shadow(color: colorScheme == .dark ? lineColor.opacity(0.4) : Color.clear, radius: 16)
                    }
                }
                .frame(height: 60)
            }
        }
        .padding(20)
        .frame(height: 170)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(lineColor.opacity(0.4), lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
        .task {
            let points = await marketData.fetchMiniChartHistory(for: asset)
            miniHistory = points
            motionSafeWithAnimation(.easeInOut) {
                isLoading = false
            }
        }
    }
}

// MARK: - Watchlist Stats Card with Skeleton
struct WatchlistStatsCard: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @State private var isLoading = true

    private var totalValue: Double {
        marketData.watchlist.reduce(0) { $0 + $1.price }
    }

    private var gainers: Int {
        marketData.watchlist.filter { $0.changePercent > 0 }.count
    }

    private var losers: Int {
        marketData.watchlist.filter { $0.changePercent < 0 }.count
    }

    private var totalAssets: Int {
        marketData.watchlist.count
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Total Assets Card
                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 120, height: 14).cornerRadius(4).shimmering()
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 80, height: 32).cornerRadius(8).shimmering()
                    } else {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            Text("Total Assets")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                        Text("\(totalAssets)")
                            .font(.title.bold())
                            .foregroundColor(theme.primaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(theme.glassBackground))

                // Gainers/Losers
                VStack(spacing: 12) {
                    if isLoading {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 60).cornerRadius(12).shimmering()
                        Divider().background(Color.gray.opacity(0.2))
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 40).cornerRadius(12).shimmering()
                    } else {
                        // Existing gainers/losers content...
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(appTheme.positiveColor)
                                    Text("Gainers")
                                        .font(.caption2)
                                        .foregroundColor(appTheme.positiveColor.opacity(0.8))
                                }
                                Text("\(gainers)")
                                    .font(.title2.bold())
                                    .foregroundColor(appTheme.positiveColor)
                            }
                            Spacer()
                            ZStack {
                                Circle().stroke(appTheme.negativeColor.opacity(0.3), lineWidth: 6)
                                Circle()
                                    .trim(from: 0, to: totalAssets > 0 ? CGFloat(gainers) / CGFloat(totalAssets) : 0)
                                    .stroke(appTheme.positiveColor, lineWidth: 6)
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 40, height: 40)
                        }

                        Divider().background(theme.glassBorder)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(appTheme.negativeColor)
                                    Text("Losers")
                                        .font(.caption2)
                                        .foregroundColor(appTheme.negativeColor.opacity(0.8))
                                }
                                Text("\(losers)")
                                    .font(.title2.bold())
                                    .foregroundColor(appTheme.negativeColor)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(theme.glassBackground))
            }
        }
        .padding(.horizontal)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            motionSafeWithAnimation { isLoading = false }
        }
    }
}

// MARK: - Index Card with Chart
struct IndexCardWithChart: View {
    let index: MarketIndex
    let history: [PricePoint]
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(index.name)
                        .font(.headline)
                        .foregroundColor(theme.primaryText.opacity(0.9))

                    HStack(spacing: 4) {
                        Image(systemName: index.change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text(String(format: "%+.2f%%", index.changePercent))
                            .font(.caption.bold())
                    }
                    .foregroundColor(index.change >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                }
                Spacer()
            }

            // Mini Chart
            if !history.isEmpty {
                let _prices = history.map { $0.price }
                let _minP = _prices.min() ?? 0
                let _maxP = _prices.max() ?? 1
                let _pad  = max((_maxP - _minP) * 0.04, _maxP * 0.005)
                let _color = index.change >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                Chart(history) {
                    AreaMark(x: .value("Date", $0.date), y: .value("Price", $0.price))
                        .foregroundStyle(LinearGradient(colors: [_color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Date", $0.date), y: .value("Price", $0.price))
                        .foregroundStyle(_color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                }
                .chartYScale(domain: max(0, _minP - _pad)...(_maxP + _pad))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 60)
                .clipped()
            }

            // Price
            Text(index.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                .font(.title3.bold())
                .foregroundColor(theme.primaryText)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke((index.change >= 0 ? appTheme.positiveColor : appTheme.negativeColor).opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Empty Watchlist Card
struct EmptyWatchlistCard: View {
    let kind: AssetKind
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)

                Image(systemName: kind == .stock ? "chart.line.uptrend.xyaxis" : "bitcoinsign.circle")
                    .font(.system(size: 50))
                    .foregroundColor(theme.primaryText.opacity(0.8))
            }

            Text("No \(kind == .stock ? "Stocks" : "Crypto") Yet")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            Text("Add \(kind == .stock ? "stocks" : "cryptocurrencies") to start tracking their performance")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.chartPlaceholder)
        )
        .padding(.horizontal)
    }
}

struct EnhancedWatchlistRow: View {
    let asset: Asset
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @State private var miniHistory: [PricePoint] = []
    @State private var isLoading = true

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 16) {
            // Icon
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                Text(asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            Spacer()

            // Mini Chart with Skeleton
            if isLoading {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 35)
                    .shimmering()  // Pulsing animation
            } else if !miniHistory.isEmpty {
                let _prices = miniHistory.map { $0.price }
                let _minP = _prices.min() ?? 0
                let _maxP = _prices.max() ?? 1
                let _pad  = max((_maxP - _minP) * 0.04, _maxP * 0.005)
                let _color = asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                Chart(miniHistory) {
                    AreaMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(LinearGradient(colors: [_color.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                    LineMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(_color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.linear)
                }
                .chartYScale(domain: max(0, _minP - _pad)...(_maxP + _pad))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 70, height: 35)
                .clipped()
            }

            // Price Info
            VStack(alignment: .trailing, spacing: 4) {
                Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 4) {
                    Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(String(format: "%+.2f%%", asset.changePercent))
                        .font(.caption.bold())
                }
                .foregroundColor(asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill((asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor).opacity(0.2))
                )
            }
        }
        .accessibilityElement(children: .combine)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.glassBackground)
        )
        .task {
            // If we already have cached data for this symbol, apply it immediately
            // without showing the loading skeleton — stable across tab navigation.
            if let cached = marketData.miniChartCache[asset.symbol], !cached.isEmpty {
                miniHistory = cached
                isLoading = false
            } else {
                let points = await marketData.fetchMiniChartHistory(for: asset)
                miniHistory = points
                motionSafeWithAnimation(.easeInOut) {
                    isLoading = false
                }
            }
        }
    }
}
// MARK: - Search Sheet (Aesthetic)
//struct SearchSheet: View {
//    @EnvironmentObject var marketData: MarketData
//    @Environment(\.dismiss) var dismiss
//    let kind: AssetKind
//
//    @State private var searchText = ""
//    @State private var isSearching = false
//    @State private var isShowingCustomAdd = false
//
//    var body: some View {
//        NavigationStack {
//            ZStack {
//                Color.black.ignoresSafeArea()
//
//                if filteredResults.isEmpty && !searchText.isEmpty && !isSearching {
//                    VStack(spacing: 24) {
//                        ZStack {
//                            Circle()
//                                .fill(LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
//                                .frame(width: 180, height: 180)
//                                .blur(radius: 40)
//
//                            Image(systemName: "magnifyingglass")
//                                .font(.system(size: 80))
//                                .foregroundColor(.white.opacity(0.4))
//                        }
//
//                        Text("No results for \"\(searchText)\"")
//                            .font(.title2.bold())
//                            .foregroundColor(.white.opacity(0.8))
//
//                        Text("Try a different symbol or add it manually")
//                            .font(.subheadline)
//                            .foregroundColor(.gray)
//                            .multilineTextAlignment(.center)
//                            .padding(.horizontal, 40)
//
//                        Button {
//                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
//                            isShowingCustomAdd = true
//                        } label: {
//                            HStack {
//                                Image(systemName: "plus.circle.fill")
//                                Text("Add \"\(searchText.uppercased())\" Manually")
//                            }
//                            .font(.headline)
//                            .foregroundColor(.white)
//                            .padding(.horizontal, 28)
//                            .padding(.vertical, 16)
//                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
//                            .cornerRadius(20)
//                            .shadow(color: .purple.opacity(0.6), radius: 20, y: 10)
//                        }
//                    }
//                    .transition(.opacity.combined(with: .scale))
//                } else {
//                    List {
//                        ForEach(filteredResults) { asset in
//                            SearchResultRow(asset: asset)
//                                .onTapGesture {
//                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
//                                    marketData.addToWatchlist(asset)
//                                    dismiss()
//                                }
//                        }
//                        .listRowBackground(Color.clear)
//                        .listRowSeparator(.hidden)
//                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
//                    }
//                    .listStyle(PlainListStyle())
//                    .animation(.easeInOut(duration: 0.3), value: filteredResults)
//                }
//
//                if isSearching {
//                    Color.black.opacity(0.6)
//                        .ignoresSafeArea()
//                        .overlay(
//                            ProgressView("Searching...")
//                                .scaleEffect(1.2)
//                                .foregroundColor(.white)
//                                .padding()
//                                .background(Color.black.opacity(0.8))
//                                .cornerRadius(16)
//                                .shadow(radius: 20)
//                        )
//                }
//            }
//            .navigationTitle("Search \(kind == .stock ? "Stocks" : "Crypto")")
//            .navigationBarTitleDisplayMode(.large)
//            .toolbarBackground(.hidden, for: .navigationBar)
//            .toolbar {
//                ToolbarItem(placement: .cancellationAction) {
//                    Button("Cancel") { dismiss() }
//                        .foregroundColor(.white.opacity(0.8))
//                }
//            }
//            .searchable(
//                text: $searchText,
//                placement: .navigationBarDrawer(displayMode: .always),
//                prompt: Text("Search symbols or names (e.g., AAPL, Bitcoin)")
//                    .foregroundColor(.white.opacity(0.6))
//            )
//            .onChange(of: searchText) { _, newValue in
//                Task {
//                    isSearching = !newValue.isEmpty
//                    if !newValue.isEmpty {
//                        await marketData.searchAssets(query: newValue, kind: kind)
//                    }
//                    withAnimation(.easeInOut) {
//                        isSearching = false
//                    }
//                }
//            }
//            .sheet(isPresented: $isShowingCustomAdd) {
//                AddCustomAssetSheet(kind: kind, presetSymbol: searchText)
//            }
//        }
//        .preferredColorScheme(.dark)
//    }
//
//    private var filteredResults: [Asset] {
//        marketData.searchResults.filter { $0.kind == kind }
//    }
//}

// MARK: - Aesthetic Search Result Row with Skeleton Loading
struct SearchResultRow: View {
    let asset: Asset
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @State private var miniHistory: [PricePoint] = []
    @State private var isLoading = true  // New: loading state for skeleton

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                Text(asset.name)
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Mini Sparkline with Skeleton
            if isLoading {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 40)
                    .shimmering()  // Pulsing shimmer effect
            } else if !miniHistory.isEmpty {
                let _prices = miniHistory.map { $0.price }
                let _minP = _prices.min() ?? 0
                let _maxP = _prices.max() ?? 1
                let _pad  = max((_maxP - _minP) * 0.04, _maxP * 0.005)
                let _color = asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                Chart(miniHistory) {
                    AreaMark(x: .value("Date", $0.date), y: .value("Price", $0.price))
                        .foregroundStyle(LinearGradient(colors: [_color.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Date", $0.date), y: .value("Price", $0.price))
                        .foregroundStyle(_color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.linear)
                }
                .chartYScale(domain: max(0, _minP - _pad)...(_maxP + _pad))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 80, height: 40)
                .clipped()
            }

            // Price & Change
            VStack(alignment: .trailing, spacing: 4) {
                if isLoading {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 90, height: 20)
                        .shimmering()

                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 70, height: 24)
                        .shimmering()
                } else {
                    Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.headline)
                        .foregroundColor(theme.primaryText)

                    Text(String(format: "%+.2f%%", asset.changePercent))
                        .font(.caption.bold())
                        .foregroundColor(asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor).opacity(0.2))
                        )
                }
            }

            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundColor(isLoading ? .gray.opacity(0.5) : appTheme.positiveColor.opacity(0.8))
                .opacity(isLoading ? 0.6 : 1.0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(theme.chartPlaceholder)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(LinearGradient(colors: [theme.separator, .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.04), radius: 10, y: 5)
        .task {
            if let cached = marketData.miniChartCache[asset.symbol], !cached.isEmpty {
                miniHistory = cached
                isLoading = false
            } else {
                let points = await marketData.fetchMiniChartHistory(for: asset)
                miniHistory = points
                withAnimation(.easeInOut(duration: 0.3)) {
                    isLoading = false
                }
            }
        }
    }

}

// shimmering() is defined in SkeletonView.swift


private func detailedStock(from asset: Asset) -> DetailedStock {
    let price = asset.price
    let changePercent = asset.changePercent
    let changeAmount = price * (changePercent / 100.0)
    let previousClose = price - changeAmount

    // Reasonable defaults/mocks for fields we don't have in the simple Asset model
    let exchange = asset.kind == .stock ? "NASDAQ" : "Crypto"
    let marketCap: Double = asset.kind == .stock ? 2_800_000_000_000 : 600_000_000_000  // e.g. AAPL vs BTC scale
    let volume = Int.random(in: 20_000_000...80_000_000)
    let avgVolume = Int.random(in: 20_000_000...80_000_000)
    let sharesOutstanding: Double = asset.kind == .stock ? 15_800_000_000 : 0
    let week52High = price * 1.3
    let week52Low = price * 0.7
    let beta: Double? = asset.kind == .stock ? 1.24 : nil
    let dividendYield: Double? = asset.kind == .stock ? 0.58 : nil

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

// MARK: - Custom Asset Sheet
struct AddCustomAssetSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss

    let kind: AssetKind
    let presetSymbol: String

    @State private var symbol = ""
    @State private var name = ""
    @State private var priceText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom \(kind == .stock ? "Stock" : "Crypto")") {
                    TextField("Symbol", text: $symbol)
                        .textInputAutocapitalization(.characters)
                    TextField("Name (optional)", text: $name)
                    TextField("Current Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Text("This will be added with the price you enter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Custom Asset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let price = Double(priceText),
                              !symbol.trimmingCharacters(in: .whitespaces).isEmpty else { return }

                        let cleanSymbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
                        let cleanName = name.isEmpty ? cleanSymbol : name

                        marketData.addCustomAsset(
                            symbol: cleanSymbol,
                            name: cleanName,
                            price: price,
                            kind: kind,
                            exchange: "NYSE"
                        )
                        dismiss()
                        dismiss()
                    }
                    .disabled(symbol.isEmpty || priceText.isEmpty || Double(priceText) == nil)
                }
            }
            .onAppear {
                symbol = presetSymbol.uppercased()
            }
        }
    }
}

// MARK: - Create Watchlist Sheet

struct CreateWatchlistSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 8) {
                    TextField("Watchlist name", text: $name)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { create() }

                    Text("Give your watchlist a clear, descriptive name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationTitle("New Watchlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        marketData.createWatchlist(name: trimmed)
        dismiss()
    }
}
