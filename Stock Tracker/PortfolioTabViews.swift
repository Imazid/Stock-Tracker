//  PortfolioTabViews.swift
//  Stock Tracker
//  Performance, Dividends, and Benchmark tab content views for the portfolio page.

import SwiftUI
import Charts

// MARK: - PortfolioPerformanceTabView

struct PortfolioPerformanceTabView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.theme) var appTheme
    @Environment(\.colorScheme) var colorScheme

    // MARK: Private Computed

    private var sortedHoldings: [PortfolioHolding] {
        marketData.portfolio.sorted { $0.profitLossPercent > $1.profitLossPercent }
    }

    private var bestPerformer: PortfolioHolding? { sortedHoldings.first }
    private var worstPerformer: PortfolioHolding? { sortedHoldings.count > 1 ? sortedHoldings.last : nil }

    // MARK: - Body

    var body: some View {
        LazyVStack(spacing: 16) {
            returnSummaryCard
            if sortedHoldings.count >= 2 {
                performersRow
            }
            if !sortedHoldings.isEmpty {
                holdingsCard
            }
        }
        .padding(16)
    }

    // MARK: - Return Summary Card

    private var returnSummaryCard: some View {
        let plPercent = marketData.totalProfitLossPercent
        let plDollar  = marketData.totalProfitLoss
        let plColor: Color = plPercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor

        return VStack(alignment: .leading, spacing: 8) {
            Text("Total Return")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(String(format: "%+.2f%%", plPercent))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundColor(plColor)
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 6) {
                Text(marketData.formatPrice(plDollar))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(plColor)
                    .monospacedDigit()
                Text("·")
                    .foregroundColor(Color(.systemGray3))
                Text("on \(marketData.formatPrice(marketData.totalCostBasis)) invested")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    // MARK: - Performers Row

    private var performersRow: some View {
        HStack(spacing: 12) {
            if let best = bestPerformer {
                performerMini(label: "Best", holding: best, color: appTheme.positiveColor)
            }
            if let worst = worstPerformer {
                performerMini(label: "Worst", holding: worst, color: appTheme.negativeColor)
            }
        }
    }

    private func performerMini(label: String, holding: PortfolioHolding, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(holding.asset.symbol)
                    .font(.headline.weight(.bold))
                    .foregroundColor(.primary)
                Text(String(format: "%+.1f%%", holding.profitLossPercent))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(color)
                    .monospacedDigit()
            }

            Text(holding.asset.name)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    // MARK: - Holdings Card

    private var holdingsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Holdings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(sortedHoldings.count) position\(sortedHoldings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ForEach(Array(sortedHoldings.enumerated()), id: \.element.asset.symbol) { idx, holding in
                holdingRow(holding, idx: idx, isLast: idx == sortedHoldings.count - 1)
            }
        }
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    private func holdingRow(_ holding: PortfolioHolding, idx: Int, isLast: Bool) -> some View {
        let returnColor: Color = holding.profitLossPercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor
        let safeIdx = idx % holdingPalette.count
        let dotColor = holdingPalette[safeIdx]

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dotColor)
                    .frame(width: 3, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.asset.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(holding.asset.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%+.2f%%", holding.profitLossPercent))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(returnColor)
                        .monospacedDigit()
                    Text(marketData.formatPrice(holding.profitLoss))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if !isLast {
                Divider().padding(.leading, 31)
            }
        }
    }
}

// MARK: - PortfolioDividendsTabView

struct PortfolioDividendsTabView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.theme) var appTheme
    @Environment(\.colorScheme) var colorScheme

    // MARK: Private Model

    private struct DividendHolding: Identifiable {
        let id: String
        let holding: PortfolioHolding
        let annualIncome: Double
    }

    // MARK: Private Computed

    private var dividendHoldings: [DividendHolding] {
        marketData.portfolio
            .compactMap { h -> DividendHolding? in
                guard let div = h.asset.dividend, div > 0 else { return nil }
                let annualIncome = div / 100.0 * h.currentValue
                return DividendHolding(id: h.asset.symbol, holding: h, annualIncome: annualIncome)
            }
            .sorted { $0.annualIncome > $1.annualIncome }
    }

    private var totalAnnual: Double {
        dividendHoldings.reduce(0) { $0 + $1.annualIncome }
    }

    private var totalMonthly: Double {
        totalAnnual / 12
    }

    private var avgYield: Double {
        guard !dividendHoldings.isEmpty else { return 0 }
        let totalValue = dividendHoldings.reduce(0) { $0 + $1.holding.currentValue }
        guard totalValue > 0 else { return 0 }
        return dividendHoldings.reduce(0) { $0 + (($1.holding.asset.dividend ?? 0) * $1.holding.currentValue / totalValue) }
    }

    // MARK: - Body

    var body: some View {
        LazyVStack(spacing: 16) {
            incomeSummaryCard
            dividendHoldingsList
            if dividendHoldings.count > 0 {
                monthlyBarChartCard
            }
            if dividendHoldings.isEmpty {
                emptyDividendNote
            }
        }
        .padding(16)
    }

    // MARK: - Income Summary Card

    private var incomeSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated Annual Income")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(marketData.formatPrice(totalAnnual))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundColor(appTheme.positiveColor)
                .monospacedDigit()

            HStack(spacing: 10) {
                // Monthly pill
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Monthly")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(marketData.formatPrice(totalMonthly))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .monospacedDigit()
                            Text("/mo")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(10)

                // Avg Yield pill
                VStack(alignment: .leading, spacing: 1) {
                    Text("Avg Yield")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f%%", avgYield))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    // MARK: - Dividend Holdings List

    private var dividendHoldingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title with count
            Text("Dividend Payers (\(dividendHoldings.count))")
                .font(.title3.bold())
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if dividendHoldings.isEmpty {
                Text("No dividend-paying positions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ForEach(Array(dividendHoldings.enumerated()), id: \.element.id) { idx, dh in
                    dividendRow(dh, isLast: idx == dividendHoldings.count - 1, paletteIndex: idx)
                }
            }
        }
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    private func dividendRow(_ dh: DividendHolding, isLast: Bool, paletteIndex: Int) -> some View {
        let monthly = dh.annualIncome / 12
        let yieldPct = dh.holding.asset.dividend ?? 0
        let safeIdx: Int = paletteIndex % holdingPalette.count
        let paletteColor: Color = holdingPalette[safeIdx]

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Symbol badge circle
                ZStack {
                    Circle()
                        .fill(paletteColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Text(String(dh.holding.asset.symbol.prefix(1)))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(paletteColor)
                }

                // Name + yield
                VStack(alignment: .leading, spacing: 2) {
                    Text(dh.holding.asset.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(String(format: "Yield: %.2f%%", yieldPct))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Annual + monthly income
                VStack(alignment: .trailing, spacing: 2) {
                    Text(marketData.formatPrice(dh.annualIncome))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(appTheme.positiveColor)
                        .monospacedDigit()

                    Text(marketData.formatPrice(monthly) + "/mo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if !isLast {
                Divider()
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Monthly Bar Chart

    private var monthlyBarChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly Income Breakdown")
                .font(.subheadline.weight(.semibold))

            Chart(dividendHoldings) { dh in
                BarMark(
                    x: .value("Symbol", dh.holding.asset.symbol),
                    y: .value("Monthly", dh.annualIncome / 12)
                )
                .foregroundStyle(appTheme.positiveColor.opacity(0.75))
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(height: 120)
        }
        .padding(20)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    // MARK: - Empty Note

    private var emptyDividendNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundColor(appTheme.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("About Dividend Data")
                    .font(.subheadline.weight(.semibold))
                Text("Dividends display when your holdings have dividend yield data. Make sure your positions include dividend-paying stocks or ETFs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }
}

// MARK: - PortfolioBenchmarkTabView

struct PortfolioBenchmarkTabView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.theme) var appTheme
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedPeriod: BenchmarkPeriod = .threeMonths

    enum BenchmarkPeriod: String, CaseIterable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "ALL"

        var days: Int {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .oneYear: return 365
            case .all: return 9999
            }
        }
    }

    // MARK: Private Computed

    private var sp500Sorted: [PricePoint] {
        marketData.sp500History.sorted { $0.date < $1.date }
    }

    private var portfolioSorted: [PortfolioSnapshot] {
        marketData.portfolioHistory.sorted { $0.date < $1.date }
    }

    /// Date range: intersect portfolio history and S&P 500 history, then clamp to selected period.
    private var alignedDateRange: (start: Date, end: Date)? {
        guard let pStart = portfolioSorted.first?.date,
              let pEnd = portfolioSorted.last?.date,
              let sStart = sp500Sorted.first?.date,
              let sEnd = sp500Sorted.last?.date else { return nil }

        let overlapStart = max(pStart, sStart)
        let overlapEnd = min(pEnd, sEnd)
        guard overlapStart < overlapEnd else { return nil }

        // Apply period clamp from the end
        let periodStart = Calendar.current.date(byAdding: .day, value: -selectedPeriod.days, to: overlapEnd) ?? overlapStart
        let effectiveStart = max(overlapStart, periodStart)
        return (effectiveStart, overlapEnd)
    }

    /// Portfolio points normalized to percentage return within aligned date range.
    private var alignedPortfolioPoints: [(date: Date, value: Double)] {
        guard let range = alignedDateRange else { return [] }
        let filtered = portfolioSorted.filter { $0.date >= range.start && $0.date <= range.end }
        guard let firstValue = filtered.first?.totalValue, firstValue > 0 else { return [] }
        return filtered.map { (date: $0.date, value: ($0.totalValue / firstValue - 1) * 100) }
    }

    /// S&P 500 points normalized to percentage return within aligned date range.
    private var alignedSP500Points: [(date: Date, value: Double)] {
        guard let range = alignedDateRange else { return [] }
        let filtered = sp500Sorted.filter { $0.date >= range.start && $0.date <= range.end }
        guard let firstPrice = filtered.first?.price, firstPrice > 0 else { return [] }
        return filtered.map { (date: $0.date, value: ($0.price / firstPrice - 1) * 100) }
    }

    private var portfolioReturnPct: Double {
        alignedPortfolioPoints.last?.value ?? 0
    }

    private var sp500ReturnPct: Double {
        alignedSP500Points.last?.value ?? 0
    }

    private var outperformance: Double {
        portfolioReturnPct - sp500ReturnPct
    }

    private var isOutperforming: Bool {
        outperformance >= 0
    }

    private var portfolioColor: Color {
        portfolioReturnPct >= 0 ? appTheme.positiveColor : appTheme.negativeColor
    }

    private var cardBg: Color {
        colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if subscriptionManager.currentTier != .black {
                FeatureLockView(featureName: "Benchmark Analysis", requiredTier: .black)
                    .environmentObject(subscriptionManager)
                    .padding(16)
            } else {
                benchmarkContent
            }
        }
    }

    // MARK: - Benchmark Content

    private var benchmarkContent: some View {
        LazyVStack(spacing: 16) {
            comparisonCards
            periodSelector
            overlayChartCard
            insightCard
        }
        .padding(16)
    }

    // MARK: - Period Selector

    private var periodSelector: some View {
        HStack(spacing: 0) {
            ForEach(BenchmarkPeriod.allCases, id: \.self) { period in
                let isSelected = selectedPeriod == period
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedPeriod = period }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(period.rawValue)
                        .font(.caption.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.blue.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(cardBg)
        .cornerRadius(12)
    }

    // MARK: - Comparison Cards

    private var comparisonCards: some View {
        HStack(spacing: 12) {
            comparisonCard(
                label: "Your Portfolio",
                returnPct: portfolioReturnPct,
                icon: "briefcase.fill",
                iconColor: .blue,
                isLeader: isOutperforming,
                accentColor: portfolioColor
            )
            comparisonCard(
                label: "S&P 500 (SPY)",
                returnPct: sp500ReturnPct,
                icon: "chart.bar.fill",
                iconColor: .orange,
                isLeader: !isOutperforming,
                accentColor: sp500ReturnPct >= 0 ? appTheme.positiveColor : appTheme.negativeColor
            )
        }
    }

    private func comparisonCard(label: String, returnPct: Double, icon: String, iconColor: Color, isLeader: Bool, accentColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(iconColor)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }

            Text(String(format: "%+.2f%%", returnPct))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(accentColor)

            if isLeader {
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                    Text("Leading")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBg)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isLeader ? iconColor.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Overlay Chart Card

    private var overlayChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Performance Comparison")
                    .font(.headline)
                Spacer()
                Text("% return")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(cardBg)
                    .clipShape(Capsule())
            }

            if alignedPortfolioPoints.count > 1 && alignedSP500Points.count > 1 {
                let allValues = alignedPortfolioPoints.map(\.value) + alignedSP500Points.map(\.value) + [0]
                let yMin = (allValues.min() ?? -5) - 1
                let yMax = (allValues.max() ?? 5) + 1

                Chart {
                    // Portfolio area fill
                    ForEach(alignedPortfolioPoints, id: \.date) { pt in
                        AreaMark(
                            x: .value("Date", pt.date),
                            yStart: .value("Base", 0),
                            yEnd: .value("Return", pt.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.15), Color.blue.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    // Portfolio line
                    ForEach(alignedPortfolioPoints, id: \.date) { pt in
                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Return", pt.value)
                        )
                        .foregroundStyle(Color.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    }

                    // S&P 500 line
                    ForEach(alignedSP500Points, id: \.date) { pt in
                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Return", pt.value)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }

                    // Zero baseline
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: yMin...yMax)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let v = val.as(Double.self) {
                                Text(String(format: "%+.1f%%", v))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .clipped()
            } else {
                // Empty / loading state
                VStack(spacing: 12) {
                    if marketData.sp500History.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text("S&P 500 data unavailable")
                            .font(.subheadline.weight(.medium))
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
                    } else {
                        ProgressView().tint(.secondary)
                        Text("Not enough overlapping data to compare.\nAdd more portfolio history.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
            }

            // Legend
            HStack(spacing: 20) {
                Spacer()
                legendDot(color: .blue, label: "Portfolio")
                legendDot(color: .orange, label: "S&P 500")
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(20)
        .background(cardBg)
        .cornerRadius(16)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Insight Card

    private var insightCard: some View {
        let absVal = abs(outperformance)
        let tintColor: Color = isOutperforming ? appTheme.positiveColor : Color.orange
        let iconName = isOutperforming ? "trophy.fill" : "chart.line.downtrend.xyaxis"

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(tintColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isOutperforming ? "Beating the Market" : "Room to Grow")
                    .font(.subheadline.weight(.bold))

                if marketData.portfolio.isEmpty {
                    Text("Add holdings to compare your returns with the S&P 500.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(isOutperforming
                        ? String(format: "Your portfolio leads the S&P 500 by %.2f points over this period.", absVal)
                        : String(format: "The S&P 500 leads your portfolio by %.2f points over this period.", absVal))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(tintColor.opacity(0.08))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tintColor.opacity(0.2), lineWidth: 1)
        )
    }
}
