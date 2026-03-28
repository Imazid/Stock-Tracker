//
//  PortfolioIntelligenceView.swift
//  Stock Tracker
//
//  Fully redesigned — glass cards, gradient tab pills, progress bars, hero metrics.
//

import SwiftUI
import Charts

// MARK: - Intelligence Tab

enum IntelligenceTab: String, CaseIterable, Identifiable {
    case allocation  = "Allocation"
    case performance = "Performance"
    case dividends   = "Dividends"
    case benchmark   = "Benchmark"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .allocation:  return "chart.pie.fill"
        case .performance: return "chart.line.uptrend.xyaxis"
        case .dividends:   return "dollarsign.circle.fill"
        case .benchmark:   return "chart.bar.fill"
        }
    }

    var accent: Color {
        switch self {
        case .allocation:  return .blue
        case .performance: return .purple
        case .dividends:   return .green
        case .benchmark:   return .orange
        }
    }

    var gradient: [Color] {
        switch self {
        case .allocation:  return [Color(red: 0.18, green: 0.40, blue: 1.00), Color(red: 0.00, green: 0.78, blue: 0.92)]
        case .performance: return [Color(red: 0.58, green: 0.18, blue: 1.00), Color(red: 1.00, green: 0.28, blue: 0.60)]
        case .dividends:   return [Color(red: 0.08, green: 0.72, blue: 0.42), Color(red: 0.00, green: 0.84, blue: 0.70)]
        case .benchmark:   return [Color(red: 1.00, green: 0.48, blue: 0.00), Color(red: 1.00, green: 0.78, blue: 0.00)]
        }
    }
}

// MARK: - PortfolioIntelligenceView

