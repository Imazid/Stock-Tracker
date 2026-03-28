//
//  QuickStatsSection.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 24/1/2026.
//

import SwiftUI

struct QuickStatsSection: View {
    let stock: DetailedStock

    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(appTheme.accentColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(appTheme.accentColor)
                }
                Text("Market Stats")
                    .font(.headline.weight(.semibold))
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {

                StatCard(label: "Market Cap", value: formatLargeNumber(stock.marketCap))
                StatCard(label: "Volume", value: formatVolume(stock.volume))
                StatCard(label: "P/E Ratio", value: stock.peRatio.map { String(format: "%.2f", $0) } ?? "—")
                StatCard(label: "Avg Volume", value: formatVolume(stock.avgVolume))
                StatCard(label: "52W High", value: stock.week52High.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                StatCard(label: "52W Low",  value: stock.week52Low.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))

                // Intraday stats (populated by FMP quote)
                if let open = stock.openPrice {
                    StatCard(label: "Open", value: open.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                }
                if let dh = stock.dayHigh {
                    StatCard(label: "Day High", value: dh.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                }
                if let dl = stock.dayLow {
                    StatCard(label: "Day Low", value: dl.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                }

                // Moving averages
                if let ma50 = stock.priceAvg50 {
                    StatCard(label: "50-Day MA", value: ma50.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                }
                if let ma200 = stock.priceAvg200 {
                    StatCard(label: "200-Day MA", value: ma200.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                }

                // Shares outstanding
                if stock.sharesOutstanding > 0 {
                    StatCard(label: "Shares Out", value: formatShares(stock.sharesOutstanding))
                }
            }
        }
    }

    private var currencySymbol: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = marketData.preferredCurrency
        fmt.locale = Locale.current
        return fmt.currencySymbol ?? "$"
    }

    private func formatLargeNumber(_ value: Double) -> String {
        let rate = marketData.preferredCurrency == "USD" ? 1.0 : (marketData.exchangeRates[marketData.preferredCurrency] ?? 1.0)
        let converted = value * rate
        let sym = currencySymbol
        if converted >= 1_000_000_000_000 { return String(format: "\(sym)%.2fT", converted / 1_000_000_000_000) }
        if converted >= 1_000_000_000     { return String(format: "\(sym)%.2fB", converted / 1_000_000_000) }
        if converted >= 1_000_000         { return String(format: "\(sym)%.2fM", converted / 1_000_000) }
        return String(format: "\(sym)%.2f", converted)
    }

    private func formatVolume(_ value: Int) -> String {
        let d = Double(value)
        if d >= 1_000_000_000 { return String(format: "%.2fB", d / 1_000_000_000) }
        if d >= 1_000_000     { return String(format: "%.2fM", d / 1_000_000) }
        if d >= 1_000         { return String(format: "%.1fK", d / 1_000) }
        return "\(value)"
    }

    private func formatShares(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000     { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000         { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
}

struct StatCard: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) var colorScheme

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    init(label: String, value: Double, format: FloatingPointFormatStyle<Double>.Currency) {
        self.label = label
        self.value = value.formatted(format)
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}
