//
//  EarningsCalendar.swift
//  Stock Tracker
//
//  "Coming up": the next earnings report for the US stocks you hold or follow, from
//  Finnhub's free earnings calendar, plus a "Remind me" local notification an hour
//  before. After Public's "Earnings & events" and Yahoo Finance's "54 days to earnings ·
//  Set reminder" on Mobbin.
//
//  Per-symbol requests on purpose: the market-wide calendar is capped at 1,500 rows
//  (a 45-day window hit exactly that in earnings season), so it silently drops symbols.
//  Each answer is cached for 12 hours, on disk, so a launch doesn't refetch.
//  ASX listings aren't covered — Finnhub's free plan has no ASX earnings.
//

import Foundation
import SwiftUI
import Combine
import UserNotifications
import OSLog

// MARK: - Model

struct EarningsEvent: Codable, Hashable, Identifiable, Sendable {
    enum Timing: String, Codable, Sendable {
        case beforeOpen = "bmo", afterClose = "amc", duringMarket = "dmh", unknown = ""
    }

    let symbol: String
    /// The report's date on Wall Street ("2026-11-02", US Eastern).
    let day: String
    let timing: Timing
    /// USD, like every stored price.
    let epsEstimate: Double?
    let quarter: Int?
    let year: Int?

    var id: String { "\(symbol)-\(day)" }

    private static let eastern = TimeZone(identifier: "America/New_York")!

    /// Roughly when the numbers land: 8:00 before the open, 16:05 after the close,
    /// midday during the session, 9:30 when the company hasn't said.
    var moment: Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.eastern
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (hour, minute): (Int, Int) = switch timing {
        case .beforeOpen: (8, 0)
        case .afterClose: (16, 5)
        case .duringMarket: (12, 0)
        case .unknown: (9, 30)
        }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute))
    }

    var timingText: String {
        switch timing {
        case .beforeOpen: "before the US open"
        case .afterClose: "after the US close"
        case .duringMarket: "during the US session"
        case .unknown: "time not announced"
        }
    }

    /// Compact form for rows and cards ("After close").
    var shortTimingText: String {
        switch timing {
        case .beforeOpen: "Before open"
        case .afterClose: "After close"
        case .duringMarket: "During session"
        case .unknown: "Time TBC"
        }
    }

    var quarterText: String? {
        guard let quarter, let year else { return nil }
        return "Q\(quarter) \(year)"
    }

    /// "Mon 2 Nov" — the Wall Street date, which is what companies announce.
    var dateText: String {
        guard let date = moment else { return day }
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = Self.eastern
        return date.formatted(style)
    }

    /// "Today", "Tomorrow", "in 16 days" (calendar days in the person's own time zone).
    func countdownText(now: Date = Date()) -> String {
        guard let date = moment else { return "" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return "Reported"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(days) days"
        }
    }

    func isUpcoming(now: Date = Date()) -> Bool {
        guard let date = moment else { return false }
        return date.addingTimeInterval(6 * 3600) >= now   // keep "Today" until the numbers are out
    }
}

// MARK: - Service

@MainActor
final class EarningsCalendar: ObservableObject {
    static let shared = EarningsCalendar()

    /// Next report per US symbol you follow, soonest first.
    @Published private(set) var upcoming: [EarningsEvent] = []
    @Published private(set) var reminders: Set<String> = []

