//
//  TopMoversWidget.swift
//  Stock Tracker Widget
//
//  Shows top gainers and losers — "Top Movers / Heat List".
//  Families: systemMedium, systemLarge
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct TopMoversEntry: TimelineEntry {
    let date: Date
    let gainers: [MoverItem]
    let losers: [MoverItem]
}

struct MoverItem: Identifiable {
    let id: String
    let symbol: String
    let price: Double
    let changePercent: Double
}

// MARK: - Provider

struct TopMoversProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopMoversEntry {
        TopMoversEntry(date: Date(), gainers: Self.sampleGainers, losers: Self.sampleLosers)
    }

    func getSnapshot(in context: Context, completion: @escaping (TopMoversEntry) -> Void) {
        if context.isPreview {
            completion(TopMoversEntry(date: Date(), gainers: Self.sampleGainers, losers: Self.sampleLosers))
        } else {
            let (g, l) = Self.loadMovers()
            completion(TopMoversEntry(date: Date(), gainers: g, losers: l))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopMoversEntry>) -> Void) {
        let (gainers, losers) = Self.loadMovers()
        let entry = TopMoversEntry(date: Date(), gainers: gainers, losers: losers)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func loadMovers() -> (gainers: [MoverItem], losers: [MoverItem]) {
        guard let shared = UserDefaults(suiteName: widgetAppGroup),
              let data = shared.data(forKey: "watchlistData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return (sampleGainers, sampleLosers) }

        let movers = items.map { r in
            MoverItem(
                id: r["id"] as? String ?? UUID().uuidString,
                symbol: r["symbol"] as? String ?? "",
                price: r["price"] as? Double ?? 0,
                changePercent: r["changePercent"] as? Double ?? 0
            )
        }

        let sorted = movers.sorted { $0.changePercent > $1.changePercent }
        let gainers = sorted.filter { $0.changePercent > 0 }
        let losers  = sorted.filter { $0.changePercent < 0 }.reversed().prefix(5).map { $0 }
        return (Array(gainers.prefix(5)), Array(losers))
    }

    static let sampleGainers: [MoverItem] = [
        MoverItem(id: "1", symbol: "NVDA", price: 880, changePercent:  2.86),
        MoverItem(id: "2", symbol: "AMZN", price: 182, changePercent:  1.90),
        MoverItem(id: "3", symbol: "AAPL", price: 189, changePercent:  1.12),
    ]
    static let sampleLosers: [MoverItem] = [
        MoverItem(id: "4", symbol: "ETH",  price: 3400, changePercent: -2.44),
        MoverItem(id: "5", symbol: "TSLA", price: 248,  changePercent: -1.66),
        MoverItem(id: "6", symbol: "MSFT", price: 415,  changePercent: -0.43),
    ]
}

// MARK: - Entry View

struct TopMoversEntryView: View {
    var entry: TopMoversEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge: TopMoversLargeView(entry: entry)
        default:           TopMoversMediumView(entry: entry)
        }
    }
}

// MARK: Medium (top 3 each side)

struct TopMoversMediumView: View {
    let entry: TopMoversEntry
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        HStack(spacing: 12) {
            moverColumn(title: "Gainers", items: Array(entry.gainers.prefix(3)), isPositive: true)
            Rectangle().fill(WidgetGlass.strokeColor).frame(width: 1)
            moverColumn(title: "Losers",  items: Array(entry.losers.prefix(3)),  isPositive: false)
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top movers: \(entry.gainers.count) gainers, \(entry.losers.count) losers")
    }

    private func moverColumn(title: String, items: [MoverItem], isPositive: Bool) -> some View {
        let color = WidgetColor.semantic(isPositive: isPositive, mode: cbMode)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(color)
            }
            ForEach(items) { item in
                HStack {
                    Text(item.symbol)
                        .font(WidgetFont.microLarge(.semibold))
                        .foregroundColor(WidgetColor.textPrimary)
                    Spacer()
                    Text("\(item.changePercent >= 0 ? "+" : "")\(String(format: "%.1f", item.changePercent))%")
                        .font(WidgetFont.microLarge(.bold))
                        .foregroundColor(color)
                }
            }
            if items.isEmpty {
                Text("—").font(WidgetFont.microLarge()).foregroundColor(WidgetColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Large (top 5 each side — heat list)

struct TopMoversLargeView: View {
    let entry: TopMoversEntry
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            largeColumn(title: "Gainers", items: Array(entry.gainers.prefix(5)), isPositive: true)
            Rectangle().fill(WidgetGlass.strokeColor).frame(width: 1)
            largeColumn(title: "Losers",  items: Array(entry.losers.prefix(5)),  isPositive: false)
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top movers: \(entry.gainers.count) gainers, \(entry.losers.count) losers")
    }

    private func largeColumn(title: String, items: [MoverItem], isPositive: Bool) -> some View {
        let color = WidgetColor.semantic(isPositive: isPositive, mode: cbMode)
        // Find max change for heat intensity
        let maxChange = items.map { abs($0.changePercent) }.max() ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(color)
                Text(title)
                    .font(WidgetFont.microLarge(.bold))
                    .foregroundColor(color)
            }
            .padding(.bottom, 2)

            ForEach(items) { item in
                let intensity = maxChange > 0 ? abs(item.changePercent) / maxChange : 0.5
                HStack(spacing: 8) {
                    TickerBadge(symbol: item.symbol, color: color)
                    Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(WidgetFont.microSmall())
                        .foregroundColor(WidgetColor.textSecondary)
                    Spacer()
                    Text("\(item.changePercent >= 0 ? "+" : "")\(String(format: "%.1f", item.changePercent))%")
                        .font(WidgetFont.microLarge(.bold))
                        .foregroundColor(color)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.06 + 0.12 * intensity))
                )
            }
            if items.isEmpty {
                Text("—").font(WidgetFont.microLarge()).foregroundColor(WidgetColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

struct TopMoversWidget: Widget {
    let kind: String = "TopMoversWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopMoversProvider()) { entry in
            TopMoversEntryView(entry: entry)
        }
        .configurationDisplayName("Top Movers")
        .description("See the biggest gainers and losers in your watchlist.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
