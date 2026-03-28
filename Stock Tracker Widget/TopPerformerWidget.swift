//
//  TopPerformerWidget.swift
//  Stock Tracker Widget
//
//  Shows the single best-performing portfolio holding today.
//  Family: systemMedium
//  Tap target: stocktracker://asset/{symbol}
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct TopPerformerEntry: TimelineEntry {
    let date: Date
    let data: WidgetTopPerformerData?
    let portfolioIsEmpty: Bool
}

// MARK: - Provider

struct TopPerformerProvider: TimelineProvider {
    func placeholder(in context: Context) -> TopPerformerEntry {
        TopPerformerEntry(date: Date(), data: .placeholder, portfolioIsEmpty: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TopPerformerEntry) -> Void) {
        if context.isPreview {
            completion(TopPerformerEntry(date: Date(), data: .placeholder, portfolioIsEmpty: false))
            return
        }
        let data = WidgetTopPerformerData.read()
        completion(TopPerformerEntry(date: Date(), data: data, portfolioIsEmpty: data == nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopPerformerEntry>) -> Void) {
        let data = WidgetTopPerformerData.read()
        let entry = TopPerformerEntry(date: Date(), data: data, portfolioIsEmpty: data == nil)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - View

struct TopPerformerEntryView: View {
    let entry: TopPerformerEntry

    var body: some View {
        if entry.portfolioIsEmpty || entry.data == nil {
            TopPerformerEmptyView()
        } else {
            TopPerformerContentView(data: entry.data!)
        }
    }
}

// MARK: - Empty State

struct TopPerformerEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 28))
                .foregroundColor(WidgetColor.textTertiary)
            Text("Add holdings to see your top performer")
                .font(WidgetFont.microLarge())
                .foregroundColor(WidgetColor.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
    }
}

// MARK: - Content

struct TopPerformerContentView: View {
    let data: WidgetTopPerformerData
    private let cbMode = WidgetColorblindMode.current
    private var positive: Bool { data.changePercent >= 0 }
    private var accent: Color { WidgetColor.semantic(isPositive: positive, mode: cbMode) }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — holding details
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeaderRow(
                    icon: "crown.fill", title: "Top Performer",
                    iconColor: WidgetColor.premium
                )
                .padding(.bottom, 8)

                Text(data.symbol)
                    .font(WidgetFont.displaySmall(.black))
                    .foregroundColor(WidgetColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                MicroLabel(text: data.name)
                    .padding(.bottom, 8)

                Spacer()

                DeltaChip(value: data.changePercent, size: .regular, mode: cbMode)

                Text(data.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(WidgetFont.microSmall(.semibold))
                    .foregroundColor(WidgetColor.textSecondary)
                    .padding(.top, 4)
            }
            .padding(WidgetSpacing.paddingMedium)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            // Right panel — sparkline + value
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 1) {
                    MicroLabel(text: "Value")
                    Text(data.currentValue, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .font(WidgetFont.secondaryMedium(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }
                .padding(.top, WidgetSpacing.paddingMedium)
                .padding(.trailing, WidgetSpacing.paddingMedium)

                if data.sparklinePoints.count >= 2 {
                    SparklineView(
                        points: data.sparklinePoints,
                        isPositive: positive,
                        lineWidth: 2, showFill: true, showGlow: true, showLastDot: true,
                        colorblindMode: cbMode
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 12)
                    .padding(.bottom, WidgetSpacing.paddingMedium)
                } else {
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.asset(data.symbol))
        .widgetContainerBG(accent: accent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top performer \(data.symbol), \(positive ? "up" : "down") \(String(format: "%.2f", abs(data.changePercent))) percent, value \(String(format: "$%.0f", data.currentValue))")
    }
}

// MARK: - Widget Declaration

struct TopPerformerWidget: Widget {
    let kind: String = "TopPerformerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopPerformerProvider()) { entry in
            TopPerformerEntryView(entry: entry)
        }
        .configurationDisplayName("Top Performer")
        .description("Your best-performing holding today.")
        .supportedFamilies([.systemMedium])
    }
}