    private struct CacheEntry: Codable {
        let fetchedAt: Date
        let event: EarningsEvent?   // nil = no report in the next 90 days
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<EarningsEvent?, Never>] = [:]
    private let session = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 15)
    private let cacheKey = "earnings_calendar_cache_v1"
    private let remindersKey = "earnings_reminders_v1"
    private static let maxAge: TimeInterval = 12 * 3600

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = saved
        }
        reminders = Set(UserDefaults.standard.stringArray(forKey: remindersKey) ?? [])
    }

    /// US listings only: Finnhub's free calendar has no ASX, crypto or index earnings.
    static func covers(_ asset: Asset) -> Bool {
        asset.kind == .stock && !QuoteService.isASX(asset) && !asset.symbol.hasPrefix("^")
    }

    /// Refreshes `upcoming` for the given assets (watchlist + holdings).
    func refresh(for assets: [Asset]) async {
        let symbols = Array(Set(assets.filter(Self.covers).map { $0.symbol.uppercased() })).sorted()
        var events: [EarningsEvent] = []
        for symbol in symbols {
            if let event = await next(for: symbol) { events.append(event) }
        }
        let now = Date()
        upcoming = events
            .filter { $0.isUpcoming(now: now) }
            .sorted { ($0.moment ?? .distantFuture) < ($1.moment ?? .distantFuture) }
    }

    /// The next report for one symbol (cached 12h; concurrent asks share one request).
    func next(for symbol: String) async -> EarningsEvent? {
        let symbol = symbol.uppercased()
        if let entry = cache[symbol], Date().timeIntervalSince(entry.fetchedAt) < Self.maxAge {
            return entry.event.flatMap { $0.isUpcoming() ? $0 : nil }
        }
        if let running = inFlight[symbol] { return await running.value }
        let task = Task<EarningsEvent?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                let event = try await self.fetch(symbol)
                self.cache[symbol] = CacheEntry(fetchedAt: Date(), event: event)
                self.saveCache()
                return event
            } catch {
                AppLogger.api.info("Earnings calendar unavailable for \(symbol): \(error.localizedDescription)")
                // Keep showing a stale answer rather than nothing; it's still the announced date.
                return self.cache[symbol]?.event
            }
        }
        inFlight[symbol] = task
        let result = await task.value
        inFlight[symbol] = nil
        return result.flatMap { $0.isUpcoming() ? $0 : nil }
    }

    private func fetch(_ symbol: String) async throws -> EarningsEvent? {
        let key = SecretsConfig.finnhubAPIKey
        guard !key.isEmpty else { return nil }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "America/New_York")
        day.dateFormat = "yyyy-MM-dd"
        var components = URLComponents(string: "\(Constants.URLs.finnhub)/calendar/earnings")!
        components.queryItems = [
            URLQueryItem(name: "from", value: day.string(from: Date())),
            URLQueryItem(name: "to", value: day.string(from: Date().addingTimeInterval(90 * 86_400))),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: key)
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await session.rateLimitedData(
            for: URLRequest(url: url), endpoint: "finnhub", config: .newsAPI)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.parse(data, symbol: symbol)
    }

    nonisolated static func parse(_ data: Data, symbol: String) throws -> EarningsEvent? {
        struct Row: Decodable {
            let symbol: String?
            let date: String?
            let hour: String?
            let epsEstimate: Double?
            let quarter: Int?
            let year: Int?
        }
        struct Body: Decodable { let earningsCalendar: [Row]? }
        let rows = try JSONDecoder().decode(Body.self, from: data).earningsCalendar ?? []
        return rows
            .filter { ($0.symbol ?? "").uppercased() == symbol }
            .compactMap { row -> EarningsEvent? in
                guard let date = row.date, !date.isEmpty else { return nil }
                return EarningsEvent(symbol: symbol, day: date,
                                     timing: EarningsEvent.Timing(rawValue: row.hour ?? "") ?? .unknown,
                                     epsEstimate: row.epsEstimate, quarter: row.quarter, year: row.year)
            }
            .sorted { $0.day < $1.day }
            .first
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: Reminders

    func hasReminder(_ event: EarningsEvent) -> Bool { reminders.contains(event.id) }

    /// Schedules (or cancels) a local notification an hour before the report.
    /// Returns false if notifications are off, so the screen can say so.
    @discardableResult
    func toggleReminder(_ event: EarningsEvent, name: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let id = "earnings-\(event.id)"
        if reminders.contains(event.id) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            reminders.remove(event.id)
            saveReminders()
            return true
        }
        guard let moment = event.moment else { return false }
        let fireAt = max(moment.addingTimeInterval(-3600), Date().addingTimeInterval(60))
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return false }
        } else if settings.authorizationStatus == .denied {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = "\(name) reports earnings soon"
        content.body = "\(event.symbol) is due \(event.timingText)\(event.quarterText.map { " for \($0)" } ?? "")."
        content.sound = .default
        content.userInfo = ["symbol": event.symbol]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        do {
            try await center.add(request)
            reminders.insert(event.id)
            saveReminders()
            return true
        } catch {
            return false
        }
    }

    private func saveReminders() {
        UserDefaults.standard.set(Array(reminders), forKey: remindersKey)
    }
}

// MARK: - Home: "Coming up"

/// Next earnings for what you hold or follow, within 30 days. Hidden when there's nothing.
struct HomeComingUpSection: View {
    @EnvironmentObject private var marketData: MarketData
    @ObservedObject private var calendar = EarningsCalendar.shared
    @Environment(\.theme) private var theme
    @State private var selected: Asset?
    @State private var showAll = false

