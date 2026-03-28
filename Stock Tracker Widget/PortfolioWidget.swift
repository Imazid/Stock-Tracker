//
//  PortfolioWidget.swift
//  Stock Tracker Widget
//
//  Families: systemSmall, systemMedium, systemLarge,
//            accessoryCircular, accessoryRectangular, accessoryInline
//
//  Tap target: stocktracker://portfolio
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let data: PortfolioWidgetData
}

struct PortfolioWidgetData {
    var totalValue: Double
    var totalChange: Double
    var totalChangePercent: Double
    var dailyChange: Double
    var dailyChangePercent: Double
    var holdings: [HoldingItem]
    var sparklinePoints: [Double]

    var isPositive: Bool    { totalChange >= 0 }
    var isDailyPositive: Bool { dailyChange >= 0 }

    struct HoldingItem {
        var symbol: String
        var name: String
        var price: Double
        var changePercent: Double
        var value: Double
        var profitLossPercent: Double
    }

    static var placeholder: PortfolioWidgetData {
        PortfolioWidgetData(
            totalValue: 52_420,
            totalChange: 1_840,
            totalChangePercent: 3.64,
            dailyChange: 320,
            dailyChangePercent: 0.61,
            holdings: [
                .init(symbol: "AAPL", name: "Apple Inc.",  price: 189.5, changePercent:  1.2, value: 18_950, profitLossPercent: 12.4),
                .init(symbol: "MSFT", name: "Microsoft",   price: 415.2, changePercent: -0.4, value: 12_456, profitLossPercent:  8.1),
                .init(symbol: "NVDA", name: "Nvidia Corp.",price: 880.0, changePercent:  2.8, value:  8_800, profitLossPercent: 35.2),
                .init(symbol: "TSLA", name: "Tesla Inc.",  price: 248.3, changePercent: -1.1, value:  4_966, profitLossPercent: -8.3),
                .init(symbol: "BTC",  name: "Bitcoin",     price: 62_000, changePercent: 0.7, value:  6_200, profitLossPercent: 22.1)
            ],
            sparklinePoints: [48_000, 49_200, 47_800, 50_100, 51_400, 50_800, 52_100,
                              51_900, 53_200, 52_800, 54_100, 53_600, 52_900, 53_800,
                              54_500, 53_100, 52_400, 53_000, 52_800, 52_420]
        )
    }

    static func fromShared() -> PortfolioWidgetData {
        if let shared = WidgetPortfolioData.read() {
            return PortfolioWidgetData(
                totalValue: shared.totalValue,
                totalChange: shared.totalChange,
                totalChangePercent: shared.totalChangePercent,
                dailyChange: shared.dailyChange,
                dailyChangePercent: shared.dailyChangePercent,
                holdings: shared.holdings.map {
                    HoldingItem(symbol: $0.symbol, name: $0.name, price: $0.price,
                                changePercent: $0.changePercent, value: $0.value,
                                profitLossPercent: $0.profitLossPercent)
                },
                sparklinePoints: shared.sparklinePoints
            )
        }
        // Fallback to legacy raw-dictionary read.
        guard let ud = UserDefaults(suiteName: widgetAppGroup),
              let data = ud.data(forKey: "portfolioData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return placeholder }

        let holdingsRaw = json["holdings"] as? [[String: Any]] ?? []
        let holdings = holdingsRaw.map { h in
            HoldingItem(symbol: h["symbol"] as? String ?? "",
                        name: h["name"] as? String ?? "",
                        price: h["price"] as? Double ?? 0,
                        changePercent: h["changePercent"] as? Double ?? 0,
                        value: h["value"] as? Double ?? 0,
                        profitLossPercent: h["profitLossPercent"] as? Double ?? 0)
        }
        return PortfolioWidgetData(
            totalValue: json["totalValue"] as? Double ?? 0,
            totalChange: json["totalChange"] as? Double ?? 0,
            totalChangePercent: json["totalChangePercent"] as? Double ?? 0,
            dailyChange: json["dailyChange"] as? Double ?? 0,
            dailyChangePercent: json["dailyChangePercent"] as? Double ?? 0,
            holdings: holdings,
            sparklinePoints: json["sparklinePoints"] as? [Double] ?? []
        )
    }

    var totalValueAbbreviated: String {
        switch abs(totalValue) {
        case 1_000_000...: return String(format: "$%.1fM", totalValue / 1_000_000)
        case 1_000...:     return String(format: "$%.1fK", totalValue / 1_000)
        default:           return String(format: "$%.0f", totalValue)
        }
    }
}

// MARK: - Provider

struct PortfolioProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        completion(PortfolioEntry(date: Date(), data: context.isPreview ? .placeholder : .fromShared()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let entry = PortfolioEntry(date: Date(), data: .fromShared())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - Root Entry View

struct PortfolioWidgetEntryView: View {
    var entry: PortfolioEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:           PortfolioSmallView(data: entry.data)
        case .systemMedium:          PortfolioMediumView(data: entry.data)
        case .systemLarge:           PortfolioLargeView(data: entry.data)
        case .accessoryCircular:     PortfolioAccessoryCircular(data: entry.data)
        case .accessoryRectangular:  PortfolioAccessoryRectangular(data: entry.data)
        case .accessoryInline:       PortfolioAccessoryInline(data: entry.data)
        default:                     PortfolioSmallView(data: entry.data)
        }
    }
}

// MARK: - System Small

struct PortfolioSmallView: View {
    let data: PortfolioWidgetData
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeaderRow(icon: "briefcase.fill", title: "Portfolio")

