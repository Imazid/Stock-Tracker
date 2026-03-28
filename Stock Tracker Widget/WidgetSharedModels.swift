//
//  WidgetSharedModels.swift
//  Stock Tracker Widget
//
//  Codable structs shared between the widget extension and the main app
//  via App Group UserDefaults ("group.com.cubeplay.stocktracker").
//
//  Writing side: MarketData.updateWidgetData() in the main app.
//  Reading side: Each widget's TimelineProvider.
//

import Foundation

// MARK: - App Group ID

let widgetAppGroup = "group.com.cubeplay.stocktracker"

// MARK: - Helpers

private func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: widgetAppGroup)
}

private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
    guard let data = sharedDefaults()?.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

// MARK: - Portfolio

struct WidgetPortfolioData: Codable {
    var totalValue: Double
    var totalChange: Double
    var totalChangePercent: Double
    var dailyChange: Double
    var dailyChangePercent: Double
    var holdings: [WidgetHolding]
    /// Normalised portfolio value history for sparkline (20 points, oldest first).
    var sparklinePoints: [Double]

    static func read() -> WidgetPortfolioData? {
        decode(WidgetPortfolioData.self, forKey: "portfolioData")
    }

    /// Convenience for Lock Screen widgets — compact "$42.5K" notation.
    var totalValueAbbreviated: String {
        switch abs(totalValue) {
        case 1_000_000...: return String(format: "$%.1fM", totalValue / 1_000_000)
        case 1_000...:     return String(format: "$%.1fK", totalValue / 1_000)
        default:           return String(format: "$%.0f", totalValue)
        }
    }

    static var placeholder: WidgetPortfolioData {
        WidgetPortfolioData(
            totalValue: 52_420,
            totalChange: 1_840,
            totalChangePercent: 3.64,
            dailyChange: 320,
            dailyChangePercent: 0.61,
            holdings: [
                WidgetHolding(id: "1", symbol: "AAPL", name: "Apple Inc.", price: 189.5,
                              changePercent: 1.2, value: 18_950, profitLossPercent: 12.4),
                WidgetHolding(id: "2", symbol: "MSFT", name: "Microsoft", price: 415.2,
                              changePercent: -0.4, value: 12_456, profitLossPercent: 8.1),
                WidgetHolding(id: "3", symbol: "NVDA", name: "Nvidia Corp.", price: 880.0,
                              changePercent: 2.8, value: 8_800, profitLossPercent: 35.2),
                WidgetHolding(id: "4", symbol: "TSLA", name: "Tesla Inc.", price: 248.3,
                              changePercent: -1.1, value: 4_966, profitLossPercent: -8.3),
                WidgetHolding(id: "5", symbol: "BTC", name: "Bitcoin", price: 62_000,
                              changePercent: 0.7, value: 6_200, profitLossPercent: 22.1)
            ],
            sparklinePoints: [48_000, 49_200, 47_800, 50_100, 51_400, 50_800, 52_100, 51_900,
                              53_200, 52_800, 54_100, 53_600, 52_900, 53_800, 54_500, 53_100,
                              52_400, 53_000, 52_800, 52_420]
        )
    }
}

struct WidgetHolding: Codable, Identifiable {
    var id: String
    var symbol: String
    var name: String
    var price: Double
    var changePercent: Double
    var value: Double
    var profitLossPercent: Double
}

// MARK: - Watchlist

struct WidgetWatchlistData: Codable {
    var items: [WidgetAsset]

    static func read() -> WidgetWatchlistData? {
        decode(WidgetWatchlistData.self, forKey: "watchlistData")
    }
}

struct WidgetAsset: Codable, Identifiable {
    var id: String
    var symbol: String
    var name: String
    var price: Double
    var change: Double
    var changePercent: Double
    /// Per-asset sparkline points (last 12), populated when available.
    var sparklinePoints: [Double]?
}

// MARK: - News

struct WidgetNewsData: Codable {
    var articles: [WidgetNewsArticle]

    static func read() -> WidgetNewsData? {
        decode(WidgetNewsData.self, forKey: "newsData")
    }

