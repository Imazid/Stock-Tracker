//
//  MarketStatusView.swift
//  Stock Tracker
//
//  Market status pills ("NYSE · Open · closes 7:00 am") for the markets a
//  person actually follows. Hours are computed in each exchange's own time zone
//  with its holidays and early closes; the next open/close is shown in the
//  person's local time.
//
//  Settings → Market status (`@AppStorage("preferredMarket")`):
//  "auto" (default — from the watchlist and holdings), "US", "AU" or "BOTH".
//

import SwiftUI
import Combine

// MARK: - Exchanges

enum StockExchangeMarket: String, CaseIterable, Identifiable {
    case us, asx

    var id: String { rawValue }
    var name: String { self == .us ? "NYSE" : "ASX" }
    var longName: String { self == .us ? "US market" : "ASX" }

    var timeZone: TimeZone {
        TimeZone(identifier: self == .us ? "America/New_York" : "Australia/Sydney")!
    }

    /// Minutes after local midnight.
    var preOpen: Int { self == .us ? 4 * 60 : 7 * 60 }
    var open: Int { self == .us ? 9 * 60 + 30 : 10 * 60 }
    var close: Int { 16 * 60 }
    /// End of after-hours trading (US only).
    var postClose: Int { self == .us ? 20 * 60 : 16 * 60 }
    /// Early close time on half days.
    var earlyClose: Int { self == .us ? 13 * 60 : 14 * 60 + 10 }

    /// Full-day closures (yyyy-MM-dd, exchange local) → name. Published exchange calendars;
    /// extend each year.
    var holidays: [String: String] {
        switch self {
        case .us:
            return [
                "2026-01-01": "New Year's Day", "2026-01-19": "Martin Luther King Jr. Day",
                "2026-02-16": "Presidents' Day", "2026-04-03": "Good Friday",
                "2026-05-25": "Memorial Day", "2026-06-19": "Juneteenth",
                "2026-07-03": "Independence Day", "2026-09-07": "Labor Day",
                "2026-11-26": "Thanksgiving", "2026-12-25": "Christmas",
                "2027-01-01": "New Year's Day", "2027-01-18": "Martin Luther King Jr. Day",
                "2027-02-15": "Presidents' Day", "2027-03-26": "Good Friday",
                "2027-05-31": "Memorial Day", "2027-06-18": "Juneteenth",
                "2027-07-05": "Independence Day", "2027-09-06": "Labor Day",
                "2027-11-25": "Thanksgiving", "2027-12-24": "Christmas"
            ]
        case .asx:
            return [
                "2026-01-01": "New Year's Day", "2026-01-26": "Australia Day",
                "2026-04-03": "Good Friday", "2026-04-06": "Easter Monday",
                "2026-06-08": "King's Birthday", "2026-12-25": "Christmas",
                "2026-12-28": "Boxing Day",
                "2027-01-01": "New Year's Day", "2027-01-26": "Australia Day",
                "2027-03-26": "Good Friday", "2027-03-29": "Easter Monday",
                "2027-06-14": "King's Birthday", "2027-12-27": "Christmas",
                "2027-12-28": "Boxing Day"
            ]
        }
    }

    var earlyCloses: Set<String> {
        switch self {
        case .us:  return ["2026-11-27", "2026-12-24", "2027-11-26"]
        case .asx: return ["2026-12-24", "2026-12-31", "2027-12-24", "2027-12-31"]
        }
    }
}

// MARK: - Clock

struct MarketClockStatus: Equatable {
    enum Phase: Equatable { case open, preMarket, afterHours, closed }

    let market: StockExchangeMarket
    let phase: Phase
    /// When the phase next changes to/from regular trading (open → close time, otherwise next open).
    let nextChange: Date?
    /// Holiday name when the market is closed for one today.
    let holiday: String?
}

enum MarketClock {
    static func status(for market: StockExchangeMarket, at now: Date = Date()) -> MarketClockStatus {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = market.timeZone
        let key = dayKey(now, cal)
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let holiday = market.holidays[key]

        if isTradingDay(now, market, cal) {
            let close = market.earlyCloses.contains(key) ? market.earlyClose : market.close
            let postClose = market.earlyCloses.contains(key) ? close : market.postClose
            if minutes >= market.open && minutes < close {
                return .init(market: market, phase: .open, nextChange: date(on: now, minutes: close, cal), holiday: nil)
            }
            if minutes >= market.preOpen && minutes < market.open {
                return .init(market: market, phase: .preMarket, nextChange: date(on: now, minutes: market.open, cal), holiday: nil)
            }
            if market == .us && minutes >= close && minutes < postClose {
                return .init(market: market, phase: .afterHours, nextChange: nextOpen(after: now, market, cal), holiday: nil)
            }
        }
        return .init(market: market, phase: .closed, nextChange: nextOpen(after: now, market, cal),
                     holiday: holiday)
    }

