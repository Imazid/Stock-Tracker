//
//  NotificationScheduler.swift
//  Stock Tracker
//
//  Manages all scheduled/smart notifications beyond simple price alerts:
//  daily portfolio summary, significant price movements, market open/close,
//  and earnings alerts.
//

import Foundation
import UserNotifications
import OSLog
import Combine

@MainActor
final class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()

    // MARK: - Preferences

    @Published var dailySummaryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dailySummaryEnabled, forKey: Keys.dailySummary)
            if !dailySummaryEnabled { cancelDailySummary() }
        }
    }
    @Published var dailySummaryHour: Int {
        didSet { UserDefaults.standard.set(dailySummaryHour, forKey: Keys.dailySummaryHour) }
    }
    @Published var dailySummaryMinute: Int {
        didSet { UserDefaults.standard.set(dailySummaryMinute, forKey: Keys.dailySummaryMinute) }
    }
    @Published var significantMovementEnabled: Bool {
        didSet { UserDefaults.standard.set(significantMovementEnabled, forKey: Keys.significantMovement) }
    }
    @Published var movementThreshold: Double {
        didSet { UserDefaults.standard.set(movementThreshold, forKey: Keys.movementThreshold) }
    }
    @Published var marketOpenCloseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(marketOpenCloseEnabled, forKey: Keys.marketOpenClose)
            if marketOpenCloseEnabled {
                scheduleMarketOpenClose()
            } else {
                cancelMarketOpenClose()
            }
        }
    }
    @Published var earningsAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(earningsAlertEnabled, forKey: Keys.earningsAlert) }
    }

    // MARK: - Keys

    private enum Keys {
        static let dailySummary      = "notif_dailySummary"
        static let dailySummaryHour  = "notif_dailySummaryHour"
        static let dailySummaryMinute = "notif_dailySummaryMinute"
        static let significantMovement = "notif_significantMovement"
        static let movementThreshold = "notif_movementThreshold"
        static let marketOpenClose   = "notif_marketOpenClose"
        static let earningsAlert     = "notif_earningsAlert"
    }

    // MARK: - Notification Identifiers

    private enum Identifiers {
        static let dailySummary = "daily_summary"
        static let marketOpen   = "market_open"
        static let marketClose  = "market_close"
        static let movement     = "movement_"
        static let earnings     = "earnings_"
    }

    // Track which symbols already triggered a movement notification today
    private var movementNotifiedToday: Set<String> = []
    private var lastMovementResetDate: Date = .distantPast

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        dailySummaryEnabled      = d.bool(forKey: Keys.dailySummary)
        dailySummaryHour         = d.object(forKey: Keys.dailySummaryHour) as? Int ?? 16
        dailySummaryMinute       = d.object(forKey: Keys.dailySummaryMinute) as? Int ?? 0
        significantMovementEnabled = d.bool(forKey: Keys.significantMovement)
        movementThreshold        = d.object(forKey: Keys.movementThreshold) as? Double ?? 5.0
        marketOpenCloseEnabled   = d.bool(forKey: Keys.marketOpenClose)
        earningsAlertEnabled     = d.bool(forKey: Keys.earningsAlert)

        // Schedule market open/close if enabled on init
        if marketOpenCloseEnabled { scheduleMarketOpenClose() }
    }

    // MARK: - 1. Daily Portfolio Summary

    func scheduleDailySummary(portfolioValue: Double, dailyPL: Double, dailyPLPercent: Double) {
        guard dailySummaryEnabled else { return }

        // Cancel existing so we don't duplicate
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Identifiers.dailySummary]
        )

        let content = UNMutableNotificationContent()
        content.title = "Daily Portfolio Summary"
        let plSign = dailyPLPercent >= 0 ? "+" : ""
        content.body = String(
            format: "Portfolio: $%.2f | Today: %@%.2f%%",
            portfolioValue, plSign, dailyPLPercent
        )
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = dailySummaryHour
        dateComponents.minute = dailySummaryMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: Identifiers.dailySummary,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLogger.general.error("Daily summary schedule error: \(error)") }
        }
    }

    private func cancelDailySummary() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Identifiers.dailySummary]
        )
    }

    // MARK: - 2. Significant Price Movement

    func checkSignificantMovements(for assets: [Asset]) {
        guard significantMovementEnabled else { return }

        // Reset the daily dedup set at midnight
        let today = Calendar.current.startOfDay(for: Date())
        if today != lastMovementResetDate {
            movementNotifiedToday.removeAll()
            lastMovementResetDate = today
        }

        for asset in assets {
            guard abs(asset.changePercent) >= movementThreshold else { continue }
            guard !movementNotifiedToday.contains(asset.symbol) else { continue }

            movementNotifiedToday.insert(asset.symbol)

            let direction = asset.changePercent > 0 ? "up" : "down"
            let content = UNMutableNotificationContent()
            content.title = "\(asset.symbol) Big Move"
            content.body = String(
                format: "%@ is %@ %.1f%% today ($%.2f)",
                asset.name, direction, abs(asset.changePercent), asset.price
            )
            content.userInfo = ["symbol": asset.symbol]
            content.sound = .default

            let identifier = "\(Identifiers.movement)\(asset.symbol)_\(Int(today.timeIntervalSince1970))"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { AppLogger.general.error("Movement notification error: \(error)") }
            }
        }
    }

    // MARK: - 3. Market Open / Close

    func scheduleMarketOpenClose() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifiers.marketOpen, Identifiers.marketClose]
        )

        guard marketOpenCloseEnabled else { return }

        // NYSE hours in Eastern Time
        let eastern = TimeZone(identifier: "America/New_York")!

        // Market Open — 9:30 AM ET, weekdays
        var openComponents = DateComponents()
        openComponents.hour = 9
        openComponents.minute = 30
        openComponents.timeZone = eastern

        let openContent = UNMutableNotificationContent()
        openContent.title = "Market Open"
        openContent.body = "US markets are now open for trading."
        openContent.sound = .default

        let openTrigger = UNCalendarNotificationTrigger(dateMatching: openComponents, repeats: true)
        let openReq = UNNotificationRequest(
            identifier: Identifiers.marketOpen, content: openContent, trigger: openTrigger
        )

        // Market Close — 4:00 PM ET, weekdays
        var closeComponents = DateComponents()
        closeComponents.hour = 16
        closeComponents.minute = 0
        closeComponents.timeZone = eastern

        let closeContent = UNMutableNotificationContent()
        closeContent.title = "Market Closed"
        closeContent.body = "US markets have closed. Check your daily performance."
        closeContent.sound = .default

        let closeTrigger = UNCalendarNotificationTrigger(dateMatching: closeComponents, repeats: true)
        let closeReq = UNNotificationRequest(
            identifier: Identifiers.marketClose, content: closeContent, trigger: closeTrigger
        )

        center.add(openReq) { error in
            if let error { AppLogger.general.error("Market open schedule error: \(error)") }
        }
        center.add(closeReq) { error in
            if let error { AppLogger.general.error("Market close schedule error: \(error)") }
        }
    }

    private func cancelMarketOpenClose() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Identifiers.marketOpen, Identifiers.marketClose]
        )
    }

    // MARK: - 4. Earnings Alerts

    func checkEarningsAlerts(newsArticles: [NewsArticle], watchedSymbols: Set<String>) {
        guard earningsAlertEnabled else { return }

        let earningsKeywords = ["earnings", "quarterly results", "revenue report", "eps", "guidance"]

        for article in newsArticles {
            let titleLower = article.title.lowercased()
            let isEarnings = earningsKeywords.contains { titleLower.contains($0) }
            guard isEarnings else { continue }

            // Check if the article mentions any watched symbol
            for symbol in watchedSymbols {
                guard titleLower.contains(symbol.lowercased()) else { continue }

                let identifier = "\(Identifiers.earnings)\(symbol)_\(article.title.hashValue)"
                let content = UNMutableNotificationContent()
                content.title = "Earnings: \(symbol)"
                content.body = article.title
                content.userInfo = ["symbol": symbol]
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request) { error in
                    if let error { AppLogger.general.error("Earnings notification error: \(error)") }
                }
                break // One notification per symbol per article
            }
        }
    }
}
