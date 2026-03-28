//
//  SentimentWidget.swift
//  Stock Tracker Widget
//
//  Market Sentiment derived from S&P 500 daily performance.
//  Families: accessoryCircular (Lock Screen), systemSmall (Home Screen)
//  Tap target: stocktracker://home
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct SentimentEntry: TimelineEntry {
    let date: Date
    let data: WidgetSentimentData
    let isMarketOpen: Bool
}

// MARK: - Provider

struct SentimentProvider: TimelineProvider {
    func placeholder(in context: Context) -> SentimentEntry {
        SentimentEntry(date: Date(), data: .placeholder, isMarketOpen: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SentimentEntry) -> Void) {
        let data = context.isPreview ? WidgetSentimentData.placeholder : (WidgetSentimentData.read() ?? .placeholder)
        let marketOpen = WidgetMarketData.read()?.isMarketOpen ?? false
        completion(SentimentEntry(date: Date(), data: data, isMarketOpen: marketOpen))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SentimentEntry>) -> Void) {
        let data = WidgetSentimentData.read() ?? .placeholder
        let marketOpen = WidgetMarketData.read()?.isMarketOpen ?? false
        let entry = SentimentEntry(date: Date(), data: data, isMarketOpen: marketOpen)
        let minutes = marketOpen ? 30 : 120
        let next = Calendar.current.date(byAdding: .minute, value: minutes, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Helpers

private func sentimentColor(for key: String, mode: WidgetColorblindMode = .current) -> Color {
    switch key {
    case "bullish":  return WidgetColor.positive(for: mode)
    case "bearish":  return WidgetColor.negative(for: mode)
    default:         return WidgetColor.neutral
    }
}

private func sentimentIcon(for symbol: String) -> String {
    symbol.isEmpty ? "chart.bar.fill" : symbol
}

// MARK: - Root Entry View

struct SentimentEntryView: View {
    var entry: SentimentEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular: SentimentCircularView(entry: entry)
        case .systemSmall:       SentimentSmallView(entry: entry)
        default:                 SentimentSmallView(entry: entry)
        }
    }
}

// MARK: - Lock Screen: Accessory Circular

struct SentimentCircularView: View {
    let entry: SentimentEntry
    private var color: Color { sentimentColor(for: entry.data.sentiment) }

    var body: some View {
        ZStack {
            let progress = min(abs(entry.data.changePercent) / 3.0, 1.0)
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Image(systemName: sentimentIcon(for: entry.data.sfSymbol))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
                    .widgetAccentable()
                Text(shortLabel(for: entry.data.sentiment))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .widgetAccentable()
            }
        }
        .widgetURL(WidgetDeepLink.home)
        .containerBackground(.clear, for: .widget)
    }

    private func shortLabel(for key: String) -> String {
        switch key {
        case "bullish": return "BULL"
        case "bearish": return "BEAR"
        default:        return "NEUT"
        }
    }
}

// MARK: - Home Screen: System Small

struct SentimentSmallView: View {
    let entry: SentimentEntry
    private let cbMode = WidgetColorblindMode.current
    private var color: Color { sentimentColor(for: entry.data.sentiment, mode: cbMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeaderRow(icon: "waveform.path.ecg", title: "Sentiment")

            Spacer()

            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: sentimentIcon(for: entry.data.sfSymbol))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(color)
            }

            Spacer()

            Text(entry.data.label)
                .font(WidgetFont.microLarge(.bold))
                .foregroundColor(WidgetColor.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            HStack(spacing: 3) {
                MicroLabel(text: "S&P 500")
                let positive = entry.data.changePercent >= 0
                Text("\(positive ? "+" : "")\(String(format: "%.2f", entry.data.changePercent))%")
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(color)
            }
            .padding(.top, 2)

            MarketStatusDot(isOpen: entry.isMarketOpen, mode: cbMode)
                .padding(.top, 4)
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.home)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.data.label), S&P 500 \(String(format: "%.2f", entry.data.changePercent)) percent, market \(entry.isMarketOpen ? "open" : "closed")")
    }
}

// MARK: - Widget Declaration

struct SentimentWidget: Widget {
    let kind: String = "SentimentWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SentimentProvider()) { entry in
            SentimentEntryView(entry: entry)
        }
        .configurationDisplayName("Market Sentiment")
        .description("Bullish, neutral, or bearish — at a glance.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}