    static func isTradingDay(_ date: Date, _ market: StockExchangeMarket, _ cal: Calendar) -> Bool {
        let weekday = cal.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        return market.holidays[dayKey(date, cal)] == nil
    }

    static func nextOpen(after now: Date, _ market: StockExchangeMarket, _ cal: Calendar) -> Date? {
        for offset in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  isTradingDay(day, market, cal),
                  let open = date(on: day, minutes: market.open, cal) else { continue }
            if open > now { return open }
        }
        return nil
    }

    private static func date(on day: Date, minutes: Int, _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    private static func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "7:00 am" today, otherwise "Mon 12:30 am" — in the person's own time zone.
    static func localTimeText(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return f.string(from: date)
    }
}

// MARK: - View

struct MarketStatusView: View {
    /// Explicit markets; nil = follow the Settings preference ("auto" uses what you track).
    var markets: [StockExchangeMarket]? = nil

    @AppStorage("preferredMarket") private var preferredMarket: String = "auto"
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @State private var now = Date()

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var shownMarkets: [StockExchangeMarket] {
        if let markets, !markets.isEmpty { return markets }
        switch preferredMarket {
        case "US":   return [.us]
        case "AU":   return [.asx]
        case "BOTH": return [.asx, .us]
        default:     return Self.followedMarkets(in: marketData)
        }
    }

    /// Stock markets present in the watchlist and holdings (crypto trades 24/7).
    static func followedMarkets(in marketData: MarketData) -> [StockExchangeMarket] {
        let assets = marketData.watchlist + marketData.portfolio.map(\.asset)
        let stocks = assets.filter { $0.kind == .stock }
        let hasASX = stocks.contains { QuoteService.isASX($0) }
        let hasUS = stocks.contains { !QuoteService.isASX($0) }
        var result: [StockExchangeMarket] = []
        if hasASX { result.append(.asx) }
        if hasUS { result.append(.us) }
        if result.isEmpty {
            result = Locale.current.region?.identifier == "AU" ? [.asx] : [.us]
        }
        return result
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) { pills }
            VStack(alignment: .leading, spacing: DS.Space.xs) { pills }
        }
        .onAppear { now = Date() }
        .onReceive(ticker) { now = $0 }
    }

    @ViewBuilder
    private var pills: some View {
        ForEach(shownMarkets) { market in
            MarketStatusPill(status: MarketClock.status(for: market, at: now), now: now)
        }
    }
}

struct MarketStatusPill: View {
    let status: MarketClockStatus
    var now: Date = Date()
    @Environment(\.theme) private var theme

    private var dotColor: Color {
        switch status.phase {
        case .open:                   return theme.positiveColor
        case .preMarket, .afterHours: return theme.warningColor
        case .closed:                 return theme.secondaryText.opacity(0.5)
        }
    }

    private var phaseText: String {
        switch status.phase {
        case .open:       return "Open"
        case .preMarket:  return "Pre-market"
        case .afterHours: return "After hours"
        case .closed:     return status.holiday.map { "Closed · \($0)" } ?? "Closed"
        }
    }

    private var nextText: String? {
        guard let next = status.nextChange else { return nil }
        let time = MarketClock.localTimeText(next, now: now)
        return status.phase == .open ? "closes \(time)" : "opens \(time)"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(status.market.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(phaseText)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            if let nextText {
                Text("· \(nextText)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.subtleFill))
        .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.market.longName) \(phaseText)\(nextText.map { ", \($0)" } ?? "")")
        .accessibilityIdentifier("marketStatus.\(status.market.rawValue)")
    }
}

// MARK: - Legacy session model (used by MarketSentimentView)

enum MarketSession {
    case open, premarket, closed

    var color: Color {
        switch self {
        case .open:      return .green
        case .premarket: return .orange
        case .closed:    return Color(UIColor.systemGray3)
        }
    }

    var label: String {
        switch self {
        case .open:      return "Open"
        case .premarket: return "Pre-Market"
        case .closed:    return "Closed"
        }
    }
}
