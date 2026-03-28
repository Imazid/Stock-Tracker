//
//  ValuationMetrics.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 25/1/2026.
//


//
//  MetricSections.swift
//  Stock Tracker
//

import SwiftUI

// MARK: - Valuation Metrics
struct ValuationMetrics: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            DetailRow(label: "P/E Ratio", value: stock.peRatio.map { String(format: "%.2f", $0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Forward P/E", value: stock.forwardPE.map { String(format: "%.2f", $0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "PEG Ratio", value: stock.pegRatio.map { String(format: "%.2f", $0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Price/Book", value: stock.priceToBook.map { String(format: "%.2f", $0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Price/Sales", value: stock.priceToSales.map { String(format: "%.2f", $0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Enterprise Value", value: stock.enterpriseValue.map { formatLargeNumber($0) } ?? "—")
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}

// MARK: - Financial Health Metrics
struct FinancialHealthMetrics: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            DetailRow(label: "Revenue", value: stock.revenue.map { formatLargeNumber($0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Gross Margin", value: stock.grossMargin.map { formatPercent($0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Operating Margin", value: stock.operatingMargin.map { formatPercent($0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Profit Margin", value: stock.profitMargin.map { formatPercent($0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Free Cash Flow", value: stock.freeCashFlow.map { formatLargeNumber($0) } ?? "—")
            Divider().opacity(0.4)
            DetailRow(label: "Debt/Equity", value: stock.debtToEquity.map { String(format: "%.2f", $0) } ?? "—")
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
    
    private func formatPercent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

// MARK: - Growth Metrics
struct GrowthMetrics: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            DetailRow(
                label: "Revenue Growth (YoY)",
                value: stock.revenueGrowthYoY.map { formatGrowth($0) } ?? "—",
                valueColor: stock.revenueGrowthYoY.map { $0 >= 0 ? appTheme.positiveColor : appTheme.negativeColor }
            )
            Divider().opacity(0.4)
            DetailRow(
                label: "Earnings Growth (YoY)",
                value: stock.earningsGrowthYoY.map { formatGrowth($0) } ?? "—",
                valueColor: stock.earningsGrowthYoY.map { $0 >= 0 ? appTheme.positiveColor : appTheme.negativeColor }
            )
            Divider().opacity(0.4)
            DetailRow(
                label: "EPS Growth",
                value: stock.epsGrowth.map { formatGrowth($0) } ?? "—",
                valueColor: stock.epsGrowth.map { $0 >= 0 ? appTheme.positiveColor : appTheme.negativeColor }
            )
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
    
    private func formatGrowth(_ value: Double) -> String {
        String(format: "%+.2f%%", value * 100)
    }
}

// MARK: - Dividend Metrics
struct DividendMetrics: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            DetailRow(
                label: "Dividend Yield",
                value: stock.dividendYield.map { String(format: "%.2f%%", $0 * 100) } ?? "—",
                valueColor: appTheme.positiveColor
            )
            Divider().opacity(0.4)
            DetailRow(
                label: "Annual Dividend",
                value: stock.annualDividend.map { $0.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates) } ?? "—"
            )
            Divider().opacity(0.4)
            DetailRow(
                label: "Payout Ratio",
                value: stock.payoutRatio.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
            )
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}

// MARK: - Risk Metrics
struct RiskMetrics: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 12) {
            // Beta with explanation
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Beta", value: stock.beta.map { String(format: "%.2f", $0) } ?? "—")

                if let beta = stock.beta {
                    Text(betaExplanation(beta))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
            }

            // Moving average comparison
            if stock.priceAvg50 != nil || stock.priceAvg200 != nil {
                Divider().opacity(0.4)
                VStack(spacing: 10) {
                    if let ma50 = stock.priceAvg50 {
                        let diff = (stock.currentPrice - ma50) / ma50
                        DetailRow(
                            label: "vs 50-Day MA",
                            value: String(format: "%+.2f%%", diff * 100),
                            valueColor: diff >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                        )
                    }
                    if let ma200 = stock.priceAvg200 {
                        let diff = (stock.currentPrice - ma200) / ma200
                        DetailRow(
                            label: "vs 200-Day MA",
                            value: String(format: "%+.2f%%", diff * 100),
                            valueColor: diff >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                        )
                    }
                }
            }

            Divider().opacity(0.4)

            // 52-Week Range
            VStack(alignment: .leading, spacing: 12) {
                Text("52-Week Range")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Low")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(stock.week52Low.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }

                    // Visual range bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background bar
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 4)

                            // Current position indicator
                            let rangeWidth = stock.week52High - stock.week52Low
                            let currentPosition = rangeWidth > 0 ? (stock.currentPrice - stock.week52Low) / rangeWidth : 0.5
                            let indicatorX = geometry.size.width * CGFloat(max(0, min(1, currentPosition)))

                            Circle()
                                .fill(stock.isPositive ? appTheme.positiveColor : appTheme.negativeColor)
                                .frame(width: 12, height: 12)
                                .offset(x: indicatorX - 6)
                        }
                    }
                    .frame(height: 12)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("High")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(stock.week52High.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }

            Divider().opacity(0.4)

            // Short Interest
            if let shortInterest = stock.shortInterest {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(
                        label: "Short Interest",
                        value: String(format: "%.2f%%", shortInterest * 100)
                    )

                    Text(shortInterestLevel(shortInterest))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
    
    private func betaExplanation(_ beta: Double) -> String {
        if beta < 0.8 {
            return "Less volatile than the market"
        } else if beta < 1.2 {
            return "Similar volatility to the market"
        } else {
            return "More volatile than the market"
        }
    }
    
    private func shortInterestLevel(_ value: Double) -> String {
        if value < 0.05 {
            return "Low short interest"
        } else if value < 0.10 {
            return "Moderate short interest"
        } else {
            return "High short interest"
        }
    }
}

// MARK: - Detail Row Component
struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    init(label: String, value: String, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            if let color = valueColor {
                Text(value)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - Helper Functions
private func formatLargeNumber(_ value: Double) -> String {
    if value >= 1_000_000_000_000 {
        return String(format: "$%.2fT", value / 1_000_000_000_000)
    } else if value >= 1_000_000_000 {
        return String(format: "$%.2fB", value / 1_000_000_000)
    } else if value >= 1_000_000 {
        return String(format: "$%.2fM", value / 1_000_000)
    }
    return String(format: "$%.2f", value)
}