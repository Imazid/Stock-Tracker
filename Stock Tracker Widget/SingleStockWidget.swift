//
//  SingleStockWidget.swift
//  Stock Tracker Widget
//
//  Configurable single-stock tracker — "Single Symbol Hero Card".
//  Families: systemSmall, systemMedium, systemLarge,
//            accessoryCircular, accessoryRectangular, accessoryInline
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Intent

struct StockSelectionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Select Stock" }
    static var description: IntentDescription { "Choose a stock symbol to track." }

    @Parameter(title: "Symbol", default: "AAPL")
    var symbol: String
}

// MARK: - Entry

struct SingleStockEntry: TimelineEntry {
    let date: Date
    let symbol: String
    let price: Double
    let change: Double
    let changePercent: Double
    var sparklinePoints: [Double]?
    var isPositive: Bool { changePercent >= 0 }
}

// MARK: - Provider

struct SingleStockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleStockEntry {
        SingleStockEntry(date: Date(), symbol: "AAPL", price: 189.5, change: 2.1, changePercent: 1.12)
    }

    func snapshot(for configuration: StockSelectionIntent, in context: Context) async -> SingleStockEntry {
        let sym = configuration.symbol.uppercased()
        return findEntry(symbol: sym)
    }

    func timeline(for configuration: StockSelectionIntent, in context: Context) async -> Timeline<SingleStockEntry> {
        let sym = configuration.symbol.uppercased()
        let entry = findEntry(symbol: sym)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func findEntry(symbol: String) -> SingleStockEntry {
        if let shared = UserDefaults(suiteName: widgetAppGroup) {
            if let wlData = shared.data(forKey: "watchlistData"),
               let json = try? JSONSerialization.jsonObject(with: wlData) as? [String: Any],
               let items = json["items"] as? [[String: Any]],
               let match = items.first(where: { ($0["symbol"] as? String)?.uppercased() == symbol }) {
                let sparkline = match["sparklinePoints"] as? [Double]
                return SingleStockEntry(
                    date: Date(),
                    symbol: symbol,
                    price: match["price"] as? Double ?? 0,
                    change: match["change"] as? Double ?? 0,
                    changePercent: match["changePercent"] as? Double ?? 0,
                    sparklinePoints: sparkline
                )
            }
            if let pfData = shared.data(forKey: "portfolioData"),
               let json = try? JSONSerialization.jsonObject(with: pfData) as? [String: Any],
               let holdings = json["holdings"] as? [[String: Any]],
               let match = holdings.first(where: { ($0["symbol"] as? String)?.uppercased() == symbol }) {
                return SingleStockEntry(
                    date: Date(),
                    symbol: symbol,
                    price: match["price"] as? Double ?? 0,
                    change: 0,
                    changePercent: match["changePercent"] as? Double ?? 0
                )
            }
        }
        return SingleStockEntry(date: Date(), symbol: symbol, price: 0, change: 0, changePercent: 0)
    }
}

// MARK: - Entry View

struct SingleStockEntryView: View {
    var entry: SingleStockEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge:            SingleStockLargeView(entry: entry)
        case .systemMedium:           SingleStockMediumView(entry: entry)
        case .accessoryCircular:      SingleStockAccessoryCircular(entry: entry)
        case .accessoryRectangular:   SingleStockAccessoryRectangular(entry: entry)
        case .accessoryInline:        SingleStockAccessoryInline(entry: entry)
        default:                      SingleStockSmallView(entry: entry)
        }
    }
}

// MARK: Small

struct SingleStockSmallView: View {
    let entry: SingleStockEntry
    private let cbMode = WidgetColorblindMode.current
    private var color: Color { WidgetColor.semantic(isPositive: entry.isPositive, mode: cbMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.symbol)
                .font(WidgetFont.primaryLarge(.bold))
                .foregroundColor(WidgetColor.textPrimary)

            Spacer()

            HeroPriceBlock(value: entry.price, family: .systemSmall)

            DeltaChip(value: entry.changePercent, size: .compact, mode: cbMode)
                .padding(.top, 4)
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.asset(entry.symbol))
        .widgetContainerBG(accent: color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.symbol), \(String(format: "$%.2f", entry.price)), \(entry.isPositive ? "up" : "down") \(String(format: "%.2f", abs(entry.changePercent))) percent")
    }
}

// MARK: Medium

