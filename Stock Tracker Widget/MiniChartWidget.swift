//
//  MiniChartWidget.swift
//  Stock Tracker Widget
//
//  Portfolio performance chart widget.
//  Families: systemMedium, systemLarge
//  Tap target: stocktracker://portfolio
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct MiniChartEntry: TimelineEntry {
    let date: Date
    let data: WidgetPortfolioData
}

// MARK: - Provider

struct MiniChartProvider: TimelineProvider {
    func placeholder(in context: Context) -> MiniChartEntry {
        MiniChartEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MiniChartEntry) -> Void) {
        let data = context.isPreview ? WidgetPortfolioData.placeholder : (WidgetPortfolioData.read() ?? .placeholder)
        completion(MiniChartEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MiniChartEntry>) -> Void) {
        let data = WidgetPortfolioData.read() ?? .placeholder
        let entry = MiniChartEntry(date: Date(), data: data)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Entry View

struct MiniChartEntryView: View {
    let entry: MiniChartEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge: MiniChartLargeView(data: entry.data)
        default:           MiniChartMediumView(data: entry.data)
        }
    }
}

// MARK: - Medium View

struct MiniChartMediumView: View {
    let data: WidgetPortfolioData
    private let cbMode = WidgetColorblindMode.current

    private var dailyPositive: Bool { data.dailyChange >= 0 }
    private var allTimePositive: Bool { data.totalChange >= 0 }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel (40%) — metrics
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeaderRow(icon: "chart.xyaxis.line", title: "Performance")

                Spacer()

                Text(data.totalValueAbbreviated)
                    .font(WidgetFont.primaryLarge(.bold))
                    .foregroundColor(WidgetColor.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Spacer()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Image(systemName: dailyPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(dailyPositive ? "+" : "")\(String(format: "$%.0f", data.dailyChange))")
                            .font(WidgetFont.microSmall(.bold))
                    }
                    .foregroundColor(WidgetColor.semantic(isPositive: dailyPositive, mode: cbMode))

                    DeltaChip(value: data.dailyChangePercent, size: .compact, mode: cbMode)

                    MicroLabel(
                        text: "All-time \(allTimePositive ? "+" : "")\(String(format: "%.1f", data.totalChangePercent))%",
                        color: WidgetColor.semantic(isPositive: allTimePositive, mode: cbMode).opacity(0.75)
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .padding(.leading, WidgetSpacing.paddingMedium)
            .padding(.vertical, WidgetSpacing.paddingMedium)

            // Right panel (60%) — sparkline
            VStack(alignment: .trailing, spacing: 4) {
                MicroLabel(text: "Today")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .padding(.top, 12)

                if data.sparklinePoints.count >= 2 {
                    SparklineView(
                        points: data.sparklinePoints,
                        isPositive: dailyPositive,
                        lineWidth: 2, showFill: true, showGlow: true, showLastDot: true,
                        colorblindMode: cbMode
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                } else {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<12, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(WidgetColor.textTertiary.opacity(0.2))
                                .frame(width: 4, height: CGFloat.random(in: 10...40))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance chart, portfolio \(data.totalValueAbbreviated)")
    }
}

// MARK: - Large View

struct MiniChartLargeView: View {
    let data: WidgetPortfolioData
    private let cbMode = WidgetColorblindMode.current

    private var dailyPositive: Bool { data.dailyChange >= 0 }
    private var allTimePositive: Bool { data.totalChange >= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapStandard) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeaderRow(icon: "chart.xyaxis.line", title: "Performance")
                    HeroPriceBlock(value: data.totalValue, family: .systemLarge)
                }
                Spacer()
                DeltaChip(value: data.totalChangePercent, mode: cbMode)
            }

            // Sparkline — 65% height
            if data.sparklinePoints.count >= 2 {
                SparklineView(
                    points: data.sparklinePoints,
                    isPositive: dailyPositive,
                    lineWidth: 2.5, showFill: true, showGlow: true, showLastDot: true,
                    colorblindMode: cbMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 3-stat row
            HStack(spacing: WidgetSpacing.sectionGap) {
                statBlock(
                    label: "Today",
                    value: "\(dailyPositive ? "+" : "")\(String(format: "%.2f", data.dailyChangePercent))%",
                    color: WidgetColor.semantic(isPositive: dailyPositive, mode: cbMode)
                )
                statBlock(
                    label: "All-Time",
                    value: "\(allTimePositive ? "+" : "")\(String(format: "%.1f", data.totalChangePercent))%",
                    color: WidgetColor.semantic(isPositive: allTimePositive, mode: cbMode)
                )
                statBlock(
                    label: "Value",
                    value: data.totalValueAbbreviated,
                    color: WidgetColor.textPrimary
                )
            }
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance chart, portfolio \(data.totalValueAbbreviated)")
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MicroLabel(text: label)
            Text(value)
                .font(WidgetFont.secondaryMedium(.bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget Declaration

struct MiniChartWidget: Widget {
    let kind: String = "MiniChartWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MiniChartProvider()) { entry in
            MiniChartEntryView(entry: entry)
        }
        .configurationDisplayName("Performance Chart")
        .description("Portfolio sparkline with daily P&L.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