    static var placeholder: WidgetNewsData {
        WidgetNewsData(articles: [
            WidgetNewsArticle(id: "1", title: "Markets rally on strong earnings reports", source: "Reuters", publishedAt: Date().addingTimeInterval(-1800), relatedSymbol: "SPY"),
            WidgetNewsArticle(id: "2", title: "Fed signals potential rate cut in coming months", source: "Bloomberg", publishedAt: Date().addingTimeInterval(-3600), relatedSymbol: nil),
            WidgetNewsArticle(id: "3", title: "Tech sector leads gains amid AI optimism", source: "CNBC", publishedAt: Date().addingTimeInterval(-7200), relatedSymbol: "NVDA"),
            WidgetNewsArticle(id: "4", title: "Oil prices steady as OPEC maintains output", source: "WSJ", publishedAt: Date().addingTimeInterval(-10800), relatedSymbol: nil),
            WidgetNewsArticle(id: "5", title: "Crypto markets see renewed institutional interest", source: "CoinDesk", publishedAt: Date().addingTimeInterval(-14400), relatedSymbol: "BTC"),
        ])
    }
}

struct WidgetNewsArticle: Codable, Identifiable {
    var id: String
    var title: String
    var source: String
    var publishedAt: Date
    var relatedSymbol: String?

    var timeAgo: String {
        let interval = Date().timeIntervalSince(publishedAt)
        switch interval {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(interval / 60))m"
        case ..<86400:      return "\(Int(interval / 3600))h"
        default:            return "\(Int(interval / 86400))d"
        }
    }
}

// MARK: - Calendar Events

struct WidgetCalendarData: Codable {
    var events: [WidgetCalendarEvent]

    static func read() -> WidgetCalendarData? {
        decode(WidgetCalendarData.self, forKey: "calendarData")
    }

    static var placeholder: WidgetCalendarData {
        WidgetCalendarData(events: [
            WidgetCalendarEvent(id: "1", symbol: "AAPL", eventType: "earnings", date: Date().addingTimeInterval(86400 * 3), title: "Q2 Earnings", detail: "After market close"),
            WidgetCalendarEvent(id: "2", symbol: "MSFT", eventType: "dividend", date: Date().addingTimeInterval(86400 * 7), title: "Ex-Dividend", detail: "$0.75/share"),
            WidgetCalendarEvent(id: "3", symbol: "NVDA", eventType: "earnings", date: Date().addingTimeInterval(86400 * 14), title: "Q2 Earnings", detail: "Before market open"),
        ])
    }
}

struct WidgetCalendarEvent: Codable, Identifiable {
    var id: String
    var symbol: String
    var eventType: String   // "earnings", "dividend", "split"
    var date: Date
    var title: String
    var detail: String?

    var eventColor: (r: Double, g: Double, b: Double) {
        switch eventType {
        case "earnings":  return (0.4, 0.6, 1.0)   // blue
        case "dividend":  return (0.2, 0.8, 0.4)   // green
        case "split":     return (0.9, 0.6, 0.1)   // orange
        default:          return (0.65, 0.65, 0.70) // neutral
        }
    }

    var eventIcon: String {
        switch eventType {
        case "earnings":  return "chart.bar.doc.horizontal"
        case "dividend":  return "dollarsign.circle"
        case "split":     return "arrow.triangle.branch"
        default:          return "calendar"
        }
    }
}

// MARK: - Market

struct WidgetMarketData: Codable {
    var isMarketOpen: Bool
    var indices: [WidgetAsset]

    static func read() -> WidgetMarketData? {
        decode(WidgetMarketData.self, forKey: "marketData")
    }
}

// MARK: - Alerts

struct WidgetAlertsData: Codable {
    var alerts: [WidgetAlert]

    static func read() -> WidgetAlertsData? {
        decode(WidgetAlertsData.self, forKey: "alertsData")
    }
}

struct WidgetAlert: Codable, Identifiable {
    var id: String
    var symbol: String
    var targetPrice: Double
    var currentPrice: Double
    var condition: String   // "above" or "below"
}

