//
//  HomeView.swift
//  Stock Tracker
//

import SwiftUI
import Charts
import Combine

struct HomeView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var showSettings = false
    @State private var isSignedIn = false
    @State private var isDayTradeMode = false
    @State private var showSearchSheet = false
    @State private var showAlerts = false
    @State private var showNews = false
    @EnvironmentObject var insightService: AIInsightService
    @State private var dailyBriefing: String?
    @State private var briefingLoading = false

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 26) {

                        // Greeting + Settings Button
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(greetingLocalized())
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(theme.primaryText.opacity(0.9))

                                Text("Here's your market overview")
                                    .font(.largeTitle.bold())
                                    .foregroundColor(theme.primaryText)
                            }

                            Spacer()

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.title3)
                                    .foregroundColor(theme.primaryText)
                                    .frame(width: 44, height: 44)
                                    .background(theme.chartPlaceholder)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)

                        // Market Sentiment & Status
                        MarketSentimentView(
                            sentiment: marketData.marketSentiment,
                            lastUpdated: marketData.sentimentLastUpdated
                        )
                        .padding(.horizontal)

                        // AI Daily Briefing
                        dailyBriefingCard
                            .padding(.horizontal)

                        // Portfolio Card
                        CompactPortfolioCard()
                            .padding(.horizontal)

                        LiveIndicesWithGlow()
                            .padding(.horizontal)

                        QuickActionsGrid()
                            .padding(.horizontal)

                        WatchlistPreviewSection()
                            .padding(.horizontal)
                    }
                    .padding(.bottom, 60)
                }
                .refreshable { await marketData.refreshFromAPI() }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .background(theme.background.ignoresSafeArea())
            }

            .sheet(isPresented: $showSettings) {
                SettingsSheetView()
            }
        }
    }

    private var subscriptionBadge: some View {
        let theme = Theme(colorScheme: colorScheme)
        return HStack(spacing: 12) {
            Image(systemName: subscriptionManager.currentTier.icon)
                .font(.title3)
                .foregroundColor(subscriptionManager.currentTier.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscriptionManager.currentTier.displayName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                if subscriptionManager.currentTier == .free {
                    Text("Tap to upgrade")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text("Active subscription")
                        .font(.caption)
                        .foregroundColor(appTheme.positiveColor)
                }
            }

            Spacer()

            if subscriptionManager.currentTier == .free {
                Image(systemName: "arrow.right")
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: subscriptionManager.currentTier.gradientColors.map { $0.opacity(0.3) },
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(subscriptionManager.currentTier.color.opacity(0.5), lineWidth: 1)
        )
        .onTapGesture {
            if subscriptionManager.currentTier == .free {
                // Present paywall here
            }
        }
    }

    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Morning"
        case 12..<17: return "Afternoon"
        default:      return "Evening"
        }
    }

    private func greetingLocalized() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return String(localized: "Good Morning,")
        case 12..<17: return String(localized: "Good Afternoon,")
        default:      return String(localized: "Good Evening,")
        }
    }

    // MARK: - Daily AI Briefing

    private var dailyBriefingCard: some View {
        let tier = subscriptionManager.currentTier
        let isLocked = tier == .free
        let cacheKey = "daily_briefing_\(insightService.todayString)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? dailyBriefing
        return AIInsightCard(
            title: "Daily Briefing",
            icon: "sparkles",
            insightText: cachedText,
            isLoading: briefingLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadDailyBriefing() },
            onRegenerate: { await loadDailyBriefing(force: true) }
        )
    }

    private func loadDailyBriefing(force: Bool = false) async {
        briefingLoading = true
        defer { briefingLoading = false }

        let tier = subscriptionManager.currentTier
        let cacheKey = "daily_briefing_\(insightService.todayString)"

        // Build context from available data
        let sentiment = marketData.marketSentiment
        let portfolioMovers = marketData.portfolio
            .sorted { abs($0.asset.changePercent) > abs($1.asset.changePercent) }
            .prefix(3)
            .map { "\($0.asset.symbol) \(String(format: "%+.1f%%", $0.asset.changePercent))" }
            .joined(separator: ", ")

        let watchlistMovers = marketData.watchlist
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(3)
            .map { "\($0.symbol) \(String(format: "%+.1f%%", $0.changePercent))" }
            .joined(separator: ", ")

        let gainers = marketData.portfolio.filter { $0.asset.changePercent > 0 }.count
        let losers = marketData.portfolio.filter { $0.asset.changePercent < 0 }.count

        let systemPrompt = "You are a market analyst. Write a 2-sentence morning briefing. Be factual, no recommendations."
        let userPrompt = """
        Market sentiment: \(sentiment). \
        Portfolio: \(gainers) up, \(losers) down. Top movers: \(portfolioMovers.isEmpty ? "none" : portfolioMovers). \
        Watchlist highlights: \(watchlistMovers.isEmpty ? "none" : watchlistMovers). \
        Give a concise 2-sentence summary of today's market picture.
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .dailyBriefing,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .dailyBriefing,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { dailyBriefing = text }
    }
}

// MARK: - Compact Portfolio Card
struct CompactPortfolioCard: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @State private var focusedIndex: Int = 0

    private let cardTitles = ["Today", "All Time", "Holdings"]

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 0) {
            // Header — label updates with the active card
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portfolio")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                    Text(cardTitles[focusedIndex])
                        .font(.headline)
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .animation(.easeInOut(duration: 0.2), value: focusedIndex)
                }

                Spacer()

                Text(marketData.totalPortfolioValue.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Scrollable Cards
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        // Card 1: Daily P&L
                        DailyPLCard()
                            .frame(width: geometry.size.width - 48)
                            .focusCard(isFocused: focusedIndex == 0)
                            .id(0)

                        // Card 2: All-time unrealized P&L
                        AllTimePLCard()
                            .frame(width: geometry.size.width - 48)
                            .focusCard(isFocused: focusedIndex == 1)
                            .id(1)

                        // Card 3: Real top holdings
                        TopHoldingsCard()
                            .frame(width: geometry.size.width - 48)
                            .focusCard(isFocused: focusedIndex == 2)
                            .id(2)
                    }
                    .padding(.horizontal, 24)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: .init(get: { focusedIndex }, set: { newValue in
                    if let newValue = newValue as? Int {
                        focusedIndex = newValue
                    }
                }))
            }
            .frame(height: 200)

            // Page Indicator
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(focusedIndex == index ? theme.primaryText : theme.primaryText.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedIndex)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(theme.glassBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}



// MARK: - Mini Chart
struct PortfolioMiniChart: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.theme) var appTheme

    private var lineColor: Color { marketData.totalProfitLoss >= 0 ? appTheme.positiveColor : appTheme.negativeColor }

    var body: some View {
        Chart {
            ForEach(marketData.portfolioHistory) { snapshot in
                LineMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))

                AreaMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(
                    LinearGradient(colors: [lineColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}


// MARK: - Card 1: Daily P&L

struct DailyPLCard: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let daily = marketData.dailyProfitLoss
        let dailyPct = marketData.dailyProfitLossPercent
        let color = daily >= 0 ? appTheme.positiveColor : appTheme.negativeColor
        let isEmpty = marketData.portfolio.isEmpty

        VStack(spacing: 0) {
            Spacer()

            // Big P&L number
            Group {
                if isEmpty {
                    Text("No holdings")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text((daily >= 0 ? "+" : "") + daily.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                        .contentTransition(.numericText())
                }
            }

            // Percent badge
            if !isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: daily >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(String(format: "%+.2f%%", dailyPct))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .cornerRadius(8)
                .padding(.top, 6)
            }

            Spacer()

            // Per-holding breakdown (top 3)
            if !isEmpty {
                Divider().padding(.horizontal, -16)
                VStack(spacing: 6) {
                    ForEach(marketData.portfolio.sorted { abs($0.shares * $0.asset.change) > abs($1.shares * $1.asset.change) }.prefix(3)) { h in
                        let hDaily = h.shares * h.asset.change
                        let hColor = hDaily >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                        HStack {
                            Text(h.asset.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(theme.primaryText)
                            Spacer()
                            Text((hDaily >= 0 ? "+" : "") + hDaily.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(hColor)
                            Text(String(format: "%+.2f%%", h.asset.changePercent))
                                .font(.caption2)
                                .foregroundColor(hColor)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today's portfolio change: \(daily >= 0 ? "up" : "down") \(String(format: "%.2f", abs(daily))) dollars")
    }
}

// MARK: - Card 2: All-Time Unrealized P&L

struct AllTimePLCard: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let pl = marketData.totalProfitLoss
        let plPct = marketData.totalProfitLossPercent
        let color = pl >= 0 ? appTheme.positiveColor : appTheme.negativeColor
        let isEmpty = marketData.portfolio.isEmpty

        VStack(spacing: 0) {
            Spacer()

            Group {
                if isEmpty {
                    Text("Add holdings to\nsee P&L")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text((pl >= 0 ? "+" : "") + pl.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                        .contentTransition(.numericText())
                }
            }

            if !isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: pl >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(String(format: "%+.2f%%", plPct))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .cornerRadius(8)
                .padding(.top, 6)

                Text("vs. cost basis")
                    .font(.caption2)
                    .foregroundColor(theme.secondaryText)
                    .padding(.top, 2)
            }

            Spacer()

            // Cost basis vs current
            if !isEmpty {
                Divider().padding(.horizontal, -16)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invested")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                        Text(marketData.totalCostBasis.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Current")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                        Text(marketData.totalPortfolioValue.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All time unrealized gain loss: \(pl >= 0 ? "up" : "down") \(String(format: "%.2f", abs(plPct))) percent")
    }
}

// MARK: - Card 3: Top Holdings (real data)

struct TopHoldingsCard: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private let pallete: [Color] = [.blue, .green, .orange, .purple, .pink]

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let sorted = marketData.portfolio.sorted { $0.currentValue > $1.currentValue }
        let total = marketData.totalPortfolioValue

        VStack(alignment: .leading, spacing: 10) {
            if sorted.isEmpty {
                Spacer()
                Text("No holdings yet")
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(Array(sorted.prefix(4).enumerated()), id: \.offset) { i, h in
                    let pct = total > 0 ? h.currentValue / total * 100 : 0
                    let color = pallete[i % pallete.count]
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(h.asset.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        // Mini bar
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color.opacity(0.25))
                                .frame(width: g.size.width)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color)
                                        .frame(width: g.size.width * CGFloat(pct / 100), alignment: .leading),
                                    alignment: .leading
                                )
                        }
                        .frame(width: 60, height: 6)
                        Text(String(format: "%.0f%%", pct))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                if sorted.count > 4 {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text("Others (\(sorted.count - 4) more)")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        let othersPct = sorted.dropFirst(4).reduce(0) { $0 + ($1.currentValue / max(total, 1) * 100) }
                        Text(String(format: "%.0f%%", othersPct))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Rest remains the same (LiveIndicesWithGlow, GlowingIndexCard, QuickActionsGrid, etc.)
struct LiveIndicesWithGlow: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @State private var indices: [MarketIndex] = []
    @State private var isLoading = true

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Indices")
                .font(.title2.bold())
                .foregroundColor(theme.primaryText)
                .padding(.horizontal)

            if isLoading {
                // Skeleton index cards
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(0..<4) { _ in
                            skeletonIndexCard
                                .frame(width: 210)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(indices) { index in
                            GlowingIndexCard(index: index)
                                .frame(width: 210)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .task { await loadIndices() }
    }

    private var skeletonIndexCard: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 80, height: 12)
                        .shimmering()

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 120, height: 16)
                        .shimmering()
                }
                Spacer()
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .shimmering()
            }

            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 28)
                    .shimmering()

                Spacer()

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 24)
                    .shimmering()
            }

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 60)
                .shimmering()
        }
        .padding(20)
        .frame(height: 170)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.separator, lineWidth: 1))
        .shimmering()
    }

    private func loadIndices() async {
        isLoading = true

        struct IndexSpec {
            let name: String
            let identifier: String
            let kind: AssetKind
            let displaySymbol: String
        }

        // Use real API-supported tickers: ETF proxies for indices via Alpaca,
        // CoinGecko IDs for crypto. No Yahoo Finance-style tickers (^GSPC etc).
        let specs: [IndexSpec] = [
            .init(name: "S&P 500",      identifier: "SPY",      kind: .stock,  displaySymbol: "SPY"),
            .init(name: "Nasdaq",        identifier: "QQQ",      kind: .stock,  displaySymbol: "QQQ"),
            .init(name: "Dow Jones",     identifier: "DIA",      kind: .stock,  displaySymbol: "DIA"),
            .init(name: "Bitcoin",       identifier: "bitcoin",  kind: .crypto, displaySymbol: "BTC"),
            .init(name: "Ethereum",      identifier: "ethereum", kind: .crypto, displaySymbol: "ETH"),
            .init(name: "Gold",          identifier: "GLD",      kind: .stock,  displaySymbol: "GLD"),
            .init(name: "Oil",           identifier: "USO",      kind: .stock,  displaySymbol: "USO"),
            .init(name: "Russell 2000",  identifier: "IWM",      kind: .stock,  displaySymbol: "IWM"),
        ]

        // Fetch all concurrently; preserve display order even if some fail
        var ordered: [(Int, MarketIndex)] = []
        await withTaskGroup(of: (Int, MarketIndex?).self) { group in
            for (i, spec) in specs.enumerated() {
                group.addTask { [marketData] in
                    do {
                        let asset = try await APIService.shared.fetchAssetDetails(
                            identifier: spec.identifier,
                            kind: spec.kind,
                            name: spec.name
                        )
                        let points = await marketData.fetchMiniChartHistory(for: asset)
                        let sparkline = points.map(\.price)
                        return (i, MarketIndex(
                            name: spec.name,
                            symbol: spec.displaySymbol,
                            price: asset.price,
                            change: asset.change,
                            changePercent: asset.changePercent,
                            sparkline: sparkline
                        ))
                    } catch {
                        return (i, nil)
                    }
                }
            }
            for await (i, result) in group {
                if let result { ordered.append((i, result)) }
            }
        }

        let sorted = ordered.sorted { $0.0 < $1.0 }.map { $0.1 }

        await MainActor.run {
            motionSafeWithAnimation(.easeInOut) {
                self.indices = sorted
                self.isLoading = false
            }
        }
    }
    }



struct GlowingIndexCard: View {
    let index: MarketIndex
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var lineColor: Color { index.isPositive ? appTheme.positiveColor : appTheme.negativeColor }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(index.symbol)
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(index.name)
                        .font(.subheadline.bold())
                        .foregroundColor(theme.primaryText)
                }
                Spacer()
                Image(systemName: index.isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                    .foregroundColor(lineColor)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Text(index.price, format: .number.precision(.fractionLength(index.price > 1000 ? 0 : 2)))
                    .font(.title2.bold())
                    .foregroundColor(theme.primaryText)

                Text("\(index.isPositive ? "+" : "")\(String(format: "%.2f", index.changePercent))%")
                    .font(.title3.bold())
                    .foregroundColor(lineColor)
            }

            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                let prices = index.sparkline

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
                    .shadow(color: colorScheme == .dark ? lineColor.opacity(0.6) : lineColor.opacity(0.06), radius: 8)
                    .shadow(color: colorScheme == .dark ? lineColor.opacity(0.4) : Color.clear, radius: 16)
                    .shadow(color: colorScheme == .dark ? lineColor.opacity(0.3) : Color.clear, radius: 24)
                } else {
                    // Fallback: directional trend line when no data yet
                    let pts = 35
                    let step = w / CGFloat(pts - 1)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h / 2))
                        for i in 1..<pts {
                            let x = CGFloat(i) * step
                            let progress = Double(i) / Double(pts - 1)
                            let trend = index.isPositive ? progress : (1 - progress)
                            let y = h * 0.5 - (trend * h * 0.35)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(lineColor.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .frame(height: 60)
        }
        .padding(20)
        .frame(height: 170)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(lineColor.opacity(0.4), lineWidth: 2)
                .shadow(color: colorScheme == .dark ? lineColor.opacity(0.6) : Color.clear, radius: 15)
                .shadow(color: colorScheme == .dark ? lineColor.opacity(0.4) : Color.clear, radius: 30)
        )
        .shadow(color: colorScheme == .dark ? lineColor.opacity(0.3) : lineColor.opacity(0.06), radius: 20, x: 0, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(FinancialAccessibility.priceChangeDescription(
            symbol: index.name,
            price: index.price,
            change: index.change,
            changePercent: index.changePercent
        ))
    }
}

struct QuickActionsGrid: View {
    @EnvironmentObject var marketData: MarketData
    @State private var showSearchSheet = false
    @State private var showAlerts = false
    @State private var showNews = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            QuickActionButton(title: "Add Stock", icon: "plus.circle.fill", color: .blue) {
                showSearchSheet = true
            }
            QuickActionButton(title: "Price Alerts", icon: "bell.fill", color: .purple) {
                showAlerts = true
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheet(kind: .stock)
        }
        .sheet(isPresented: $showAlerts) {
            PriceAlertsSheet()
        }
        .sheet(isPresented: $showNews) {
            NewsView()
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(theme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(theme.glassBackground)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct WatchlistPreviewSection: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @State private var isLoading = true

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Watchlist")
                    .font(.title3.bold())
                    .foregroundColor(theme.primaryText)
                Spacer()
                NavigationLink("See Watchlist") { AppleStocksWatchlistView() }
                    .foregroundColor(.blue)
            }

            if marketData.watchlist.isEmpty && isLoading {
                // Skeleton cards
                ForEach(0..<5) { _ in
                    skeletonWatchlistRow
                }
            } else if marketData.watchlist.isEmpty {
                Text("No assets in watchlist yet")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(theme.chartPlaceholder)
                    .cornerRadius(12)
            } else {
                ForEach(marketData.watchlist.prefix(5)) { asset in
                    WatchlistRowPreview(asset: asset)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                motionSafeWithAnimation {
                                    marketData.removeFromWatchlist(asset)
                                }
                            } label: {
                                Label("Remove", systemImage: "trash.fill")
                            }
                        }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                motionSafeWithAnimation {
                    isLoading = false
                }
            }
        }
    }

    private var skeletonWatchlistRow: some View {
        let theme = Theme(colorScheme: colorScheme)
        return HStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 50, height: 50)
                .shimmering()

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 16)
                    .shimmering()

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 160, height: 12)
                    .shimmering()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 90, height: 20)
                    .shimmering()

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 16)
                    .shimmering()
            }
        }
        .padding()
        .background(theme.chartPlaceholder)
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

struct WatchlistRowPreview: View {
    let asset: Asset
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack {
            VStack(alignment: .leading) {
                Text(asset.symbol).font(.headline).foregroundColor(theme.primaryText)
                Text(asset.name).font(.caption).foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                GainLossIndicator(value: asset.changePercent)
            }
        }
        .padding()
        .background(theme.chartPlaceholder)
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(FinancialAccessibility.priceChangeDescription(
            symbol: asset.symbol,
            price: asset.price,
            change: asset.change,
            changePercent: asset.changePercent
        ))
    }
}

#Preview {
    HomeView()
        .environmentObject(MarketData())
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(ThemeManager())
}