struct PortfolioIntelligenceView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedTab: IntelligenceTab = .allocation

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Pinned gradient tab bar
                tabBar(theme: theme)
                    .padding(.vertical, 14)
                    .background(theme.background.shadow(.drop(color: .black.opacity(0.04), radius: 8, y: 4)))

                // Scrollable content
                ScrollView(showsIndicators: false) {
                    Group {
                        switch selectedTab {
                        case .allocation:
                            if subscriptionManager.currentTier.hasPortfolioAccess {
                                AllocationSection()
                            } else {
                                FeatureLockView(featureName: "Portfolio Allocation", requiredTier: .pro)
                                    .environmentObject(subscriptionManager)
                                    .frame(maxWidth: .infinity, minHeight: 300)
                            }
                        case .performance:
                            if subscriptionManager.currentTier.hasPortfolioAccess {
                                PerformanceSection()
                            } else {
                                FeatureLockView(featureName: "Performance Analytics", requiredTier: .pro)
                                    .environmentObject(subscriptionManager)
                                    .frame(maxWidth: .infinity, minHeight: 300)
                            }
                        case .dividends:
                            if subscriptionManager.currentTier.hasPortfolioAccess {
                                DividendsSection()
                            } else {
                                FeatureLockView(featureName: "Dividend Tracker", requiredTier: .pro)
                                    .environmentObject(subscriptionManager)
                                    .frame(maxWidth: .infinity, minHeight: 300)
                            }
                        case .benchmark:
                            if subscriptionManager.currentTier.hasPortfolioBenchmark {
                                BenchmarkSection()
                            } else {
                                FeatureLockView(featureName: "Portfolio Benchmark", requiredTier: .black)
                                    .environmentObject(subscriptionManager)
                                    .frame(maxWidth: .infinity, minHeight: 300)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 48)
                    .id(selectedTab.rawValue)   // force view identity reset on tab switch
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selectedTab)
            }
        }
        .navigationTitle("Portfolio Analysis")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Tab Bar

    private func tabBar(theme: Theme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(IntelligenceTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .bold))
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(
                            Group {
                                if selectedTab == tab {
                                    LinearGradient(colors: tab.gradient, startPoint: .leading, endPoint: .trailing)
                                } else {
                                    LinearGradient(colors: [theme.glassBackground, theme.glassBackground], startPoint: .leading, endPoint: .trailing)
                                }
                            }
                        )
                        .foregroundColor(selectedTab == tab ? .white : .secondary)
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(selectedTab == tab ? Color.clear : theme.glassBorder, lineWidth: 1)
                        )
                        .shadow(color: selectedTab == tab ? tab.accent.opacity(colorScheme == .dark ? 0.38 : 0.04) : .clear, radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Allocation Section

struct AllocationSection: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var insightService: AIInsightService
    @Environment(\.colorScheme) var colorScheme

    @State private var diversificationText: String?
    @State private var diversificationLoading = false

    private var totalValue: Double { marketData.portfolio.reduce(0) { $0 + $1.currentValue } }

    private var typeAllocation: [(label: String, pct: Double, color: Color)] {
        guard totalValue > 0 else { return [] }
        let stocks = marketData.portfolio.filter { $0.asset.kind == .stock  }.reduce(0) { $0 + $1.currentValue }
        let crypto = marketData.portfolio.filter { $0.asset.kind == .crypto }.reduce(0) { $0 + $1.currentValue }
        var out: [(String, Double, Color)] = []
        if stocks > 0 { out.append(("Stocks", stocks / totalValue * 100, .blue)) }
        if crypto > 0 { out.append(("Crypto", crypto / totalValue * 100, .orange)) }
        return out
    }

    private var topHoldings: [PortfolioHolding] {
        marketData.portfolio.sorted { $0.currentValue > $1.currentValue }.prefix(7).map { $0 }
    }

    private func pct(_ h: PortfolioHolding) -> Double {
        totalValue > 0 ? h.currentValue / totalValue * 100 : 0
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 16) {
            if marketData.portfolio.isEmpty {
                intelEmptyState(icon: "chart.pie", title: "No Holdings", message: "Add holdings to see how your portfolio is allocated across assets.", accent: .blue)
            } else {
                donutCard(theme: theme)
                if SubscriptionManager.shared.currentTier != .free {
                    diversificationCard
                }
                topHoldingsCard(theme: theme)
            }
        }
    }

    // MARK: Diversification AI Card

    private var diversificationCard: some View {
        let tier = SubscriptionManager.shared.currentTier
        let isLocked = tier == .free
        let cacheKey = "diversification_score"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? diversificationText
        return AIInsightCard(
            title: "Diversification Score",
            icon: "chart.pie.fill",
            insightText: cachedText,
            isLoading: diversificationLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadDiversificationScore() },
            onRegenerate: { await loadDiversificationScore(force: true) }
        )
    }

    private func loadDiversificationScore(force: Bool = false) async {
        diversificationLoading = true
        defer { diversificationLoading = false }

        let tier = SubscriptionManager.shared.currentTier
        let cacheKey = "diversification_score"

        let holdings = marketData.portfolio
        let total = holdings.reduce(0.0) { $0 + $1.currentValue }
        guard total > 0 else { return }

        let stockCount = holdings.filter { $0.asset.kind == .stock }.count
        let cryptoCount = holdings.filter { $0.asset.kind == .crypto }.count
        let stockPct = holdings.filter { $0.asset.kind == .stock }.reduce(0.0) { $0 + $1.currentValue } / total * 100
        let cryptoPct = 100 - stockPct

        let top5 = holdings.sorted { $0.currentValue > $1.currentValue }.prefix(5)
        let top5Summary = top5.map { h in
            "\(h.asset.symbol) \(String(format: "%.1f", h.currentValue / total * 100))%"
        }.joined(separator: ", ")

        let topConcentration = (top5.reduce(0.0) { $0 + $1.currentValue } / total) * 100

        let systemPrompt = "You are a portfolio diversification analyst. Rate the diversification from 1-10 and give 2-3 sentences of actionable advice. Mention concentration risk if the top holding exceeds 30%."
        let userPrompt = """
        Portfolio: \(holdings.count) holdings (\(stockCount) stocks, \(cryptoCount) crypto). \
        Stocks \(String(format: "%.0f", stockPct))%, Crypto \(String(format: "%.0f", cryptoPct))%. \
        Top 5: \(top5Summary). Top 5 concentration: \(String(format: "%.0f", topConcentration))%. \
        Rate diversification and suggest improvements.
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .diversificationScore,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .diversificationScore,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { diversificationText = text }
    }

    // MARK: Donut card

    private func donutCard(theme: Theme) -> some View {
        VStack(spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Asset Allocation")
                        .font(.title3.bold())
                    Text("\(marketData.portfolio.count) holdings · \(typeAllocation.count) asset types")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .center, spacing: 24) {
                // Donut + total value label
                ZStack {
                    Chart(typeAllocation, id: \.label) { item in
                        SectorMark(
                            angle: .value("Pct", item.pct),
                            innerRadius: .ratio(0.62),
                            angularInset: 3.5
                        )
                        .foregroundStyle(item.color)
                        .cornerRadius(5)
                    }
                    .frame(width: 164, height: 164)

                    VStack(spacing: 4) {
                        Text("Total").font(.caption2).foregroundColor(.secondary)
                        Text("$\(Int(totalValue).formatted())")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                    }
                }

                // Legend with animated bars
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(typeAllocation, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(item.color)
                                    .frame(width: 10, height: 10)
                                Text(item.label)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(String(format: "%.1f%%", item.pct))
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(item.color.opacity(0.15)).frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(LinearGradient(colors: [item.color, item.color.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geo.size.width * item.pct / 100, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
    }

    // MARK: Top holdings card

    private func topHoldingsCard(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Top Holdings")
                    .font(.title3.bold())
                Spacer()
                Text("\(topHoldings.count) of \(marketData.portfolio.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.glassBackground)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
            }

            // Mini donut + legend row
            HStack(alignment: .center, spacing: 22) {
                let chartData = topHoldings.enumerated().map { (i, h) in
                    (h.asset.symbol, pct(h), holdingPalette[i % holdingPalette.count])
                }
                ZStack {
                    Chart(chartData, id: \.0) { item in
                        SectorMark(angle: .value("V", item.1), innerRadius: .ratio(0.58), angularInset: 2.5)
                            .foregroundStyle(item.2).cornerRadius(4)
                    }
                    .frame(width: 120, height: 120)
                    Text("\(topHoldings.count)")
                        .font(.title3.bold())
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(topHoldings.enumerated()), id: \.1.id) { i, h in
                        HStack(spacing: 8) {
                            Circle().fill(holdingPalette[i % holdingPalette.count]).frame(width: 7, height: 7)
                            Text(h.asset.symbol).font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.1f%%", pct(h)))
                                .font(.caption.weight(.medium)).foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                    if marketData.portfolio.count > 7 {
                        let other = max(0, 100 - topHoldings.reduce(0) { $0 + pct($1) })
                        HStack(spacing: 8) {
                            Circle().fill(Color.gray.opacity(0.35)).frame(width: 7, height: 7)
                            Text("Other").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f%%", other))
                                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Holdings list with allocation bars
            ForEach(Array(topHoldings.enumerated()), id: \.1.id) { i, h in
                let color = holdingPalette[i % holdingPalette.count]
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(color.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Text(String(h.asset.symbol.prefix(2)))
                                .font(.caption.weight(.bold))
                                .foregroundColor(color)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.asset.symbol).font(.subheadline.weight(.semibold))
                            Text(h.asset.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("$\(Int(h.currentValue).formatted())")
                                .font(.subheadline.weight(.bold)).monospacedDigit()
                            Text(String(format: "%.1f%%", pct(h)))
                                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.1)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [color, color.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, geo.size.width * pct(h) / 100), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                if i < topHoldings.count - 1 { Divider() }
            }
        }
        .padding(22)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
    }
}

// MARK: - Performance Section

struct PerformanceSection: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var sortedByGain: [PortfolioHolding] {
        marketData.portfolio.sorted { $0.profitLossPercent > $1.profitLossPercent }
    }
    private var isProfit: Bool { marketData.totalProfitLoss >= 0 }
    private var maxAbsPct: Double {
        marketData.portfolio.map { abs($0.profitLossPercent) }.max() ?? 1
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 16) {
            if marketData.portfolio.isEmpty {
                intelEmptyState(icon: "chart.line.uptrend.xyaxis", title: "No Holdings", message: "Add holdings to track your performance and P&L.", accent: .purple)
            } else {
                heroPLCard
                holdingsPLCard(theme: theme)
                if sortedByGain.count > 1 {
                    performersRow(theme: theme)
                }
            }
        }
    }

    // MARK: Hero P&L

    private var heroPLCard: some View {
        let plColor: Color = isProfit
            ? Color(red: 0.08, green: 0.72, blue: 0.42)
            : Color(red: 0.82, green: 0.18, blue: 0.18)
        let gradColors: [Color] = isProfit
            ? [Color(red: 0.06, green: 0.60, blue: 0.34), Color(red: 0.00, green: 0.48, blue: 0.38)]
            : [Color(red: 0.78, green: 0.14, blue: 0.14), Color(red: 0.60, green: 0.08, blue: 0.20)]

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                // Left: big P&L number
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unrealized Return")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.72))

                    Text("\(isProfit ? "+" : "-")$\(String(format: "%.2f", abs(marketData.totalProfitLoss)))")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)

                    HStack(spacing: 5) {
                        Image(systemName: isProfit ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption.weight(.bold))
                        Text(String(format: "%@%.2f%%", isProfit ? "+" : "", marketData.totalProfitLossPercent))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())
                }

                Spacer()

                // Right: basis + value
                VStack(alignment: .trailing, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Cost Basis")
                            .font(.caption).foregroundColor(.white.opacity(0.68))
                        Text("$\(Int(marketData.totalCostBasis).formatted())")
                            .font(.headline.weight(.bold)).monospacedDigit().foregroundColor(.white)
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Market Value")
                            .font(.caption).foregroundColor(.white.opacity(0.68))
                        Text("$\(Int(marketData.totalPortfolioValue).formatted())")
                            .font(.headline.weight(.bold)).monospacedDigit().foregroundColor(.white)
                    }
                }
            }
            .padding(22)
        }
        .background(LinearGradient(colors: gradColors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .cornerRadius(22)
        .shadow(color: plColor.opacity(colorScheme == .dark ? 0.32 : 0.04), radius: 18, y: 9)
    }

    // MARK: Holdings P&L list

    private func holdingsPLCard(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Holdings P&L")
                .font(.title3.bold())

            ForEach(sortedByGain) { h in
                let isPos = h.profitLoss >= 0
                let barColor: Color = isPos ? appTheme.positiveColor : appTheme.negativeColor
                let fraction = maxAbsPct > 0 ? abs(h.profitLossPercent) / maxAbsPct : 0

                VStack(spacing: 7) {
                    HStack(spacing: 12) {
                        // Colored magnitude bar
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(LinearGradient(colors: [barColor, barColor.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 4, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.asset.symbol).font(.subheadline.weight(.semibold))
                            Text(String(format: "%.4g shares", h.shares))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(isPos ? "+" : "-")$\(String(format: "%.2f", abs(h.profitLoss)))")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(barColor)
                                .monospacedDigit()
                            Text(String(format: "%@%.2f%%", isPos ? "+" : "", h.profitLossPercent))
                                .font(.caption.weight(.bold))
                                .foregroundColor(barColor)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(barColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    // Relative magnitude bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(barColor.opacity(0.1)).frame(height: 3)
                            RoundedRectangle(cornerRadius: 2).fill(barColor.opacity(0.55))
                                .frame(width: max(0, geo.size.width * fraction), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.leading, 16)
                }

                if h.id != sortedByGain.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .padding(22)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
    }

    // MARK: Performers row

    private func performersRow(theme: Theme) -> some View {
        HStack(spacing: 12) {
            performerCell(label: "Best Performer", holding: sortedByGain.first!, color: appTheme.positiveColor, icon: "arrow.up.right", theme: theme)
            performerCell(label: "Worst Performer", holding: sortedByGain.last!, color: appTheme.negativeColor, icon: "arrow.down.right", theme: theme)
        }
    }

    private func performerCell(label: String, holding: PortfolioHolding, color: Color, icon: String, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2.weight(.bold)).foregroundColor(color)
                Text(label).font(.caption.weight(.medium)).foregroundColor(.secondary)
            }
            Text(holding.asset.symbol).font(.title2.weight(.bold))
            Text(holding.asset.name).font(.caption).foregroundColor(.secondary).lineLimit(1)

            Text(String(format: "%@%.2f%%", holding.profitLossPercent >= 0 ? "+" : "", holding.profitLossPercent))
                .font(.subheadline.weight(.bold))
                .foregroundColor(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Dividends Section

struct DividendsSection: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var dividendHoldings: [(PortfolioHolding, Double)] {
        marketData.portfolio.compactMap { h in
            guard let div = h.asset.dividend, div > 0 else { return nil }
            return (h, (div / 100.0) * h.currentValue)
        }
        .sorted { $0.1 > $1.1 }
    }

    private var totalAnnual: Double { dividendHoldings.reduce(0) { $0 + $1.1 } }

    private var avgYield: Double {
        let divTotal = dividendHoldings.reduce(0.0) { $0 + $1.0.currentValue }
        return divTotal > 0 ? totalAnnual / divTotal * 100 : 0
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 16) {
            if dividendHoldings.isEmpty {
                intelEmptyState(
                    icon: "dollarsign.circle",
                    title: "No Dividend Data",
                    message: "Dividend data loads when you view a stock's detail page. Open a dividend-paying holding to populate yield data, then return here.",
                    accent: .green
                )
            } else {
                incomeBanner
                holdingsList(theme: theme)
            }
        }
    }

    private var incomeBanner: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Est. Annual Income")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.72))
                Text("$\(String(format: "%.2f", totalAnnual))")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.caption).foregroundColor(.white.opacity(0.8))
                    Text("$\(String(format: "%.2f", totalAnnual / 12)) per month")
                        .font(.subheadline).foregroundColor(.white.opacity(0.88))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Avg Yield").font(.caption).foregroundColor(.white.opacity(0.68))
                    Text(String(format: "%.2f%%", avgYield))
                        .font(.title2.weight(.bold)).foregroundColor(.white)
                }
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Positions").font(.caption).foregroundColor(.white.opacity(0.68))
                    Text("\(dividendHoldings.count)").font(.title3.weight(.bold)).foregroundColor(.white)
                }
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.62, blue: 0.36), Color(red: 0.00, green: 0.52, blue: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .cornerRadius(22)
        .shadow(color: Color.green.opacity(colorScheme == .dark ? 0.30 : 0.04), radius: 18, y: 9)
    }

    private func holdingsList(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dividend Holdings").font(.title3.bold())

            ForEach(dividendHoldings, id: \.0.id) { h, annual in
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color.green.opacity(0.22), Color.teal.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 46, height: 46)
                        Text(String(h.asset.symbol.prefix(2)))
                            .font(.caption.weight(.bold))
                            .foregroundColor(appTheme.positiveColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.asset.symbol).font(.subheadline.weight(.semibold))
                        Text(String(format: "%.2f%% yield", h.asset.dividend ?? 0))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(annual.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates) + "/yr")
                            .font(.subheadline.weight(.bold)).foregroundColor(appTheme.positiveColor).monospacedDigit()
                        Text((annual / 12).formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates) + "/mo")
                            .font(.caption).foregroundColor(.secondary).monospacedDigit()
                    }
                }
                .padding(14)
                .background(Color.green.opacity(0.06))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.15), lineWidth: 1))
            }
        }
        .padding(22)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
    }
}

// MARK: - Benchmark Section

struct BenchmarkSection: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var portfolioReturn: Double { marketData.totalProfitLossPercent }

    private var sp500Return: Double {
        let h = marketData.sp500History
        guard h.count >= 2, let first = h.first, let last = h.last, first.price > 0 else { return 0 }
        return ((last.price - first.price) / first.price) * 100
    }

    private var isOutperforming: Bool { portfolioReturn > sp500Return }
    private var diff: Double { portfolioReturn - sp500Return }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 16) {
            comparisonCards(theme: theme)
            if marketData.sp500History.isEmpty {
                // Error / retry UI when S&P 500 data failed to load
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("S&P 500 data unavailable")
                        .font(.subheadline.weight(.medium))
                    Text("Benchmark chart requires market history data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await marketData.fetchSP500History() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .background(theme.glassBackground)
                .cornerRadius(22)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
            } else {
                chartCard(theme: theme)
            }
            insightCard(theme: theme)
        }
    }

    // MARK: Comparison cards

    private func comparisonCards(theme: Theme) -> some View {
        HStack(spacing: 12) {
            returnCard(
                title: "Your Portfolio",
                value: portfolioReturn,
                subtitle: "Total Return",
                dotColor: .blue,
                isWinner: isOutperforming,
                theme: theme
            )
            returnCard(
                title: "S&P 500 (SPY)",
                value: sp500Return,
                subtitle: "Same Period",
                dotColor: .gray,
                isWinner: !isOutperforming,
                theme: theme
            )
        }
    }

    private func returnCard(title: String, value: Double, subtitle: String, dotColor: Color, isWinner: Bool, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.medium)).foregroundColor(.secondary)
            }

            let sign = value >= 0 ? "+" : ""
            Text("\(sign)\(String(format: "%.2f", value))%")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(value >= 0 ? appTheme.positiveColor : appTheme.negativeColor)

            Text(subtitle).font(.caption).foregroundColor(.secondary)

            if isWinner {
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill").font(.system(size: 8)).foregroundColor(.orange)
                    Text("Leading").font(.caption2.weight(.bold)).foregroundColor(.orange)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(theme.glassBackground)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isWinner ? dotColor.opacity(0.4) : theme.cardBorder, lineWidth: isWinner ? 1.5 : 0.5)
        )
        .shadow(color: isWinner ? dotColor.opacity(colorScheme == .dark ? 0.12 : 0.04) : .clear, radius: 10, y: 4)
    }

    // MARK: Chart card

    private func chartCard(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("S&P 500 History")
                    .font(.title3.bold())
                Spacer()
                Text("Indexed to 100")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.glassBackground)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
            }

            let spy = marketData.sp500History
            let base = spy.first?.price ?? 1
            let portLine = (portfolioReturn / 100 + 1) * 100

            // Compute explicit Y domain so the chart auto-scales to all data
            let spNormalized = spy.map { ($0.price / base) * 100 }
            let allYValues = spNormalized + [portLine, 100]
            let yMin = (allYValues.min() ?? 90) - 2
            let yMax = (allYValues.max() ?? 110) + 2

            Chart {
                ForEach(spy) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value("S&P 500", (pt.price / base) * 100)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)

                    AreaMark(
                        x: .value("Date", pt.date),
                        y: .value("S&P 500", (pt.price / base) * 100)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [Color.secondary.opacity(0.1), Color.secondary.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .interpolationMethod(.linear)
                }

                RuleMark(y: .value("Portfolio", portLine))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundStyle(.blue)
                    .annotation(position: .trailing) {
                        Text("You").font(.caption2.weight(.bold)).foregroundColor(.blue).padding(.leading, 2)
                    }

                RuleMark(y: .value("Base", 100))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.3))
            }
            .chartYScale(domain: yMin...yMax)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(.caption2).foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let v = val.as(Double.self) {
                            Text(String(format: "%.0f", v)).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(height: 200)
            .clipped()

            HStack(spacing: 16) {
                legendItem(color: .secondary, label: "S&P 500", dashed: false)
                legendItem(color: .blue, label: "Your Return", dashed: true)
            }
        }
        .padding(22)
        .background(theme.glassBackground)
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.cardBorder, lineWidth: 0.5))
    }

    private func legendItem(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 5, height: 2)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 16, height: 2)
            }
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: Insight card

    private func insightCard(theme: Theme) -> some View {
        let accent: Color = isOutperforming ? .green : .orange
        return HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(accent.opacity(0.12)).frame(width: 46, height: 46)
                Image(systemName: isOutperforming ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                    .font(.title3.weight(.semibold)).foregroundColor(accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(isOutperforming ? "Outperforming the Market" : "Underperforming the Market")
                    .font(.subheadline.weight(.bold))
                if marketData.portfolio.isEmpty {
                    Text("Add holdings to compare your returns with the S&P 500.")
                        .font(.caption).foregroundColor(.secondary)
                } else if isOutperforming {
                    Text(String(format: "Your %.2f%% return beats the S&P 500's %.2f%% by %.2f points.", portfolioReturn, sp500Return, diff))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(String(format: "Your %.2f%% return trails the S&P 500's %.2f%% by %.2f points.", portfolioReturn, sp500Return, abs(diff)))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(18)
        .background(accent.opacity(0.08))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Shared empty state

private func intelEmptyState(icon: String, title: String, message: String, accent: Color) -> some View {
    VStack(spacing: 22) {
        ZStack {
            Circle()
                .fill(accent.opacity(0.10))
                .frame(width: 110, height: 110)
                .blur(radius: 24)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(accent.opacity(0.55))
        }
        VStack(spacing: 8) {
            Text(title).font(.title3.bold())
            Text(message)
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
        }
    }
    .frame(maxWidth: .infinity)
    .padding(52)
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PortfolioIntelligenceView()
            .environmentObject(MarketData())
    }
}