// MARK: - Sentiment

/// Market sentiment data derived from S&P 500 daily performance.
/// Modular: replace `sentimentFromChangePercent` in MarketData to plug in a real Fear & Greed API.
struct WidgetSentimentData: Codable {
    /// "bullish" | "neutral" | "bearish"
    var sentiment: String
    /// S&P 500 daily change percent used to derive sentiment.
    var changePercent: Double
    /// Human-readable label (e.g. "Bullish Sentiment").
    var label: String
    /// SF Symbol name for this sentiment state.
    var sfSymbol: String

    static func read() -> WidgetSentimentData? {
        decode(WidgetSentimentData.self, forKey: "sentimentData")
    }

    static var placeholder: WidgetSentimentData {
        WidgetSentimentData(
            sentiment: "bullish",
            changePercent: 1.23,
            label: "Bullish Sentiment",
            sfSymbol: "chart.line.uptrend.xyaxis"
        )
    }
}

// MARK: - Top Performer

/// The single best-performing portfolio holding by daily changePercent.
struct WidgetTopPerformerData: Codable {
    var symbol: String
    var name: String
    var changePercent: Double
    var currentValue: Double
    var price: Double
    /// Mini sparkline (8 points) for the holding.
    var sparklinePoints: [Double]

    static func read() -> WidgetTopPerformerData? {
        decode(WidgetTopPerformerData.self, forKey: "topPerformerData")
    }

    static var placeholder: WidgetTopPerformerData {
        WidgetTopPerformerData(
            symbol: "NVDA",
            name: "Nvidia Corp.",
            changePercent: 4.82,
            currentValue: 8_800,
            price: 880.0,
            sparklinePoints: [820, 835, 828, 845, 852, 860, 871, 880]
        )
    }
}

// MARK: - Premium Data

/// Pro / Black tier data written by the main app; widgets use this to gate premium content.
struct WidgetPremiumData: Codable {
    /// SubscriptionTier.rawValue: "Free" | "Pro" | "Black"
    var tier: String
    var allocationSlices: [AllocationSlice]
    /// Portfolio concentration-weighted risk score 0–100.
    var riskScore: Double
    /// Portfolio % change over the last 7 days.
    var weeklyChangePercent: Double
    /// Daily portfolio values for the last 7 days (oldest first).
    var weeklyValues: [Double]

    var isPremium: Bool { tier != "Free" }

    static func read() -> WidgetPremiumData? {
        decode(WidgetPremiumData.self, forKey: "premiumData")
    }

    static var placeholder: WidgetPremiumData {
        WidgetPremiumData(
            tier: "Pro",
            allocationSlices: [
                AllocationSlice(symbol: "AAPL", name: "Apple", percent: 36.1,
                                colorR: 0.4, colorG: 0.6, colorB: 1.0),
                AllocationSlice(symbol: "MSFT", name: "Microsoft", percent: 23.8,
                                colorR: 0.6, colorG: 0.3, colorB: 0.9),
                AllocationSlice(symbol: "NVDA", name: "Nvidia", percent: 16.8,
                                colorR: 0.2, colorG: 0.8, colorB: 0.4),
                AllocationSlice(symbol: "TSLA", name: "Tesla", percent: 9.5,
                                colorR: 0.9, colorG: 0.6, colorB: 0.1),
                AllocationSlice(symbol: "Other", name: "Other", percent: 13.8,
                                colorR: 0.5, colorG: 0.5, colorB: 0.5)
            ],
            riskScore: 62.4,
            weeklyChangePercent: 3.17,
            weeklyValues: [50_100, 50_800, 49_900, 51_200, 52_100, 51_800, 52_420]
        )
    }
}

struct AllocationSlice: Codable, Identifiable {
    var id: String { symbol }
    var symbol: String
    var name: String
    var percent: Double
    // RGB components stored as doubles (avoids Color Codable issues in widget extension).
    var colorR: Double
    var colorG: Double
    var colorB: Double
}