    private var tracked: [Asset] { marketData.portfolio.map(\.asset) + marketData.watchlist }
    private var soon: [EarningsEvent] {
        let limit = Date().addingTimeInterval(30 * 86_400)
        return calendar.upcoming.filter { ($0.moment ?? .distantFuture) <= limit }
    }

    var body: some View {
        Group {
            if !soon.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SectionHeader(title: "Coming up",
                                  actionTitle: calendar.upcoming.count > 4 ? "See all" : nil,
                                  action: calendar.upcoming.count > 4 ? { showAll = true } : nil)
                    VStack(spacing: 0) {
                        ForEach(Array(soon.prefix(4).enumerated()), id: \.element.id) { index, event in
                            EarningsRow(event: event, asset: asset(for: event.symbol)) {
                                selected = asset(for: event.symbol)
                            }
                            if index < min(soon.count, 4) - 1 {
                                Divider().overlay(theme.cardBorder.opacity(0.3)).padding(.leading, 52)
                            }
                        }
                    }
                    .dsCard(padding: DS.Space.m)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.comingUp")
            }
        }
        .sheet(item: $selected) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
        .sheet(isPresented: $showAll) {
            EarningsListSheet(events: calendar.upcoming, assetFor: asset(for:))
        }
    }

    private func asset(for symbol: String) -> Asset {
        tracked.first { $0.symbol.uppercased() == symbol }
            ?? Asset(symbol: symbol, name: symbol, price: 0, change: 0, changePercent: 0, volume: 0, kind: .stock, exchange: "")
    }
}

struct EarningsRow: View {
    let event: EarningsEvent
    let asset: Asset
    var onTap: () -> Void
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: { Haptics.tap(); onTap() }) {
            AdaptiveQuoteRow {
                HStack(spacing: DS.Space.m) {
                    TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name.isEmpty ? event.symbol : asset.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            } numbers: { stacked in
                let date = Text(event.dateText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                let countdown = Text(event.countdownText())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(event.countdownText() == "Today" ? DS.accent : theme.secondaryText)
                    .lineLimit(1)
                if stacked {
                    HStack(spacing: DS.Space.s) { date; countdown; Spacer(minLength: 0) }
                } else {
                    VStack(alignment: .trailing, spacing: 2) { date; countdown }
                }
            }
            .padding(.vertical, DS.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(asset.name) reports earnings \(event.dateText), \(event.timingText), \(event.countdownText())")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("earnings.row.\(event.symbol)")
    }

    private var subtitle: String {
        [event.shortTimingText, event.epsEstimate.map { "est. EPS \(marketData.formatPrice($0))" } ?? "Earnings"]
            .joined(separator: " · ")
    }
}

struct EarningsListSheet: View {
    let events: [EarningsEvent]
    let assetFor: (String) -> Asset
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var selected: Asset?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(events) { event in
                        EarningsRow(event: event, asset: assetFor(event.symbol)) { selected = assetFor(event.symbol) }
                    }
                } footer: {
                    Text("Dates are Wall Street's (US Eastern) and can move. US listings only — ASX reporting dates aren't available on the free data plan.")
                }
            }
            .navigationTitle("Upcoming earnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected) { asset in
                AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
            }
        }
    }
}

// MARK: - Stock page: next report + reminder

struct DetailNextEarningsCard: View {
    let event: EarningsEvent
    let name: String
    @ObservedObject private var calendar = EarningsCalendar.shared
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next report")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    Text("\(event.dateText) · \(event.shortTimingText.lowercased())")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text([event.countdownText(), event.quarterText,
                          event.epsEstimate.map { "est. EPS \(marketData.formatPrice($0))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                let isSet = calendar.hasReminder(event)
                Button {
                    Task {
                        let ok = await calendar.toggleReminder(event, name: name)
                        Haptics.select()
                        note = ok ? nil : "Turn on notifications in Settings to get reminders."
                    }
                } label: {
                    Label(isSet ? "Reminder set" : "Remind me", systemImage: isSet ? "bell.fill" : "bell")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, DS.Space.m)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(isSet ? DS.accent.opacity(0.15) : theme.subtleFill))
                        .foregroundStyle(isSet ? DS.accent : theme.primaryText)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier("detail.earnings.remind")
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(theme.warningColor)
            }
        }
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.nextEarnings")
    }
}
