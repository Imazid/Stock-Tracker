//
//  MarketOverviewWidget.swift
//  Stock Tracker Widget
//
//  Shows market open/closed status and key index prices.
//  Families: systemMedium, systemLarge
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct MarketOverviewEntry: TimelineEntry {
    let date: Date
    let isMarketOpen: Bool
    let indices: [MarketIndexItem]
}

struct MarketIndexItem: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
    var isPositive: Bool { changePercent >= 0 }
}

// MARK: - Provider

struct MarketOverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> MarketOverviewEntry {
        MarketOverviewEntry(date: Date(), isMarketOpen: true, indices: Self.sampleIndices)
    }

    func getSnapshot(in context: Context, completion: @escaping (MarketOverviewEntry) -> Void) {
        completion(MarketOverviewEntry(date: Date(), isMarketOpen: Self.checkMarketOpen(), indices: context.isPreview ? Self.sampleIndices : Self.loadData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MarketOverviewEntry>) -> Void) {
        let entry = MarketOverviewEntry(date: Date(), isMarketOpen: Self.checkMarketOpen(), indices: Self.loadData())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func loadData() -> [MarketIndexItem] {
        guard let shared = UserDefaults(suiteName: widgetAppGroup),
              let data = shared.data(forKey: "marketData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["indices"] as? [[String: Any]]
        else { return sampleIndices }

        return raw.map { r in
            MarketIndexItem(
                id: r["id"] as? String ?? UUID().uuidString,
                symbol: r["symbol"] as? String ?? "",
                name: r["name"] as? String ?? "",
                price: r["price"] as? Double ?? 0,
                change: r["change"] as? Double ?? 0,
                changePercent: r["changePercent"] as? Double ?? 0
            )
        }
    }

    static func checkMarketOpen() -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        guard weekday >= 2, weekday <= 6 else { return false }
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let minutes = hour * 60 + minute
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
    }

    static let sampleIndices: [MarketIndexItem] = [
        MarketIndexItem(id: "1", symbol: "SPY",  name: "S&P 500",       price: 4783.45, change: 18.2,  changePercent: 0.38),
        MarketIndexItem(id: "2", symbol: "QQQ",  name: "Nasdaq 100",    price: 415.20,  change: 2.8,   changePercent: 0.68),
        MarketIndexItem(id: "3", symbol: "DIA",  name: "Dow Jones",     price: 382.10,  change: -1.2,  changePercent: -0.31),
    ]
}

// MARK: - Entry View

struct MarketOverviewEntryView: View {
    var entry: MarketOverviewEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge: MarketOverviewLargeView(entry: entry)
        default:           MarketOverviewMediumView(entry: entry)
        }
    }
}

// MARK: Medium

struct MarketOverviewMediumView: View {
    let entry: MarketOverviewEntry
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        HStack(spacing: WidgetSpacing.sectionGap) {
            // Market status badge
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(WidgetColor.semantic(isPositive: entry.isMarketOpen, mode: cbMode).opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: entry.isMarketOpen ? "building.columns.fill" : "moon.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(WidgetColor.semantic(isPositive: entry.isMarketOpen, mode: cbMode))
                }
                MarketStatusDot(isOpen: entry.isMarketOpen, mode: cbMode)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(WidgetColor.semantic(isPositive: entry.isMarketOpen, mode: cbMode).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(width: 70)

            Rectangle().fill(WidgetGlass.strokeColor).frame(width: 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.indices.prefix(2)) { idx in
                    let color = WidgetColor.semantic(isPositive: idx.isPositive, mode: cbMode)
                    HStack {
                        Text(idx.symbol)
                            .font(WidgetFont.microLarge(.bold))
                            .foregroundColor(WidgetColor.textPrimary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(idx.price, format: .number.precision(.fractionLength(2)))
                                .font(WidgetFont.microLarge(.semibold))
                                .foregroundColor(WidgetColor.textPrimary)
                            Text("\(idx.isPositive ? "+" : "")\(String(format: "%.2f", idx.changePercent))%")
                                .font(WidgetFont.microSmall(.bold))
                                .foregroundColor(color)
                        }
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Market \(entry.isMarketOpen ? "open" : "closed")")
    }
}

// MARK: Large

struct MarketOverviewLargeView: View {
    let entry: MarketOverviewEntry
    private let cbMode = WidgetColorblindMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapStandard) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Market Overview")
                        .font(WidgetFont.secondaryLarge(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                    MicroLabel(text: entry.isMarketOpen ? "NYSE is Open" : "NYSE is Closed")
                }
                Spacer()
                MarketStatusDot(isOpen: entry.isMarketOpen, mode: cbMode)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(WidgetColor.semantic(isPositive: entry.isMarketOpen, mode: cbMode).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Rectangle().fill(WidgetGlass.strokeColor).frame(height: 0.5)

            VStack(spacing: 10) {
                ForEach(entry.indices) { idx in
                    let color = WidgetColor.semantic(isPositive: idx.isPositive, mode: cbMode)
                    HStack(spacing: 12) {
                        TickerBadge(symbol: idx.symbol, color: color, width: 44, height: 34)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(idx.name)
                                .font(WidgetFont.microLarge(.semibold))
                                .foregroundColor(WidgetColor.textPrimary)
                            MicroLabel(text: idx.symbol)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(idx.price, format: .number.precision(.fractionLength(2)))
                                .font(WidgetFont.secondaryMedium(.bold))
                                .foregroundColor(WidgetColor.textPrimary)
                            DeltaChip(value: idx.changePercent, size: .compact, mode: cbMode)
                        }
                    }
                    .padding(8)
                    .glassCard()
                }
            }

            Spacer()

            MicroLabel(text: "Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Market overview, \(entry.isMarketOpen ? "open" : "closed"), \(entry.indices.count) indices")
    }
}

// MARK: - Widget

struct MarketOverviewWidget: Widget {
    let kind: String = "MarketOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MarketOverviewProvider()) { entry in
            MarketOverviewEntryView(entry: entry)
        }
        .configurationDisplayName("Market Overview")
        .description("See market status and key index performance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
