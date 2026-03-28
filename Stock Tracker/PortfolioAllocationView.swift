//  PortfolioAllocationView.swift
//  Stock Tracker
//  Allocation tab: composition card (donut + legend), horizontal risk strip.

import SwiftUI
import Charts

// MARK: - PortfolioRiskCalculator

struct PortfolioRiskCalculator {
    /// Annualized volatility as % (std dev of daily returns x sqrt(252) x 100)
    static func volatility(from history: [PortfolioSnapshot]) -> Double {
        let sorted = history.sorted { $0.date < $1.date }
        guard sorted.count > 1 else { return 0 }
        let returns = zip(sorted, sorted.dropFirst()).compactMap { prev, curr -> Double? in
            guard prev.totalValue > 0 else { return nil }
            return (curr.totalValue - prev.totalValue) / prev.totalValue
        }
        guard !returns.isEmpty else { return 0 }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { pow($0 - mean, 2) }.reduce(0, +) / Double(returns.count)
        return sqrt(variance) * sqrt(252) * 100
    }

    /// Weighted average beta of holdings (falls back to 1.0 if no beta data)
    static func beta(from portfolio: [PortfolioHolding]) -> Double {
        let betas = portfolio.compactMap { h -> (Double, Double)? in
            guard let b = h.asset.beta, h.currentValue > 0 else { return nil }
            return (b, h.currentValue)
        }
        guard !betas.isEmpty else { return 1.0 }
        let totalV = betas.reduce(0) { $0 + $1.1 }
        return betas.reduce(0) { $0 + ($1.0 * $1.1 / totalV) }
    }

    /// Sharpe ratio: (annualizedReturn% - riskFreeRate%) / volatility%
    static func sharpeRatio(totalPLPercent: Double, volatility: Double, riskFreeRate: Double = 4.5) -> Double {
        guard volatility > 0 else { return 0 }
        return (totalPLPercent - riskFreeRate) / volatility
    }

    /// 0–100 diversification score based on inverse HHI
    static func diversificationScore(from portfolio: [PortfolioHolding], totalValue: Double) -> Int {
        guard totalValue > 0, portfolio.count > 1 else { return 0 }
        let hhi = portfolio.reduce(0.0) { $0 + pow($1.currentValue / totalValue, 2) }
        let n = Double(portfolio.count)
        let maxScore = 1.0 - 1.0 / n
        guard maxScore > 0 else { return 0 }
        return Int(min(100, max(0, (1 - hhi) / maxScore * 100)))
    }
}

// MARK: - Segment Model

private struct AllocationSegment: Identifiable {
    let id: UUID
    let label: String
    let value: Double
    let pct: Double
    let color: Color

    init(label: String, value: Double, pct: Double, color: Color) {
        self.id    = UUID()
        self.label = label
        self.value = value
        self.pct   = pct
        self.color = color
    }
}

// MARK: - AllocationChartView

