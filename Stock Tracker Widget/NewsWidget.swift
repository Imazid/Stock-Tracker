//
//  NewsWidget.swift
//  Stock Tracker Widget
//
//  News & headlines widget.
//  Families: systemMedium, systemLarge, accessoryRectangular
//  Tap target: stocktracker://news
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct NewsEntry: TimelineEntry {
    let date: Date
    let data: WidgetNewsData
}

// MARK: - Provider

struct NewsProvider: TimelineProvider {
    func placeholder(in context: Context) -> NewsEntry {
        NewsEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NewsEntry) -> Void) {
        let data = context.isPreview ? WidgetNewsData.placeholder : (WidgetNewsData.read() ?? .placeholder)
        completion(NewsEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NewsEntry>) -> Void) {
        let data = WidgetNewsData.read() ?? .placeholder
        let entry = NewsEntry(date: Date(), data: data)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Entry View

struct NewsEntryView: View {
    let entry: NewsEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemLarge:          NewsLargeView(data: entry.data)
        case .accessoryRectangular: NewsAccessoryRectangular(data: entry.data)
        default:                    NewsMediumView(data: entry.data)
        }
    }
}

// MARK: - Medium (2-3 headlines)

struct NewsMediumView: View {
    let data: WidgetNewsData

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(
                icon: "newspaper.fill", title: "News",
                trailing: "\(data.articles.count)", trailingColor: WidgetColor.textSecondary
            )

            ForEach(data.articles.prefix(3)) { article in
                newsRow(article)
            }

            if data.articles.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "newspaper")
                            .font(.title2)
                            .foregroundColor(WidgetColor.textTertiary)
                        Text("No news yet")
                            .font(WidgetFont.microLarge())
                            .foregroundColor(WidgetColor.textTertiary)
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.news)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("News, \(data.articles.count) headlines")
    }

    private func newsRow(_ article: WidgetNewsArticle) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(article.source)
                        .font(WidgetFont.microTiny(.bold))
                        .foregroundColor(WidgetColor.textSecondary)
                    Text(article.timeAgo)
                        .font(WidgetFont.microTiny())
                        .foregroundColor(WidgetColor.textTertiary)
                    if let sym = article.relatedSymbol {
                        Text(sym)
                            .font(WidgetFont.microTiny(.bold))
                            .foregroundColor(WidgetColor.warning)
                    }
                }
                Text(article.title)
                    .font(WidgetFont.microSmall(.medium))
                    .foregroundColor(WidgetColor.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .glassCard()
    }
}

// MARK: - Large (4-5 headlines)

struct NewsLargeView: View {
    let data: WidgetNewsData

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(
                icon: "newspaper.fill", title: "NEWS",
                trailing: "\(data.articles.count) articles", trailingColor: WidgetColor.textSecondary
            )
            .padding(.bottom, 4)

            ForEach(data.articles.prefix(5)) { article in
                largeNewsRow(article)
            }

            Spacer(minLength: 0)
        }
        .padding(WidgetSpacing.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.news)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("News, \(data.articles.count) headlines")
    }

    private func largeNewsRow(_ article: WidgetNewsArticle) -> some View {
        HStack(spacing: 10) {
            // Source badge
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(WidgetColor.bg2)
                    .frame(width: 36, height: 36)
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(WidgetColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(article.source)
                        .font(WidgetFont.microTiny(.bold))
                        .foregroundColor(WidgetColor.textSecondary)
                    Text(article.timeAgo)
                        .font(WidgetFont.microTiny())
                        .foregroundColor(WidgetColor.textTertiary)
                    if let sym = article.relatedSymbol {
                        TickerBadge(symbol: sym, color: WidgetColor.warning, width: 28, height: 16)
                    }
                }
                Text(article.title)
                    .font(WidgetFont.microSmall(.medium))
                    .foregroundColor(WidgetColor.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .glassCard()
    }
}

// MARK: - Lock Screen: Accessory Rectangular

struct NewsAccessoryRectangular: View {
    let data: WidgetNewsData

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NEWS")
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
                .widgetAccentable()

            if let article = data.articles.first {
                Text(article.title)
                    .font(.caption2)
                    .lineLimit(2)
            } else {
                Text("No headlines")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .widgetURL(WidgetDeepLink.news)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Widget Declaration

struct NewsWidget: Widget {
    let kind: String = "NewsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NewsProvider()) { entry in
            NewsEntryView(entry: entry)
        }
        .configurationDisplayName("News")
        .description("Latest market headlines at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}
