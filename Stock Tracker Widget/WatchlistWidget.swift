//
//  WatchlistWidget.swift
//  Stock Tracker Widget
//
//  Shows top watchlist movers — "Compact Watchlist".
//  Families: systemSmall, systemMedium, systemLarge
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct WatchlistEntry: TimelineEntry {
    let date: Date
    let items: [WatchlistWidgetItem]
}

struct WatchlistWidgetItem: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
    var isPositive: Bool { changePercent >= 0 }
}

// MARK: - Provider

struct WatchlistProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchlistEntry {
        WatchlistEntry(date: Date(), items: Self.sampleItems)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchlistEntry) -> Void) {
        completion(WatchlistEntry(date: Date(), items: context.isPreview ? Self.sampleItems : Self.loadItems()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchlistEntry>) -> Void) {
        let entry = WatchlistEntry(date: Date(), items: Self.loadItems())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func loadItems() -> [WatchlistWidgetItem] {
        guard let shared = UserDefaults(suiteName: widgetAppGroup),
              let data = shared.data(forKey: "watchlistData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = json["items"] as? [[String: Any]]
        else { return sampleItems }

        return rawItems.map { r in
            WatchlistWidgetItem(
                id: r["id"] as? String ?? UUID().uuidString,
                symbol: r["symbol"] as? String ?? "",
                name: r["name"] as? String ?? "",
                price: r["price"] as? Double ?? 0,
                change: r["change"] as? Double ?? 0,
                changePercent: r["changePercent"] as? Double ?? 0
            )
        }
    }

    static let sampleItems: [WatchlistWidgetItem] = [
        WatchlistWidgetItem(id: "1", symbol: "AAPL",  name: "Apple",     price: 189.5,  change: 2.1,   changePercent: 1.12),
        WatchlistWidgetItem(id: "2", symbol: "MSFT",  name: "Microsoft", price: 415.2,  change: -1.8,  changePercent: -0.43),
        WatchlistWidgetItem(id: "3", symbol: "NVDA",  name: "Nvidia",    price: 880.0,  change: 24.5,  changePercent: 2.86),
        WatchlistWidgetItem(id: "4", symbol: "TSLA",  name: "Tesla",     price: 248.3,  change: -4.2,  changePercent: -1.66),
        WatchlistWidgetItem(id: "5", symbol: "AMZN",  name: "Amazon",    price: 182.1,  change: 3.4,   changePercent: 1.90),
        WatchlistWidgetItem(id: "6", symbol: "GOOGL", name: "Alphabet",  price: 174.0,  change: -0.9,  changePercent: -0.51),
        WatchlistWidgetItem(id: "7", symbol: "BTC",   name: "Bitcoin",   price: 62000,  change: 1200,  changePercent: 1.97),
        WatchlistWidgetItem(id: "8", symbol: "ETH",   name: "Ethereum",  price: 3400,   change: -85,   changePercent: -2.44),
    ]
}

// MARK: - Entry View

struct WatchlistWidgetEntryView: View {
    var entry: WatchlistEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  WatchlistSmallView(items: entry.items)
        case .systemMedium: WatchlistMediumView(items: entry.items)
        case .systemLarge:  WatchlistLargeView(items: entry.items)
        default:            WatchlistSmallView(items: entry.items)
        }
    }
}

// MARK: - Small (top mover)

struct WatchlistSmallView: View {
    let items: [WatchlistWidgetItem]
    private let cbMode = WidgetColorblindMode.current

    private var topMover: WatchlistWidgetItem? {
        items.max(by: { abs($0.changePercent) < abs($1.changePercent) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeaderRow(icon: "eye.fill", title: "Top Mover")

            Spacer()

            if let item = topMover {
                Text(item.symbol)
                    .font(WidgetFont.primaryLarge(.bold))
                    .foregroundColor(WidgetColor.textPrimary)

                Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textSecondary)

                DeltaChip(value: item.changePercent, size: .compact, mode: cbMode)
                    .padding(.top, 4)
            } else {
                Text("No data")
                    .font(WidgetFont.microLarge())
                    .foregroundColor(WidgetColor.textTertiary)
            }
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchlist top mover: \(topMover?.symbol ?? "none")")
    }
}

// MARK: - Medium (4 vertical rows)

struct WatchlistMediumView: View {
    let items: [WatchlistWidgetItem]
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(icon: "eye.fill", title: "Watchlist")

            ForEach(items.prefix(4)) { item in
                watchlistRow(item)
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchlist, \(items.prefix(4).count) stocks")
    }

    private func watchlistRow(_ item: WatchlistWidgetItem) -> some View {
        let color = WidgetColor.semantic(isPositive: item.isPositive, mode: cbMode)
        return HStack(spacing: 8) {
            TickerBadge(symbol: item.symbol, color: color, width: 32, height: 20)

            Text(item.symbol)
                .font(WidgetFont.microLarge(.bold))
                .foregroundColor(WidgetColor.textPrimary)

            Spacer()

            Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(WidgetFont.microSmall(.semibold))
                .foregroundColor(WidgetColor.textSecondary)

            Text("\(item.isPositive ? "+" : "")\(String(format: "%.2f", item.changePercent))%")
                .font(WidgetFont.microSmall(.bold))
                .foregroundColor(color)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Large (8 vertical rows)

struct WatchlistLargeView: View {
    let items: [WatchlistWidgetItem]
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(
                icon: "eye.fill", title: "WATCHLIST",
                trailing: "\(items.count)", trailingColor: WidgetColor.textSecondary
            )
            .padding(.bottom, 4)

            ForEach(items.prefix(8)) { item in
                largeRow(item)
            }
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchlist, \(items.prefix(8).count) stocks")
    }

    private func largeRow(_ item: WatchlistWidgetItem) -> some View {
        let color = WidgetColor.semantic(isPositive: item.isPositive, mode: cbMode)
        return HStack(spacing: 10) {
            TickerBadge(symbol: item.symbol, color: color)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.symbol)
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textPrimary)
                Text(item.name)
                    .font(WidgetFont.microTiny())
                    .foregroundColor(WidgetColor.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textPrimary)
                Text("\(item.isPositive ? "+" : "")\(String(format: "%.2f", item.changePercent))%")
                    .font(WidgetFont.microSmall(.bold))
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - Widget

struct WatchlistWidget: Widget {
    let kind: String = "WatchlistWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchlistProvider()) { entry in
            WatchlistWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Watchlist")
        .description("See your top watchlist movers at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