struct AllocationChartView: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.theme) var appTheme
    @Environment(\.colorScheme) var colorScheme

    // MARK: - Data

    private var portfolio: [PortfolioHolding] { marketData.portfolio }
    private var totalValue: Double { marketData.totalPortfolioValue }

    private var sortedByValue: [PortfolioHolding] {
        portfolio.sorted { $0.currentValue > $1.currentValue }
    }

    private let localPalette: [Color] = [
        Color(red: 0.18, green: 0.40, blue: 1.00),
        Color(red: 0.58, green: 0.18, blue: 1.00),
        Color(red: 1.00, green: 0.48, blue: 0.00),
        Color(red: 0.08, green: 0.72, blue: 0.42),
        Color(red: 1.00, green: 0.28, blue: 0.60),
        Color(red: 0.00, green: 0.78, blue: 0.92),
        Color(red: 0.90, green: 0.20, blue: 0.20),
    ]

    private var topSegments: [AllocationSegment] {
        guard totalValue > 0 else { return [] }
        let top6 = Array(sortedByValue.prefix(6))
        var segments: [AllocationSegment] = []
        for (idx, holding) in top6.enumerated() {
            let pct: Double = holding.currentValue / totalValue * 100
            let c: Color = localPalette[idx % localPalette.count]
            segments.append(AllocationSegment(label: holding.asset.symbol, value: holding.currentValue, pct: pct, color: c))
        }
        if sortedByValue.count > 6 {
            let othersValue: Double = sortedByValue.dropFirst(6).reduce(0.0) { $0 + $1.currentValue }
            let othersPct: Double = othersValue / totalValue * 100
            segments.append(AllocationSegment(label: "Others", value: othersValue, pct: othersPct, color: Color(UIColor.systemGray3)))
        }
        return segments
    }

    private var volatility: Double {
        PortfolioRiskCalculator.volatility(from: marketData.portfolioHistory)
    }
    private var beta: Double {
        PortfolioRiskCalculator.beta(from: portfolio)
    }
    private var sharpe: Double {
        PortfolioRiskCalculator.sharpeRatio(
            totalPLPercent: marketData.totalProfitLossPercent,
            volatility: volatility
        )
    }
    private var diversificationScore: Int {
        PortfolioRiskCalculator.diversificationScore(from: portfolio, totalValue: totalValue)
    }

    // MARK: - Body

    var body: some View {
        if portfolio.isEmpty {
            emptyPlaceholder
                .padding(.horizontal, 16)
                .padding(.top, 60)
        } else {
            VStack(spacing: 16) {
                compositionCard
                riskCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
    }

    // MARK: - Composition Card

    private var compositionCard: some View {
        VStack(spacing: 0) {
            // Donut chart
            ZStack {
                Chart(topSegments) { seg in
                    SectorMark(
                        angle: .value("Value", seg.value),
                        innerRadius: .ratio(0.60),
                        angularInset: 1.5
                    )
                    .foregroundStyle(seg.color)
                    .cornerRadius(3)
                }

                VStack(spacing: 3) {
                    Text(marketData.formatPrice(totalValue))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                    Text("\(portfolio.count) position\(portfolio.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 190)
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Divider()
                .padding(.top, 16)

            // Holdings list
            VStack(spacing: 0) {
                ForEach(Array(topSegments.enumerated()), id: \.element.id) { idx, seg in
                    HStack(spacing: 12) {
                        // Color bar accent
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.color)
                            .frame(width: 3, height: 34)

                        // Symbol + name
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(nameForSymbol(seg.label))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        // Value + percentage
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f%%", seg.pct))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                                .monospacedDigit()
                            Text(marketData.formatPrice(seg.value))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if idx < topSegments.count - 1 {
                        Divider()
                            .padding(.leading, 31)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    private func nameForSymbol(_ symbol: String) -> String {
        if symbol == "Others" { return "Multiple positions" }
        return portfolio.first { $0.asset.symbol == symbol }?.asset.name ?? symbol
    }

    // MARK: - Risk Card

    private var riskCard: some View {
        HStack(spacing: 0) {
            riskItem(
                title: "Volatility",
                value: String(format: "%.1f%%", volatility),
                sub: volatility > 25 ? "High" : volatility < 10 ? "Low" : "Normal",
                color: volatility > 25 ? appTheme.negativeColor : volatility < 10 ? appTheme.positiveColor : .primary
            )

            Divider().frame(height: 44)

            riskItem(
                title: "Beta",
                value: String(format: "%.2f", beta),
                sub: beta > 1.2 ? "Aggressive" : beta < 0.8 ? "Defensive" : "Neutral",
                color: beta > 1.2 ? Color.orange : .primary
            )

            Divider().frame(height: 44)

            riskItem(
                title: "Sharpe",
                value: String(format: "%.2f", sharpe),
                sub: sharpe > 1 ? "Excellent" : sharpe < 0 ? "Negative" : "Moderate",
                color: sharpe > 1 ? appTheme.positiveColor : sharpe < 0 ? appTheme.negativeColor : .primary
            )

            Divider().frame(height: 44)

            riskItem(
                title: "Diversity",
                value: "\(diversificationScore)",
                sub: "/100",
                color: diversificationScore >= 70 ? appTheme.positiveColor : diversificationScore >= 40 ? .orange : appTheme.negativeColor
            )
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(16)
    }

    private func riskItem(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
            Text(sub)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.pie")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Add holdings to see allocation")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