struct SingleStockMediumView: View {
    let entry: SingleStockEntry
    private let cbMode = WidgetColorblindMode.current
    private var color: Color { WidgetColor.semantic(isPositive: entry.isPositive, mode: cbMode) }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.symbol)
                    .font(WidgetFont.displaySmall(.bold))
                    .foregroundColor(WidgetColor.textPrimary)

                HeroPriceBlock(value: entry.price, family: .systemMedium)

                DeltaChip(value: entry.changePercent, mode: cbMode)
            }

            Spacer()

            if let pts = entry.sparklinePoints, pts.count >= 2 {
                SparklineView(
                    points: pts, isPositive: entry.isPositive,
                    lineWidth: 2, showFill: true, showGlow: true, showLastDot: true,
                    colorblindMode: cbMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 2) {
                        MicroLabel(text: "Change")
                        Text(entry.change, format: .currency(code: "USD").sign(strategy: .always()))
                            .font(WidgetFont.microLarge(.bold))
                            .foregroundColor(color)
                    }
                    Image(systemName: entry.isPositive ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                        .font(.system(size: 36))
                        .foregroundColor(color.opacity(0.3))
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.asset(entry.symbol))
        .widgetContainerBG(accent: color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.symbol), \(String(format: "$%.2f", entry.price)), \(entry.isPositive ? "up" : "down") \(String(format: "%.2f", abs(entry.changePercent))) percent")
    }
}

// MARK: Large

struct SingleStockLargeView: View {
    let entry: SingleStockEntry
    private let cbMode = WidgetColorblindMode.current
    private var color: Color { WidgetColor.semantic(isPositive: entry.isPositive, mode: cbMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapStandard) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.symbol)
                        .font(WidgetFont.displaySmall(.black))
                        .foregroundColor(WidgetColor.textPrimary)
                    HeroPriceBlock(value: entry.price, family: .systemLarge)
                }
                Spacer()
                DeltaChip(value: entry.changePercent, size: .large, mode: cbMode)
            }

            if let pts = entry.sparklinePoints, pts.count >= 2 {
                SparklineView(
                    points: pts, isPositive: entry.isPositive,
                    lineWidth: 2.5, showFill: true, showGlow: true, showLastDot: true,
                    colorblindMode: cbMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: entry.isPositive ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                        .font(.system(size: 60))
                        .foregroundColor(color.opacity(0.15))
                    Spacer()
                }
                Spacer()
            }

            HStack(spacing: WidgetSpacing.sectionGap) {
                if entry.change != 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        MicroLabel(text: "CHG")
                        Text(entry.change, format: .currency(code: "USD").sign(strategy: .always()))
                            .font(WidgetFont.secondaryMedium(.bold))
                            .foregroundColor(color)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.asset(entry.symbol))
        .widgetContainerBG(accent: color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.symbol), \(String(format: "$%.2f", entry.price)), \(entry.isPositive ? "up" : "down") \(String(format: "%.2f", abs(entry.changePercent))) percent")
    }
}

// MARK: - Lock Screen: Accessory Circular

struct SingleStockAccessoryCircular: View {
    let entry: SingleStockEntry
    private var color: Color { WidgetColor.semantic(isPositive: entry.isPositive) }

    var body: some View {
        ZStack {
            let progress = min(abs(entry.changePercent) / 5.0, 1.0)
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(entry.symbol)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                Text("\(entry.isPositive ? "+" : "")\(String(format: "%.1f", entry.changePercent))%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
            }
            .widgetAccentable()
        }
        .widgetURL(WidgetDeepLink.asset(entry.symbol))
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock Screen: Accessory Rectangular

struct SingleStockAccessoryRectangular: View {
    let entry: SingleStockEntry
    private var color: Color { WidgetColor.semantic(isPositive: entry.isPositive) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .widgetAccentable()
                Text(entry.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: entry.isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(color)
                    .widgetAccentable()
                Text("\(entry.isPositive ? "+" : "")\(String(format: "%.2f", entry.changePercent))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .widgetAccentable()
            }
        }
        .widgetURL(WidgetDeepLink.asset(entry.symbol))
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock Screen: Accessory Inline

struct SingleStockAccessoryInline: View {
    let entry: SingleStockEntry

    var body: some View {
        Text("\(entry.symbol) \(String(format: "$%.2f", entry.price)) \(entry.isPositive ? "▲" : "▼")\(String(format: "%.1f", abs(entry.changePercent)))%")
            .widgetAccentable()
            .widgetURL(WidgetDeepLink.asset(entry.symbol))
            .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Widget

struct SingleStockWidget: Widget {
    let kind: String = "SingleStockWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StockSelectionIntent.self, provider: SingleStockProvider()) { entry in
            SingleStockEntryView(entry: entry)
        }
        .configurationDisplayName("Single Stock")
        .description("Track any stock or crypto by symbol.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}