            Spacer()

            Text(data.totalValue, format: .currency(code: "USD").precision(.fractionLength(0)))
                .font(WidgetFont.primaryLarge(.bold))
                .foregroundColor(WidgetColor.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if data.sparklinePoints.count >= 2 {
                SparklineView(
                    points: data.sparklinePoints, isPositive: data.isPositive,
                    lineWidth: 1.5, showFill: true, showGlow: true,
                    colorblindMode: cbMode
                )
                .frame(height: 28)
            }

            DeltaChip(value: data.totalChangePercent, size: .compact, mode: cbMode)
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Portfolio \(data.totalValueAbbreviated), \(data.isPositive ? "up" : "down") \(String(format: "%.2f", abs(data.totalChangePercent))) percent")
    }
}

// MARK: - System Medium

struct PortfolioMediumView: View {
    let data: PortfolioWidgetData
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        HStack(spacing: WidgetSpacing.sectionGap) {
            // Left — value + sparkline
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeaderRow(icon: "briefcase.fill", title: "Portfolio")

                Text(data.totalValue, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(WidgetFont.primaryLarge(.bold))
                    .foregroundColor(WidgetColor.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                if data.sparklinePoints.count >= 2 {
                    SparklineView(
                        points: data.sparklinePoints, isPositive: data.isDailyPositive,
                        lineWidth: 1.5, showGlow: true,
                        colorblindMode: cbMode
                    )
                    .frame(height: 30)
                }

                HStack(spacing: 6) {
                    DeltaChip(value: data.totalChangePercent, size: .compact, mode: cbMode)
                    MicroLabel(
                        text: "Today \(data.isDailyPositive ? "+" : "")\(String(format: "%.2f", data.dailyChangePercent))%",
                        color: WidgetColor.semantic(isPositive: data.isDailyPositive, mode: cbMode).opacity(0.8)
                    )
                }
            }

            // Divider
            Rectangle()
                .fill(WidgetGlass.strokeColor)
                .frame(width: 1)

            // Right — top 3 holdings
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel(text: "Top Holdings")
                    .padding(.bottom, 6)

                ForEach(Array(data.holdings.prefix(3).enumerated()), id: \.1.symbol) { i, h in
                    let color = WidgetColor.semantic(isPositive: h.changePercent >= 0, mode: cbMode)
                    HStack {
                        Text(h.symbol)
                            .font(WidgetFont.microLarge(.bold))
                            .foregroundColor(WidgetColor.textPrimary)
                        Spacer()
                        Text("\(h.changePercent >= 0 ? "+" : "")\(String(format: "%.1f", h.changePercent))%")
                            .font(WidgetFont.microLarge(.semibold))
                            .foregroundColor(color)
                    }
                    .padding(.vertical, 4)

                    if i < min(data.holdings.count, 3) - 1 {
                        Rectangle().fill(WidgetGlass.strokeColor).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Portfolio \(data.totalValueAbbreviated), \(data.isPositive ? "up" : "down") \(String(format: "%.2f", abs(data.totalChangePercent))) percent, \(data.holdings.count) holdings")
    }
}

// MARK: - System Large

struct PortfolioLargeView: View {
    let data: PortfolioWidgetData
    private let cbMode = WidgetColorblindMode.current
    let palette: [Color] = [
        Color(red: 0.4, green: 0.6, blue: 1.0),
        Color(red: 0.6, green: 0.3, blue: 0.9),
        Color(red: 0.2, green: 0.8, blue: 0.4),
        Color(red: 0.9, green: 0.6, blue: 0.1),
        Color(red: 0.9, green: 0.3, blue: 0.4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapStandard) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetHeaderRow(icon: "briefcase.fill", title: "Portfolio")
                    Text(data.totalValue, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .font(WidgetFont.displaySmall(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    DeltaChip(value: data.totalChangePercent, mode: cbMode)
                    MicroLabel(
                        text: "Today \(data.isDailyPositive ? "+" : "")\(String(format: "%.2f", data.dailyChangePercent))%",
                        color: WidgetColor.textTertiary
                    )
                }
            }

            // Sparkline
            if data.sparklinePoints.count >= 2 {
                SparklineView(
                    points: data.sparklinePoints, isPositive: data.isDailyPositive,
                    lineWidth: 2, showFill: true, showGlow: true, showLastDot: true,
                    colorblindMode: cbMode
                )
                .frame(height: 44)
            }

            Rectangle().fill(WidgetGlass.strokeColor).frame(height: 0.5)

            MicroLabel(text: "Top Holdings")

            ForEach(Array(data.holdings.prefix(5).enumerated()), id: \.1.symbol) { i, h in
                let totalVal = data.holdings.prefix(5).reduce(0) { $0 + $1.value }
                let alloc = totalVal > 0 ? h.value / totalVal : 0
                let color = WidgetColor.semantic(isPositive: h.changePercent >= 0, mode: cbMode)
                let col = palette[i % palette.count]

                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(col.opacity(0.25))
                            .frame(width: 30, height: 30)
                        Text(String(h.symbol.prefix(2)))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(WidgetColor.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.symbol)
                            .font(WidgetFont.microLarge(.semibold))
                            .foregroundColor(WidgetColor.textPrimary)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(col.opacity(0.5))
                                .frame(width: max(4, geo.size.width * alloc), height: 3)
                        }
                        .frame(height: 3)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(h.value, format: .currency(code: "USD").precision(.fractionLength(0)))
                            .font(WidgetFont.microLarge(.bold))
                            .foregroundColor(WidgetColor.textPrimary)
                        Text("\(h.changePercent >= 0 ? "+" : "")\(String(format: "%.1f", h.changePercent))%")
                            .font(WidgetFont.microSmall())
                            .foregroundColor(color)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Portfolio \(data.totalValueAbbreviated), \(data.holdings.count) holdings")
    }
}

// MARK: - Lock Screen: Accessory Circular

struct PortfolioAccessoryCircular: View {
    let data: PortfolioWidgetData
    private var accent: Color { WidgetColor.semantic(isPositive: data.isDailyPositive) }

    var body: some View {
        ZStack {
            let progress = min(abs(data.dailyChangePercent) / 5.0, 1.0)
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(data.totalValueAbbreviated)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("\(data.isDailyPositive ? "▲" : "▼")\(String(format: "%.1f", abs(data.dailyChangePercent)))%")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
            }
            .widgetAccentable()
        }
        .widgetURL(WidgetDeepLink.portfolio)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock Screen: Accessory Rectangular

struct PortfolioAccessoryRectangular: View {
    let data: PortfolioWidgetData
    private var accent: Color { WidgetColor.semantic(isPositive: data.isDailyPositive) }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .widgetAccentable()
                Text(data.totalValueAbbreviated)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: data.isDailyPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(accent)
                    .widgetAccentable()
                Text("\(data.isDailyPositive ? "+" : "")\(String(format: "%.2f", data.dailyChangePercent))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(accent)
                    .widgetAccentable()
                Text("Today")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .widgetURL(WidgetDeepLink.portfolio)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock Screen: Accessory Inline

struct PortfolioAccessoryInline: View {
    let data: PortfolioWidgetData

    var body: some View {
        Text("\(data.totalValueAbbreviated) \(data.isDailyPositive ? "▲" : "▼")\(String(format: "%.1f", abs(data.dailyChangePercent)))%")
            .widgetAccentable()
            .widgetURL(WidgetDeepLink.portfolio)
            .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Widget Declaration

struct PortfolioWidget: Widget {
    let kind: String = "PortfolioWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioProvider()) { entry in
            PortfolioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Portfolio")
        .description("Track your total portfolio value and top holdings.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
