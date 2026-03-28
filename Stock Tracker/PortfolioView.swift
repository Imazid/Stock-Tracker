//
//  PortfolioView.swift
//  Stock Tracker
//
//  Full premium fintech-grade portfolio page.
//  Tab-based layout: Overview | Performance | Dividends | Benchmark.
//  Hero chart, interactive scrubbing, allocation donut, risk metrics.
//

import SwiftUI
import Charts

// MARK: - Portfolio Tab

enum PortfolioTab: String, CaseIterable {
    case overview    = "Overview"
    case allocation  = "Allocation"
    case performance = "Performance"
    case dividends   = "Dividends"
    case benchmark   = "Benchmark"
}

// MARK: - Holding Palette (shared)

let holdingPalette: [Color] = [
    Color(red: 0.18, green: 0.40, blue: 1.00),
    Color(red: 0.58, green: 0.18, blue: 1.00),
    Color(red: 1.00, green: 0.48, blue: 0.00),
    Color(red: 0.08, green: 0.72, blue: 0.42),
    Color(red: 1.00, green: 0.28, blue: 0.60),
    Color(red: 0.00, green: 0.78, blue: 0.92),
    Color(red: 0.90, green: 0.20, blue: 0.20),
]

// MARK: - PortfolioView

struct PortfolioView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @StateObject private var viewModel = PortfolioViewModel()
    @StateObject private var snapTradeVM: SnapTradeViewModel = {
        let clientId = SecretsConfig.snapTradeClientId
        let consumerKey = SecretsConfig.snapTradeConsumerKey
        let networkService = SnapTradeNetworkService(clientId: clientId, consumerKey: consumerKey)
        let repository = SnapTradeRepository(networkService: networkService)
        return SnapTradeViewModel(repository: repository)
    }()

    private let stockBrokers: [(String, String)] = [
        ("CommSec", "COMMSEC"), ("Alpaca", "ALPACA"), ("TD Ameritrade", "TDAMERITRADE"),
        ("E*TRADE", "ETRADE"), ("Fidelity", "FIDELITY"), ("Schwab", "SCHWAB"),
        ("Interactive Brokers", "IBKR"), ("Robinhood", "ROBINHOOD"), ("Webull", "WEBULL")
    ]
    private let cryptoExchanges: [(String, String)] = [
        ("Coinbase", "COINBASE"), ("Kraken", "KRAKEN"), ("Binance", "BINANCE"),
        ("Binance US", "BINANCEUS"), ("Gemini", "GEMINI"), ("CoinSpot", "COINSPOT"), ("CoinJar", "COINJAR")
    ]

    // Tab state
    @State private var selectedTab: PortfolioTab = .overview

    // Chart state (passed into PortfolioHeroView)
    @State private var selectedChartRange: PortfolioChartRange = .oneMonth
    @State private var scrubbedSnapshot: PortfolioSnapshot?

    // Sheet / navigation state
    @State private var selectedHolding: PortfolioHolding?
    @State private var showSnapTrade = false
    @State private var showAddHolding = false
    @State private var showConnectionPicker = false
    @State private var showManualEntry = false
    @State private var snapTradeAutoMode: SnapTradeAutoMode? = nil
    @State private var showBrokerPicker = false
    @State private var showCryptoExchangePicker = false
    @State private var showCSVImport = false
    @State private var showCreatePortfolio = false
    @State private var showIntelligence = false

    // Holdings filter
    @State private var filterMode: PortfolioFilterMode = .all

    // Portfolio switcher
    @State private var showPortfolioDropdown = false
    @State private var portfolioRenameTargetIndex: Int? = nil
    @State private var portfolioRenameText = ""
    @State private var holdingToDelete: PortfolioHolding?
    @State private var showPaywall = false
    @EnvironmentObject var insightService: AIInsightService
    @State private var portfolioHealthText: String?
    @State private var healthLoading = false
    @State private var healthDismissed = false

    // MARK: - Computed Helpers

    private var activePortfolioName: String {
        let idx = marketData.activePortfolioIndex
        guard marketData.portfolioGroups.indices.contains(idx) else { return "Portfolio" }
        return marketData.portfolioGroups[idx].name
    }

    private var stockCount: Int  { marketData.portfolio.filter { $0.asset.kind == .stock  }.count }
    private var cryptoCount: Int { marketData.portfolio.filter { $0.asset.kind == .crypto }.count }

    private var bestPerformer: PortfolioHolding? {
        marketData.portfolio.max(by: { $0.profitLossPercent < $1.profitLossPercent })
    }
    private var worstPerformer: PortfolioHolding? {
        marketData.portfolio.min(by: { $0.profitLossPercent < $1.profitLossPercent })
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        // Portfolio switcher header
                        portfolioHeaderView
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 12)

                        // Tab bar
                        PortfolioTabBar(selectedTab: $selectedTab)

                        // Tab content
                        tabContent
                            .animation(.easeInOut(duration: 0.22), value: selectedTab)
                    }
                }
                .refreshable { await marketData.refreshFromAPI() }

                // FAB
                fabButton
            }
            .navigationTitle(activePortfolioName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showIntelligence) {
                PortfolioIntelligenceView()
                    .environmentObject(marketData)
                    .environmentObject(subscriptionManager)
            }
            .sheet(isPresented: $showConnectionPicker) {
                ConnectionTypeSheet(
                    onStockBroker: {
                        showConnectionPicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showBrokerPicker = true
                        }
                    },
                    onCryptoExchange: {
                        showConnectionPicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showCryptoExchangePicker = true
                        }
                    },
                    onManual: {
                        showConnectionPicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showAddHolding = true
                        }
                    },
                    onCSVImport: subscriptionManager.currentTier == .black ? {
                        showConnectionPicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showCSVImport = true
                        }
                    } : nil
                )
                .presentationDetents(subscriptionManager.currentTier == .black ? [.medium, .large] : [.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSnapTrade) { SnapTradeConnectionView(autoMode: snapTradeAutoMode) }
            .sheet(isPresented: $showBrokerPicker) {
                BrokerPickerSheet(brokers: stockBrokers) { slug in
                    Task { await snapTradeVM.connectBroker(broker: slug) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCryptoExchangePicker) {
                CryptoPickerSheet(exchanges: cryptoExchanges) { slug in
                    Task { await snapTradeVM.connectBroker(broker: slug) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $snapTradeVM.showConnectionView) {
                if let url = snapTradeVM.connectionURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                        .onDisappear {
                            Task { await snapTradeVM.syncAll() }
                        }
                }
            }
            .sheet(isPresented: $showManualEntry) { ManualPositionSheet().environmentObject(marketData) }
            .sheet(isPresented: $showAddHolding) { AddHoldingSheet() }
            .sheet(isPresented: $showCSVImport) { CSVImportSheet().environmentObject(marketData) }
            .sheet(item: $selectedHolding) { HoldingDetailView(holding: $0) }
            .sheet(isPresented: $showCreatePortfolio) {
                CreatePortfolioSheet(onDismiss: { showCreatePortfolio = false })
                    .environmentObject(marketData)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(requiredTier: .pro, featureName: "More Portfolio Holdings")
                    .environmentObject(subscriptionManager)
            }
            .onAppear { viewModel.observe(marketData) }
            .alert("Rename Portfolio", isPresented: Binding(
                get: { portfolioRenameTargetIndex != nil },
                set: { if !$0 { portfolioRenameTargetIndex = nil } }
            )) {
                TextField("Name", text: $portfolioRenameText)
                Button("Save") {
                    if let i = portfolioRenameTargetIndex {
                        let trimmed = portfolioRenameText.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { marketData.renamePortfolio(at: i, to: trimmed) }
                    }
                    portfolioRenameTargetIndex = nil
                }
                Button("Cancel", role: .cancel) { portfolioRenameTargetIndex = nil }
            }
            .alert("Remove Holding", isPresented: Binding(
                get: { holdingToDelete != nil },
                set: { if !$0 { holdingToDelete = nil } }
            )) {
                Button("Remove", role: .destructive) {
                    if let holding = holdingToDelete {
                        motionSafeWithAnimation {
                            marketData.removeFromPortfolio(holding)
                        }
                    }
                    holdingToDelete = nil
                }
                Button("Cancel", role: .cancel) { holdingToDelete = nil }
            } message: {
                if let h = holdingToDelete {
                    Text("Remove \(h.asset.symbol) (\(String(format: "%.4g", h.shares)) shares) from your portfolio?")
                }
            }
        }
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showConnectionPicker = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 56, height: 56)
                    .shadow(color: colorScheme == .dark ? .blue.opacity(0.35) : .blue.opacity(0.10), radius: 10, y: 5)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 90)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewContent
        case .allocation:
            VStack(spacing: 0) {
                AllocationChartView()
                    .environmentObject(marketData)
                    .padding(.top, 16)
                Spacer(minLength: 120)
            }
        case .performance:
            PortfolioPerformanceTabView()
                .environmentObject(marketData)
                .environmentObject(subscriptionManager)
        case .dividends:
            PortfolioDividendsTabView()
                .environmentObject(marketData)
                .environmentObject(subscriptionManager)
        case .benchmark:
            PortfolioBenchmarkTabView()
                .environmentObject(marketData)
                .environmentObject(subscriptionManager)
        }
    }

    // MARK: - Overview Tab

    private var overviewContent: some View {
        VStack(spacing: 0) {
            PortfolioHeroView(
                totalValue:      marketData.totalPortfolioValue,
                totalCostBasis:  marketData.totalCostBasis,
                history:         marketData.portfolioHistory,
                dailyPL:         marketData.dailyProfitLoss,
                dailyPLPercent:  marketData.dailyProfitLossPercent,
                totalPL:         marketData.totalProfitLoss,
                totalPLPercent:  marketData.totalProfitLossPercent,
                selectedRange:   $selectedChartRange,
                scrubbedSnapshot: $scrubbedSnapshot
            )
            .environmentObject(marketData)

            if !marketData.portfolio.isEmpty {
                // AI Portfolio Health (Pro/Black only)
                if !healthDismissed && subscriptionManager.currentTier != .free {
                    portfolioHealthCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                compactStatsRow
                    .padding(.top, 16)

                holdingsSection
                    .padding(.top, 20)

            } else {
                emptyState.padding(.top, 24)
            }

            Spacer(minLength: 120)
        }
    }

    // MARK: - AI Portfolio Health

    private var portfolioHealthCard: some View {
        let tier = subscriptionManager.currentTier
        let isLocked = tier == .free
        let cacheKey = "portfolio_health_\(insightService.todayString)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? portfolioHealthText
        return AIInsightCard(
            title: "Portfolio Health",
            icon: "heart.text.square",
            insightText: cachedText,
            isLoading: healthLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadPortfolioHealth() },
            onRegenerate: { await loadPortfolioHealth(force: true) }
        )
    }

    private func loadPortfolioHealth(force: Bool = false) async {
        healthLoading = true
        defer { healthLoading = false }

        let tier = subscriptionManager.currentTier
        let cacheKey = "portfolio_health_\(insightService.todayString)"
        let totalValue = marketData.totalPortfolioValue
        guard totalValue > 0 else { return }

        let holdingsSummary = marketData.portfolio.map { h in
            let pct = (h.currentValue / totalValue) * 100
            let plPct = h.profitLossPercent
            return "\(h.asset.symbol): \(Int(pct))% of portfolio, \(String(format: "%+.1f%%", plPct)) P&L"
        }.joined(separator: "; ")

        let stockPct = marketData.portfolio
            .filter { $0.asset.kind == .stock }
            .reduce(0.0) { $0 + $1.currentValue } / totalValue * 100
        let cryptoPct = 100 - stockPct

        let topHoldingPct = marketData.portfolio
            .map { $0.currentValue / totalValue * 100 }
            .max() ?? 0

        let systemPrompt = "You are a portfolio risk advisor. Identify 1-2 key risks or opportunities. Be specific about which holdings. 2-3 bullet points max. No buy/sell advice."
        let userPrompt = """
        Portfolio: \(String(format: "$%.0f", totalValue)) total, \(String(format: "%+.1f%%", marketData.totalProfitLossPercent)) overall. \
        Allocation: \(Int(stockPct))% stocks, \(Int(cryptoPct))% crypto. \
        Top concentration: \(Int(topHoldingPct))%. \
        Holdings: \(holdingsSummary).
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .portfolioHealth,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .portfolioHealth,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { portfolioHealthText = text }
    }

    // MARK: - Portfolio Header

    private var portfolioHeaderView: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        showPortfolioDropdown.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        Text(activePortfolioName)
                            .font(.title2.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(showPortfolioDropdown ? -180 : 0))
                            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: showPortfolioDropdown)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            Text("Watch your assets grow")
                .font(.title3.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.top, 4)

            if showPortfolioDropdown {
                portfolioPillsRow
                    .padding(.top, 12)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal:   .opacity.combined(with: .move(edge: .top))
                    ))
            }
        }
    }

    private var portfolioPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(marketData.portfolioGroups.enumerated()), id: \.1.id) { index, group in
                    let isActive = index == marketData.activePortfolioIndex
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                            marketData.switchToPortfolio(index: index)
                            showPortfolioDropdown = false
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
                            portfolioRenameText = group.name
                            portfolioRenameTargetIndex = index
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        if marketData.portfolioGroups.count > 1 {
                            Button(role: .destructive) {
                                withAnimation { marketData.deletePortfolio(at: index) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    showPortfolioDropdown = false
                    showCreatePortfolio = true
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

    // MARK: - Compact Stats Row

    private var compactStatsRow: some View {
        let returnColor: Color = marketData.totalProfitLossPercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor
        let todayColor: Color  = marketData.dailyProfitLoss >= 0 ? appTheme.positiveColor : appTheme.negativeColor

        return HStack(spacing: 0) {
            statColumn(
                label: "Return",
                value: String(format: "%+.2f%%", marketData.totalProfitLossPercent),
                valueColor: returnColor
            )
            Divider().frame(height: 32)
            statColumn(
                label: "Today",
                value: marketData.formatPrice(marketData.dailyProfitLoss),
                valueColor: todayColor
            )
            Divider().frame(height: 32)
            statColumn(
                label: "Positions",
                value: "\(marketData.portfolio.count)",
                valueColor: .primary
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
        .padding(.horizontal, 16)
    }

    private func statColumn(label: String, value: String, valueColor: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundColor(valueColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Holdings Section

    private var holdingsSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Holdings")
                        .font(.title3.bold())
                    Text("\(marketData.portfolio.count) position\(marketData.portfolio.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(PortfolioSortOption.allCases, id: \.self) { opt in
                        Button(opt.rawValue) { viewModel.sortBy = opt }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)

            filterPillsRow(theme: theme)
                .padding(.horizontal)
                .padding(.bottom, 16)

            // Over-limit banner
            if marketData.isOverPortfolioLimit {
                let overCount = marketData.portfolio.count - (FeatureGate.maxPortfolioHoldings(for: subscriptionManager.currentTier) ?? Int.max)
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(overCount) holding\(overCount == 1 ? "" : "s") over your plan limit")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Remove holdings or upgrade your plan.")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Button("Upgrade") {
                        showPaywall = true
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
                .padding(.horizontal)
                .padding(.bottom, 12)
            }

            if marketData.portfolio.isEmpty && marketData.isRefreshingQuotes {
                VStack(spacing: 10) {
                    StaggeredSkeletonList(count: 4) {
                        HoldingRowSkeleton().padding(.horizontal)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(viewModel.filteredHoldings.enumerated()), id: \.1.id) { index, holding in
                        PortfolioHoldingCard(holding: holding, paletteIndex: index)
                            .padding(.horizontal)
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedHolding = holding
                            }
                            .contextMenu {
                                Button {
                                    selectedHolding = holding
                                } label: {
                                    Label("View Details", systemImage: "chart.line.uptrend.xyaxis")
                                }
                                Button(role: .destructive) {
                                    holdingToDelete = holding
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    holdingToDelete = holding
                                } label: {
                                    Label("Remove", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
        }
    }

    private func filterPillsRow(theme: Theme) -> some View {
        HStack(spacing: 8) {
            filterPill(label: "All",              mode: .all,    theme: theme)
            filterPill(label: "Stocks (\(stockCount))", mode: .stocks, theme: theme)
            filterPill(label: "Crypto (\(cryptoCount))", mode: .crypto, theme: theme)
            Spacer()
        }
    }

    private func filterPill(label: String, mode: PortfolioFilterMode, theme: Theme) -> some View {
        let isSelected = filterMode == mode
        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                filterMode = mode
                switch mode {
                case .all:    viewModel.showAll = true
                case .stocks: viewModel.showAll = false; viewModel.selectedFilter = .stock
                case .crypto: viewModel.showAll = false; viewModel.selectedFilter = .crypto
                }
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : theme.glassBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : theme.glassBorder, lineWidth: 1)
                        .opacity(isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 32) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.4))

            VStack(spacing: 10) {
                Text("Build Your Portfolio")
                    .font(.title2.bold())
                Text("Add your first holding to start tracking\nperformance, gains, and more.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                EmptyStateTip(icon: "plus.circle.fill",   color: .blue,   title: "Add from Watchlist",    description: "Tap a stock and choose Add to Portfolio")
                EmptyStateTip(icon: "link",               color: .purple, title: "Connect Broker",         description: "Sync your real holdings automatically")
                EmptyStateTip(icon: "chart.xyaxis.line",  color: .green,  title: "Track Performance",      description: "See gains, losses and portfolio history")
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 16)
    }

    struct EmptyStateTip: View {
        let icon: String
        let color: Color
        let title: String
        let description: String

        var body: some View {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(description).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Portfolio Tab Bar

private struct PortfolioTabBar: View {
    @Binding var selectedTab: PortfolioTab
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(PortfolioTab.allCases, id: \.self) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                selectedTab = tab
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            VStack(spacing: 0) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? .primary : .secondary)
                                    .padding(.horizontal, 18)
                                    .padding(.top, 12)
                                    .padding(.bottom, 10)

                                ZStack {
                                    Color.clear
                                    if isSelected {
                                        Rectangle()
                                            .fill(Color.primary)
                                            .matchedGeometryEffect(id: "tab_underline", in: ns)
                                    }
                                }
                                .frame(height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider()
        }
    }
}

// MARK: - Portfolio Filter Mode

private enum PortfolioFilterMode: Equatable {
    case all, stocks, crypto
}

// MARK: - PortfolioHoldingCard

private struct PortfolioHoldingCard: View {
    let holding: PortfolioHolding
    let paletteIndex: Int
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var paletteColor: Color { holdingPalette[paletteIndex % holdingPalette.count] }
    private var isProfit: Bool { holding.profitLoss >= 0 }
    private var accentColor: Color { isProfit ? appTheme.positiveColor : appTheme.negativeColor }
    private var allocation: Double {
        guard marketData.totalPortfolioValue > 0 else { return 0 }
        return (holding.currentValue / marketData.totalPortfolioValue) * 100
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 0) {
            // Left accent stripe
            paletteColor
                .frame(width: 4)
                .cornerRadius(2)

            HStack(spacing: 12) {
                // Symbol badge
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(paletteColor.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Text(String(holding.asset.symbol.prefix(2)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(paletteColor)
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(holding.asset.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(holding.asset.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(String(format: "%.4g shares", holding.shares))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.75))
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.50))
                        Text(String(format: "%.1f%% of portfolio", allocation))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.75))
                    }
                }

                Spacer()

                // Value + P&L
                VStack(alignment: .trailing, spacing: 5) {
                    Text(marketData.formatPrice(holding.currentValue))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(.primary)

                    HStack(spacing: 3) {
                        Image(systemName: isProfit ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%@%.2f%%", isProfit ? "+" : "", holding.profitLossPercent))
                            .font(.caption.weight(.bold))
                    }
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.10))
                    .clipShape(Capsule())

                    Text(String(format: "%@%@", isProfit ? "+" : "", marketData.formatPrice(holding.profitLoss)))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(accentColor)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
        .background(theme.glassBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(paletteColor.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(FinancialAccessibility.holdingDescription(
            symbol: holding.asset.symbol,
            shares: holding.shares,
            currentValue: holding.currentValue,
            profitLossPercent: holding.profitLossPercent
        ))
    }
}

// MARK: - CreatePortfolioSheet

struct CreatePortfolioSheet: View {
    @EnvironmentObject var marketData: MarketData
    let onDismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 8) {
                    TextField("Portfolio name", text: $name)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { create() }
                    Text("Give your portfolio a clear, descriptive name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("New Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction)  { Button("Cancel") { onDismiss() } }
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
        marketData.createPortfolio(name: trimmed, emoji: "")
        onDismiss()
    }
}

// MARK: - AddHoldingSheet

struct AddHoldingSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var selectedKind: AssetKind = .stock
    @State private var query = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var selectedAsset: Asset?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @StateObject private var speech = SearchVoiceRecognizer()

    private var localMatches: [Asset] {
        let pool = selectedKind == .stock ? marketData.stocks : marketData.crypto
        guard !query.isEmpty else { return pool }
        return pool.filter {
            $0.symbol.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }
    private var hasResults: Bool { !localMatches.isEmpty || !searchResults.isEmpty }
    private var totalCount: Int  { localMatches.count + searchResults.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                kindPicker
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
                searchBar
                    .padding(.horizontal, 16).padding(.bottom, 12)
                Divider()
                ScrollView {
                    if isSearching                                  { skeletonState }
                    else if query.isEmpty && localMatches.isEmpty   { initialState  }
                    else if !query.isEmpty && !hasResults            { noResultsState }
                    else                                            { resultsContent }
                }
            }
            .background(colorScheme == .dark ? Color(UIColor.systemBackground) : Color(red: 0.980, green: 0.973, blue: 0.961))
            .navigationTitle("Add to Portfolio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .sheet(item: $selectedAsset) { asset in
                ManualPositionSheet(asset: asset).environmentObject(marketData)
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                guard !newValue.isEmpty else { searchResults = []; return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    await performSearch(newValue)
                }
            }
            .onChange(of: selectedKind) { _, _ in query = ""; searchResults = [] }
            .onDisappear { if speech.isRecording { speech.stopRecording() } }
            .alert("Microphone Access Needed", isPresented: $speech.permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enable microphone and speech recognition in Settings to use voice search.")
            }
        }
    }

    // Kind Picker
    private var kindPicker: some View {
        HStack(spacing: 0) {
            ForEach([AssetKind.stock, AssetKind.crypto], id: \.self) { kind in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selectedKind = kind }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind == .stock ? "chart.line.uptrend.xyaxis" : "bitcoinsign.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(kind == .stock ? "Stocks" : "Crypto")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selectedKind == kind ? (colorScheme == .dark ? Color(UIColor.systemBackground) : Color(red: 0.980, green: 0.973, blue: 0.961)) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundColor(selectedKind == kind ? .primary : .secondary)
                }
            }
        }
        .padding(4)
        .background(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.945, green: 0.930, blue: 0.905), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedKind)
    }

    // Search Bar
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(.secondary)
            TextField("Search symbols or companies...", text: $query)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                    if speech.isRecording { speech.stopRecording() }
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.secondary)
                }
                .transition(.scale.combined(with: .opacity))
            }
            Button {
                speech.toggle { transcript in query = transcript }
            } label: {
                ZStack {
                    Circle()
                        .fill(speech.isRecording ? Color.red.opacity(0.15) : Color.clear)
                        .frame(width: 32, height: 32)
                        .scaleEffect(speech.isRecording ? 1.0 : 0.1)
                        .animation(
                            speech.isRecording ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                            value: speech.isRecording
                        )
                    Image(systemName: speech.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(speech.isRecording ? .red : .secondary)
                }
            }
            .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.945, green: 0.930, blue: 0.905))
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isSearchFocused = true }
        }
    }

    // Initial State
    private var initialState: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878)).frame(width: 64, height: 64)
                    Image(systemName: "briefcase.fill").font(.system(size: 28)).foregroundColor(.blue)
                }
                VStack(spacing: 8) {
                    Text("Add a \(selectedKind == .stock ? "Stock" : "Crypto") Position")
                        .font(.title3.weight(.semibold))
                    Text("Search by symbol or name, then enter your purchase details to track your position.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                    Label("Tap the mic to search by voice", systemImage: "mic.fill")
                        .font(.caption).foregroundColor(.secondary.opacity(0.7)).padding(.top, 4)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Popular Picks")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    .textCase(.uppercase).tracking(0.5)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                    ForEach(popularSymbols, id: \.self) { symbol in
                        Button { query = symbol } label: {
                            Text(symbol)
                                .font(.subheadline.weight(.medium)).foregroundColor(.primary)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878)).cornerRadius(8)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 32)
    }

    // Skeleton
    private var skeletonState: some View {
        StaggeredSkeletonList(count: 6) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    SkeletonCircle(size: 40)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: 55, height: 14)
                        SkeletonBlock(width: 140, height: 11)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        SkeletonBlock(width: 65, height: 14)
                        SkeletonBlock(width: 45, height: 11)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().padding(.leading, 68)
            }
        }
        .padding(.top, 4)
    }

    // No Results
    private var noResultsState: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878)).frame(width: 64, height: 64)
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundColor(.secondary)
                }
                VStack(spacing: 8) {
                    Text("No results for \"\(query)\"").font(.title3.weight(.semibold))
                    Text("Try a different ticker symbol or company name")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            }
            Spacer()
        }
        .padding(.top, 40)
    }

    // Results
    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !query.isEmpty {
                Text("\(totalCount) \(totalCount == 1 ? "result" : "results")")
                    .font(.subheadline).foregroundColor(.secondary)
                    .padding(.horizontal).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878)).opacity(0.5))
            }
            LazyVStack(spacing: 0) {
                if !localMatches.isEmpty {
                    sectionLabel(query.isEmpty ? "In Your Watchlist" : "Close Matches")
                    ForEach(localMatches) { asset in
                        PortfolioSearchResultRow(
                            symbol: asset.symbol, name: asset.name, exchange: asset.exchange,
                            price: asset.price, changePercent: asset.changePercent,
                            isInPortfolio: marketData.portfolio.contains { $0.asset.symbol == asset.symbol }
                        )
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedAsset = asset
                        }
                        if asset.id != localMatches.last?.id || !searchResults.isEmpty {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                if !searchResults.isEmpty {
                    sectionLabel("Search Results")
                    ForEach(searchResults, id: \.id) { result in
                        PortfolioSearchResultRow(
                            symbol: result.symbol, name: result.name, exchange: nil,
                            price: nil, changePercent: nil,
                            isInPortfolio: marketData.portfolio.contains { $0.asset.symbol == result.symbol }
                        )
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await resolveAndSelect(result) }
                        }
                        if result.id != searchResults.last?.id { Divider().padding(.leading, 68) }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
            .textCase(.uppercase).tracking(0.4)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performSearch(_ term: String) async {
        guard !term.isEmpty else { return }
        isSearching = true; defer { isSearching = false }
        let results = (try? await APIService.shared.fetchSymbolSearch(query: term, kind: selectedKind)) ?? []
        if !Task.isCancelled { searchResults = results }
    }

    private func resolveAndSelect(_ result: SearchResult) async {
        isSearching = true; defer { isSearching = false }
        if let asset = try? await APIService.shared.fetchAssetDetails(
            identifier: result.symbol, kind: selectedKind, name: result.name, exchange: result.exchange) {
            selectedAsset = asset
        }
    }

    private var popularSymbols: [String] {
        selectedKind == .stock
            ? ["AAPL", "TSLA", "NVDA", "MSFT", "GOOGL", "AMZN", "META", "NFLX"]
            : ["BTC", "ETH", "SOL", "ADA", "DOGE", "XRP"]
    }
}

// MARK: - Portfolio Search Result Row

struct PortfolioSearchResultRow: View {
    let symbol: String
    let name: String
    let exchange: String?
    let price: Double?
    let changePercent: Double?
    let isInPortfolio: Bool

    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 40, height: 40)
                Text(String(symbol.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(symbol).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                    if let exchange { Text(exchange).font(.caption).foregroundColor(.secondary) }
                }
                Text(name).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let price, let pct = changePercent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                    HStack(spacing: 3) {
                        Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(pct >= 0 ? "+" : "")\(String(format: "%.2f", pct))%")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(pct >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                }
            }
            Image(systemName: isInPortfolio ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(isInPortfolio ? .green : .blue)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isInPortfolio)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(colorScheme == .dark ? Color(UIColor.systemBackground) : Color(red: 0.980, green: 0.973, blue: 0.961))
        .contentShape(Rectangle())
    }
}

// MARK: - Portfolio Chart Range

enum PortfolioChartRange: String, CaseIterable {
    case oneWeek  = "1W"
    case oneMonth = "1M"
    case ytd      = "YTD"
    case oneYear  = "1Y"
    case twoYear  = "2Y"
    case fiveYear = "5Y"

    var displayLabel: String {
        switch self {
        case .oneWeek:  return "1 Week"
        case .oneMonth: return "1 Month"
        case .ytd:      return "Year to Date"
        case .oneYear:  return "1 Year"
        case .twoYear:  return "2 Years"
        case .fiveYear: return "5 Years"
        }
    }

    func filter(_ history: [PortfolioSnapshot]) -> [PortfolioSnapshot] {
        let now = Date()
        let cal = Calendar.current
        switch self {
        case .oneWeek:
            return history.filter { $0.date >= cal.date(byAdding: .day, value: -7, to: now) ?? now }
        case .oneMonth:
            return history.filter { $0.date >= cal.date(byAdding: .month, value: -1, to: now) ?? now }
        case .ytd:
            let startOfYear = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return history.filter { $0.date >= startOfYear }
        case .oneYear:
            return history.filter { $0.date >= cal.date(byAdding: .year, value: -1, to: now) ?? now }
        case .twoYear:
            return history.filter { $0.date >= cal.date(byAdding: .year, value: -2, to: now) ?? now }
        case .fiveYear:
            return history
        }
    }
}
