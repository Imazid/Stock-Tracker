//
//  PriceAlertWidget.swift
//  Stock Tracker Widget
//
//  Shows active price alerts and their proximity to current price.
//  Families: systemSmall, systemMedium
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct PriceAlertEntry: TimelineEntry {
    let date: Date
    let alerts: [AlertWidgetItem]
}

struct AlertWidgetItem: Identifiable {
    let id: String
    let symbol: String
    let targetPrice: Double
    let currentPrice: Double
    let condition: String

    var isAbove: Bool { condition == "above" }
    var percentAway: Double {
        guard currentPrice > 0 else { return 0 }
        return ((targetPrice - currentPrice) / currentPrice) * 100
    }
}

// MARK: - Provider

struct PriceAlertProvider: TimelineProvider {
    func placeholder(in context: Context) -> PriceAlertEntry {
        PriceAlertEntry(date: Date(), alerts: Self.sampleAlerts)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceAlertEntry) -> Void) {
        completion(PriceAlertEntry(date: Date(), alerts: context.isPreview ? Self.sampleAlerts : Self.loadAlerts()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceAlertEntry>) -> Void) {
        let entry = PriceAlertEntry(date: Date(), alerts: Self.loadAlerts())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    static func loadAlerts() -> [AlertWidgetItem] {
        guard let shared = UserDefaults(suiteName: widgetAppGroup),
              let data = shared.data(forKey: "alertsData"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["alerts"] as? [[String: Any]], !raw.isEmpty
        else { return [] }

        return raw.map { r in
            AlertWidgetItem(
                id: r["id"] as? String ?? UUID().uuidString,
                symbol: r["symbol"] as? String ?? "",
                targetPrice: r["targetPrice"] as? Double ?? 0,
                currentPrice: r["currentPrice"] as? Double ?? 0,
                condition: r["condition"] as? String ?? "above"
            )
        }
    }

    static let sampleAlerts: [AlertWidgetItem] = [
        AlertWidgetItem(id: "1", symbol: "AAPL", targetPrice: 200.0, currentPrice: 189.5, condition: "above"),
        AlertWidgetItem(id: "2", symbol: "TSLA", targetPrice: 240.0, currentPrice: 248.3, condition: "below"),
        AlertWidgetItem(id: "3", symbol: "BTC",  targetPrice: 65000, currentPrice: 62000, condition: "above"),
    ]
}

// MARK: - Entry View

struct PriceAlertEntryView: View {
    var entry: PriceAlertEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium: PriceAlertMediumView(entry: entry)
        default:            PriceAlertSmallView(entry: entry)
        }
    }
}

// MARK: Small

struct PriceAlertSmallView: View {
    let entry: PriceAlertEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeaderRow(icon: "bell.fill", title: "Alerts", iconColor: WidgetColor.warning)

            Spacer()

            if entry.alerts.isEmpty {
                Text("No Alerts Set")
                    .font(WidgetFont.secondaryMedium(.semibold))
                    .foregroundColor(WidgetColor.textTertiary)
                MicroLabel(text: "Add alerts in the app.")
            } else {
                Text("\(entry.alerts.count)")
                    .font(WidgetFont.displayMedium(.bold))
                    .foregroundColor(WidgetColor.warning)
                Text("Active Alert\(entry.alerts.count == 1 ? "" : "s")")
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textSecondary)

                if let first = entry.alerts.first {
                    MicroLabel(text: "\(first.symbol) → \(String(format: "$%.2f", first.targetPrice))")
                }
            }
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.alerts.count) active price alerts")
    }
}

// MARK: Medium

struct PriceAlertMediumView: View {
    let entry: PriceAlertEntry

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(
                icon: "bell.fill", title: "Price Alerts",
                iconColor: WidgetColor.warning,
                trailing: "\(entry.alerts.count) active",
                trailingColor: WidgetColor.warning
            )

            if entry.alerts.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "bell.slash")
                            .font(.largeTitle)
                            .foregroundColor(WidgetColor.textTertiary.opacity(0.4))
                        Text("No price alerts set")
                            .font(WidgetFont.microLarge())
                            .foregroundColor(WidgetColor.textTertiary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                VStack(spacing: 6) {
                    ForEach(entry.alerts.prefix(3)) { alert in
                        alertRow(alert)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.alerts.count) price alerts")
    }

    private func alertRow(_ alert: AlertWidgetItem) -> some View {
        HStack(spacing: 10) {
            TickerBadge(symbol: alert.symbol, color: WidgetColor.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.symbol)
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textPrimary)
                Text("\(alert.isAbove ? "▲" : "▼") \(alert.targetPrice, format: .currency(code: "USD").precision(.fractionLength(2)))")
                    .font(WidgetFont.microTiny())
                    .foregroundColor(WidgetColor.warning.opacity(0.8))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(alert.currentPrice, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(WidgetFont.microLarge(.semibold))
                    .foregroundColor(WidgetColor.textPrimary)
                let pct = alert.percentAway
                DeltaChip(value: pct, size: .compact)
            }
        }
        .padding(6)
        .glassCard()
    }
}

// MARK: - Widget

struct PriceAlertWidget: Widget {
    let kind: String = "PriceAlertWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PriceAlertProvider()) { entry in
            PriceAlertEntryView(entry: entry)
        }
        .configurationDisplayName("Price Alerts")
        .description("Track your active price alerts and how close they are to triggering.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
