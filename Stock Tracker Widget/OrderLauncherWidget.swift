//
//  OrderLauncherWidget.swift
//  Stock Tracker Widget
//
//  Trade deep-link launcher widget. Opens the in-app trade flow — NO execution in widget.
//  Families: systemSmall, systemMedium
//  Tap target: stocktracker://trade/{SYMBOL}
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct OrderLauncherEntry: TimelineEntry {
    let date: Date
    let items: [OrderLauncherItem]
}

struct OrderLauncherItem: Identifiable {
    let id: String
    let symbol: String
    let price: Double
    let changePercent: Double
    var isPositive: Bool { changePercent >= 0 }
}

// MARK: - Provider

struct OrderLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrderLauncherEntry {
        OrderLauncherEntry(date: Date(), items: Self.sampleItems)
    }

    func getSnapshot(in context: Context, completion: @escaping (OrderLauncherEntry) -> Void) {
        completion(OrderLauncherEntry(date: Date(), items: context.isPreview ? Self.sampleItems : Self.loadItems()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OrderLauncherEntry>) -> Void) {
        let entry = OrderLauncherEntry(date: Date(), items: Self.loadItems())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func loadItems() -> [OrderLauncherItem] {
        guard let shared = UserDefaults(suiteName: widgetAppGroup),
              let data = shared.data(forKey: "watchlistData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = json["items"] as? [[String: Any]]
        else { return sampleItems }

        return rawItems.prefix(3).map { r in
            OrderLauncherItem(
                id: r["id"] as? String ?? UUID().uuidString,
                symbol: r["symbol"] as? String ?? "",
                price: r["price"] as? Double ?? 0,
                changePercent: r["changePercent"] as? Double ?? 0
            )
        }
    }

    static let sampleItems: [OrderLauncherItem] = [
        OrderLauncherItem(id: "1", symbol: "AAPL",  price: 189.5,  changePercent: 1.12),
        OrderLauncherItem(id: "2", symbol: "NVDA",  price: 880.0,  changePercent: 2.86),
        OrderLauncherItem(id: "3", symbol: "TSLA",  price: 248.3,  changePercent: -1.66),
    ]
}

// MARK: - Entry View

struct OrderLauncherEntryView: View {
    let entry: OrderLauncherEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium: OrderLauncherMediumView(items: entry.items)
        default:            OrderLauncherSmallView(items: entry.items)
        }
    }
}

// MARK: - Small (single symbol + TRADE)

struct OrderLauncherSmallView: View {
    let items: [OrderLauncherItem]
    private let cbMode = WidgetColorblindMode.current

    private var item: OrderLauncherItem? { items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeaderRow(icon: "arrow.left.arrow.right", title: "Quick Trade")

            Spacer()

            if let item = item {
                let color = WidgetColor.semantic(isPositive: item.isPositive, mode: cbMode)

                Text(item.symbol)
                    .font(WidgetFont.primaryLarge(.black))
                    .foregroundColor(WidgetColor.textPrimary)

                Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textSecondary)

                Spacer()

                // TRADE button
                HStack {
                    Spacer()
                    Text("TRADE")
                        .font(WidgetFont.microLarge(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: WidgetRadius.pill)
                                .fill(color)
                        )
                    Spacer()
                }
            } else {
                Text("No data")
                    .font(WidgetFont.microLarge())
                    .foregroundColor(WidgetColor.textTertiary)
            }
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(item.map { WidgetDeepLink.trade($0.symbol) } ?? WidgetDeepLink.watchlist)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quick trade \(item?.symbol ?? "")")
    }
}

// MARK: - Medium (2-3 quick-launch tiles)

struct OrderLauncherMediumView: View {
    let items: [OrderLauncherItem]
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(icon: "arrow.left.arrow.right", title: "Quick Trade")

            HStack(spacing: WidgetSpacing.rowGapCompact) {
                ForEach(items.prefix(3)) { item in
                    tradeTile(item)
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.watchlist)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quick trade, \(items.count) symbols")
    }

    private func tradeTile(_ item: OrderLauncherItem) -> some View {
        let color = WidgetColor.semantic(isPositive: item.isPositive, mode: cbMode)

        return VStack(spacing: 6) {
            Text(item.symbol)
                .font(WidgetFont.secondaryMedium(.bold))
                .foregroundColor(WidgetColor.textPrimary)

            Text(item.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(WidgetFont.microSmall(.semibold))
                .foregroundColor(WidgetColor.textSecondary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            DeltaChip(value: item.changePercent, size: .compact, mode: cbMode)

            // BUY / SELL label
            Text(item.isPositive ? "BUY" : "SELL")
                .font(WidgetFont.microTiny(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: WidgetRadius.pill)
                        .fill(color)
                )
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
    }
}

// MARK: - Widget Declaration

struct OrderLauncherWidget: Widget {
    let kind: String = "OrderLauncherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OrderLauncherProvider()) { entry in
            OrderLauncherEntryView(entry: entry)
        }
        .configurationDisplayName("Quick Trade")
        .description("Launch trades directly from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
