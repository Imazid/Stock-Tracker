//
//  PriceAlert.swift
//  Stock Tracker
//

import Foundation
import OSLog
import UserNotifications
import Combine
import SwiftUI
import WidgetKit

// MARK: - Price Alert Model

struct PriceAlert: Identifiable, Codable {
    let id: UUID
    let symbol: String
    let assetName: String
    /// USD, like every stored price.
    let targetPrice: Double
    let condition: AlertCondition
    /// The person's on/off switch.
    var isActive: Bool
    let createdAt: Date
    /// "Every time": notifies on each crossing instead of once.
    var repeats: Bool
    /// A repeating alert that just fired waits (unarmed) until the price moves
    /// back past `rearmPrice`, so a price hovering on the line can't notify on every tick.
    var isArmed: Bool
    var lastTriggeredAt: Date?
    /// What to quote when the symbol isn't on the watchlist or in the portfolio (an alert
    /// set from Search or a stock page). nil on alerts saved before this was stored.
    var kind: AssetKind?
    var exchange: String?

    /// How far back across the target the price must go before a repeating alert re-arms.
    static let rearmGap = 0.005

    init(id: UUID = UUID(), symbol: String, assetName: String, targetPrice: Double,
         condition: AlertCondition, isActive: Bool = true, createdAt: Date = Date(),
         repeats: Bool = false, isArmed: Bool = true, lastTriggeredAt: Date? = nil,
         kind: AssetKind? = nil, exchange: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.assetName = assetName
        self.targetPrice = targetPrice
        self.condition = condition
        self.isActive = isActive
        self.createdAt = createdAt
        self.repeats = repeats
        self.isArmed = isArmed
        self.lastTriggeredAt = lastTriggeredAt
        self.kind = kind
        self.exchange = exchange
    }

    enum CodingKeys: String, CodingKey {
        case id, symbol, assetName, targetPrice, condition, isActive, createdAt, repeats, isArmed, lastTriggeredAt,
             kind, exchange
    }

    /// Alerts saved before repeating alerts existed have no `repeats`/`isArmed` keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        symbol = try c.decode(String.self, forKey: .symbol)
        assetName = try c.decode(String.self, forKey: .assetName)
        targetPrice = try c.decode(Double.self, forKey: .targetPrice)
        condition = try c.decode(AlertCondition.self, forKey: .condition)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false
        isArmed = try c.decodeIfPresent(Bool.self, forKey: .isArmed) ?? true
        lastTriggeredAt = try c.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind)
        exchange = try c.decodeIfPresent(String.self, forKey: .exchange)
    }

    /// An unpriced asset to quote for this alert. Older alerts don't know their listing:
    /// a coin the app can price is crypto, anything else is treated as a US stock.
    var quoteAsset: Asset {
        let isCoin = SymbolSearchModel.supportedCoins.contains { $0.symbol == symbol }
        return Asset(symbol: symbol, name: assetName, price: 0, change: 0, changePercent: 0, volume: 0,
                     kind: kind ?? (isCoin ? .crypto : .stock), exchange: exchange ?? "")
    }

    /// Where a fired repeating alert re-arms: 0.5% back on the near side of the target.
    var rearmPrice: Double {
        condition == .above ? targetPrice * (1 - Self.rearmGap) : targetPrice * (1 + Self.rearmGap)
    }

    enum Outcome: Equatable { case nothing, fire, rearm }

    /// The single rule for what a price does to this alert. In-app refreshes and
    /// background refreshes both reach it through `PriceAlertManager.checkAlerts`.
    func evaluate(price: Double) -> Outcome {
        guard isActive, price > 0, targetPrice > 0 else { return .nothing }
        if isArmed {
            let reached = condition == .above ? price >= targetPrice : price <= targetPrice
            return reached ? .fire : .nothing
        }
        let movedBack = condition == .above ? price <= rearmPrice : price >= rearmPrice
        return movedBack ? .rearm : .nothing
    }
}

enum AlertCondition: String, Codable, CaseIterable {
    case above = "Above"
    case below = "Below"

    var symbol: String {
        switch self {
        case .above: return "↑"
        case .below: return "↓"
        }
    }

    var icon: String {
        switch self {
        case .above: return "arrow.up.circle.fill"
        case .below: return "arrow.down.circle.fill"
        }
    }
}

// MARK: - Alert Manager

@MainActor
class PriceAlertManager: ObservableObject {
    @Published var alerts: [PriceAlert] = []

    private(set) var owner: UUID?

    init() {
        // Permission is asked for in context (onboarding, or the first alert a user
        // sets) — never on cold launch, before the user has seen anything.
        loadAlerts()
    }

    func useAccount(_ newOwner: UUID?) {
        guard owner != newOwner else { return }
        owner = newOwner
        loadAlerts()
        syncAlertsToWidgetData()
    }

    func addAlert(_ alert: PriceAlert) {
        requestNotificationPermission()
        alerts.append(alert)
        saveAlerts()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    func removeAlert(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        saveAlerts()
        if let owner {
            Task { await SyncManager.shared.softDeleteAlert(id: alert.id, owner: owner) }
        }
    }

    func toggleAlert(_ alert: PriceAlert) {
        update(alert.id) { $0.isActive.toggle() }
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    /// Switches an alert between "Once" and "Every time".
    func setRepeats(_ repeats: Bool, for alert: PriceAlert) {
        update(alert.id) {
            $0.repeats = repeats
            $0.isArmed = true
        }
    }

    private func update(_ id: UUID, _ change: (inout PriceAlert) -> Void) {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }
        change(&alerts[index])
        saveAlerts()
    }

    /// Called by SyncManager after a pull. Replaces local alerts and persists.
    /// A new device takes the server's repeat/armed state; a device that already has the
    /// alert keeps its own (it may have fired here since the last push).
    func applyRemoteAlerts(_ remoteAlerts: [PriceAlert]) {
        let local = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        alerts = remoteAlerts.map { remote in
            guard let mine = local[remote.id] else { return remote }
            var merged = remote
            merged.repeats = mine.repeats
            merged.isArmed = mine.isArmed
            merged.lastTriggeredAt = mine.lastTriggeredAt
            return merged
        }
        saveAlerts()
    }

    /// Runs every alert against fresh prices (in-app refresh and `BackgroundRefresh`).
    /// "Once" alerts notify and are removed; "Every time" alerts notify, then wait
    /// until the price has moved back across the target before they can fire again.
    func checkAlerts(for assets: [Asset]) {
        var seen = Set<String>()
        for asset in assets where seen.insert(asset.symbol).inserted {
            let price = Self.testPrice(for: asset.symbol) ?? asset.price
            guard price > 0 else { continue }
            for alert in alerts where alert.symbol == asset.symbol {
                switch alert.evaluate(price: price) {
                case .nothing:
                    continue
                case .fire:
                    sendNotification(for: alert, currentPrice: price)
                    if alert.repeats {
                        update(alert.id) {
                            $0.isArmed = false
                            $0.lastTriggeredAt = Date()
                        }
                    } else {
                        removeAlert(alert)
                    }
                case .rearm:
                    update(alert.id) { $0.isArmed = true }
                }
            }
        }
    }

    private func sendNotification(for alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        let now = Self.displayPrice(currentPrice)
        let target = Self.displayPrice(alert.targetPrice)
        let verb = alert.condition == .above ? "rose above" : "fell below"
        content.title = String(localized: "\(alert.symbol) \(verb) \(target)")
        content.body = alert.repeats
            ? String(localized: "\(alert.assetName) is now \(now). We'll tell you again the next time it crosses \(target).")
            : String(localized: "\(alert.assetName) is now \(now). This alert is now off — set a new one from the bell on your watchlist.")
        content.userInfo = ["symbol": alert.symbol]   // a tap opens the stock's page
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLogger.general.error("Failed to schedule alert: \(error)") }
        }
    }

    #if DEBUG
    /// UI tests only: `-UITestAlertPrices "AAPL=100000"` makes alert checks see that
    /// USD price, so the fire → re-arm path can be driven without waiting for the market.
    private static let testPrices: [String: Double] = {
        guard let raw = UserDefaults.standard.string(forKey: "UITestAlertPrices") else { return [:] }
        var prices: [String: Double] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let value = Double(parts[1]) { prices[String(parts[0])] = value }
        }
        return prices
    }()
    private static func testPrice(for symbol: String) -> Double? { testPrices[symbol] }
    #else
    private static func testPrice(for symbol: String) -> Double? { nil }
    #endif

    /// Formats a stored USD price in the person's chosen currency ("A$342.00").
    static func displayPrice(_ usd: Double) -> String {
        let code = DataPersistenceManager.shared.loadPreferredCurrency()
        let rate = code == "USD" ? 1.0 : (FXRates.shared.rate(for: code) ?? 1.0)
        return usd.formattedPrice(in: code, rates: [code: rate])
    }

    /// Only prompts while the status is undecided; a no-op once the user has answered.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error { AppLogger.general.error("Notification permission error: \(error)") }
            }
        }
    }

    private func saveAlerts() {
        DataPersistenceManager.shared.savePriceAlerts(alerts, owner: owner)
        syncAlertsToWidgetData()
    }

    private func loadAlerts() { alerts = DataPersistenceManager.shared.loadPriceAlerts(owner: owner) }

    /// Writes current active alerts into App Group UserDefaults so the PriceAlert
    /// widget reads fresh data immediately, then tells WidgetKit to reload.
    private func syncAlertsToWidgetData() {
        guard let shared = UserDefaults(suiteName: Constants.Widget.appGroup) else { return }

        // Pull the latest prices already cached in the App Group by MarketData.updateWidgetData()
        var priceMap: [String: Double] = [:]
        if let wlData = shared.data(forKey: "watchlistData"),
           let wlJson = try? JSONSerialization.jsonObject(with: wlData) as? [String: Any],
           let items = wlJson["items"] as? [[String: Any]] {
            for item in items {
                if let sym = item["symbol"] as? String, let price = item["price"] as? Double {
                    priceMap[sym] = price
                }
            }
        }
        if let pfData = shared.data(forKey: "portfolioData"),
           let pfJson = try? JSONSerialization.jsonObject(with: pfData) as? [String: Any],
           let holdings = pfJson["holdings"] as? [[String: Any]] {
            for h in holdings {
                if let sym = h["symbol"] as? String, let price = h["price"] as? Double {
                    priceMap[sym] = price
                }
            }
        }

        let alertDicts: [[String: Any]] = alerts.filter { $0.isActive }.map { alert in
            [
                "id": alert.id.uuidString,
                "symbol": alert.symbol,
                "targetPrice": alert.targetPrice,
                "currentPrice": priceMap[alert.symbol] ?? 0,
                "condition": alert.condition.rawValue.lowercased()
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["alerts": alertDicts]) {
            shared.set(data, forKey: "alertsData")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Notification permission

/// Live notification permission, so alert screens can say when alerts can't reach you.
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    var isDenied: Bool { status == .denied }

    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks only while undecided; returns whether notifications can be delivered.
    @discardableResult
    func requestIfNeeded() async -> Bool {
        await refresh()
        if status == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
        }
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// "Notifications are off — Turn on".
struct NotificationsOffBanner: View {
    var message: LocalizedStringKey = "Price alerts can't reach you until you turn them on."
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "bell.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.warningColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Button {
                Haptics.tap()
                NotificationPermission.shared.openSettings()
            } label: {
                Text("Turn on")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notifications.turnOn")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.off")
    }
}

// MARK: - Price input (locale-aware)

enum AlertPriceInput {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        if let n = f.number(from: trimmed) { return n.doubleValue }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        let digits = value >= 1 ? 2 : (value >= 0.01 ? 4 : 6)
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }
}

/// Shared alert copy — alerts are checked when prices update, not by a server.
enum AlertCopy {
    static let howItWorks: LocalizedStringKey =
        "We check your alerts whenever prices update — in the app, and in the background when iOS allows."
}

// MARK: - Create alert

/// Set a price alert: one big price field in the person's currency (stored in USD),
/// direction worked out from the target, and ±% shortcuts — after Plum / Crypto.com on Mobbin.
struct AddPriceAlertSheet: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var permission = NotificationPermission.shared

    let symbol: String
    let assetName: String
    /// USD, like every stored price.
    let currentPrice: Double
    let changePercent: Double
    let kind: AssetKind
    let exchange: String

    init(asset: Asset) {
        symbol = asset.symbol
        assetName = asset.name
        currentPrice = asset.price
        changePercent = asset.changePercent
        kind = asset.kind
        exchange = asset.exchange
    }

    init(stock: DetailedStock) {
        symbol = stock.symbol
        assetName = stock.name
        currentPrice = stock.currentPrice
        changePercent = stock.dayChangePercent
        kind = stock.exchange == "Crypto" ? .crypto : .stock
        exchange = stock.exchange == "ASX" ? "ASX" : ""
    }

    @State private var text = ""
    @State private var repeats = false
    @State private var showPaywall = false
    @FocusState private var focused: Bool

    private var currentDisplay: Double { marketData.display(fromUSD: currentPrice) }
    private var target: Double? { AlertPriceInput.parse(text).flatMap { $0 > 0 ? $0 : nil } }

    private var direction: AlertCondition? {
        guard let target, currentDisplay > 0 else { return nil }
        let gap = abs(target - currentDisplay) / currentDisplay
        guard gap >= 0.0005 else { return nil }
        return target > currentDisplay ? .above : .below
    }

    private var percentAway: Double? {
        guard let target, currentDisplay > 0 else { return nil }
        return (target / currentDisplay - 1) * 100
    }

    private var alertLimit: Int? { subscriptionManager.currentTier.maxPriceAlerts }
    private var canAddMore: Bool { subscriptionManager.canAddPriceAlert(currentCount: alertManager.alerts.count) }
    private var isValid: Bool { direction != nil && canAddMore && currentPrice > 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    header
                    priceField
                    quickTargets
                    if permission.isDenied {
                        NotificationsOffBanner()
                            .dsCard()
                    }
                    footnotes
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.l)
                .padding(.bottom, DS.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .dsScreenBackground()
            .safeAreaInset(edge: .bottom) { createButton }
            .navigationTitle("Price alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("alert.cancel")
                }
            }
            .task {
                await permission.refresh()
                try? await Task.sleep(for: .milliseconds(350))
                focused = true
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(requiredTier: .pro, featureName: "More price alerts")
                    .environmentObject(subscriptionManager)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: symbol, kind: kind, exchange: exchange, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Text(assetName)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if currentPrice > 0 {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(marketData.formatPrice(currentPrice))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                    ChangePill(percent: changePercent, compact: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now \(marketData.formatPrice(currentPrice))")
            }
        }
        .dsCard()
    }

    private var priceField: some View {
        VStack(spacing: DS.Space.s) {
            Text("Notify me when \(symbol) reaches")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marketData.displayCurrencySymbol)
                    .font(DS.money(26, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                TextField(currentPrice > 0 ? AlertPriceInput.format(currentDisplay) : "0", text: $text)
                    .font(DS.money(46, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .fixedSize()
                    .accessibilityLabel("Target price in \(marketData.preferredCurrency)")
                    .accessibilityIdentifier("alert.price")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.s)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            relationText
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("alert.relation")
        }
    }

    @ViewBuilder
    private var relationText: some View {
        if currentPrice <= 0 {
            Text("There's no live price for \(symbol) right now, so alerts can't be set.")
                .foregroundStyle(theme.secondaryText)
        } else if let pct = percentAway, let direction {
            Text(String(format: "%.1f%% %@ the current price", abs(pct), direction == .above ? "above" : "below"))
                .foregroundStyle(direction == .above ? theme.positiveColor : theme.negativeColor)
        } else if target != nil {
            Text("That's the current price — pick a price above or below it.")
                .foregroundStyle(theme.secondaryText)
        } else {
            Text("Now \(marketData.formatPrice(currentPrice))")
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var quickTargets: some View {
        HStack(spacing: DS.Space.s) {
            ForEach([-10, -5, 5, 10], id: \.self) { pct in
                Button {
                    Haptics.select()
                    text = AlertPriceInput.format(currentDisplay * (1 + Double(pct) / 100))
                } label: {
                    Text(pct > 0 ? "+\(pct)%" : "−\(abs(pct))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(theme.subtleFill))
                        .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(currentPrice <= 0)
                .accessibilityLabel(pct > 0 ? "\(pct) percent above now" : "\(abs(pct)) percent below now")
                .accessibilityIdentifier("alert.quick.\(pct)")
            }
        }
    }

    /// Once / Every time — TradingView's "Only Once | Every Time" and Binance's
    /// frequency choice on Mobbin. Lives in the bottom bar, right above Create, so it
    /// stays in view while the number pad is up.
    private var repeatPicker: some View {
        Picker("Notify me", selection: $repeats) {
            Text("Once").tag(false)
            Text("Every time").tag(true)
        }
        .pickerStyle(.segmented)
        .onChange(of: repeats) { Haptics.select() }
        .accessibilityIdentifier("alert.repeat")
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let target, let direction {
                Label {
                    Text("We'll notify you \(repeats ? "every time" : "when") \(symbol) \(direction == .above ? "rises to" : "falls to") \(formatDisplay(target)).")
                } icon: {
                    Image(systemName: "bell.badge")
                }
                .font(.subheadline)
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("alert.preview")
            }
            Text(repeats
                 ? "Repeats: each time \(symbol) crosses your price. After it fires, it waits for a 0.5% move back before it can fire again."
                 : "Once: after it fires, the alert turns off.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("alert.repeat.explainer")
            Text(AlertCopy.howItWorks)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            if let limit = alertLimit {
                Text("\(alertManager.alerts.count) of \(limit) alerts on your plan")
                    .font(.footnote)
                    .foregroundStyle(canAddMore ? theme.secondaryText : theme.warningColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var createButton: some View {
        VStack(spacing: DS.Space.m) {
            if canAddMore {
                repeatPicker
                Button("Create alert") { create() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(!isValid)
                    .accessibilityIdentifier("alert.create")
            } else {
                Button("Upgrade for more alerts") { showPaywall = true }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("alert.upgrade")
            }
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, DS.Space.m)
        .background {
            // Opaque, so scrolled content doesn't show through behind the controls.
            theme.background
                .overlay(alignment: .top) { Divider().opacity(0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func formatDisplay(_ value: Double) -> String {
        marketData.formatPrice(marketData.usd(fromDisplay: value))
    }

    private func create() {
        guard let target, let direction, isValid else { return }
        let alert = PriceAlert(
            symbol: symbol,
            assetName: assetName,
            targetPrice: marketData.usd(fromDisplay: target),
            condition: direction,
            repeats: repeats,
            kind: kind,
            exchange: exchange
        )
        alertManager.addAlert(alert)
        Haptics.success()
        AccessibilityNotification.Announcement("Alert set for \(symbol) at \(formatDisplay(target))").post()
        dismiss()
    }
}

// MARK: - Alerts list

struct PriceAlertsView: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var permission = NotificationPermission.shared
    @State private var showNewAlert = false

    private var alerts: [PriceAlert] {
        alertManager.alerts.sorted { ($0.isActive ? 0 : 1, $0.symbol) < ($1.isActive ? 0 : 1, $1.symbol) }
    }

    var body: some View {
        NavigationStack {
            List {
                if permission.isDenied && !alertManager.alerts.isEmpty {
                    Section { NotificationsOffBanner() }
                        .listRowBackground(theme.subtleFill)
                }
                if alertManager.alerts.isEmpty {
                    Section {
                        EmptyStateCard(
                            systemImage: "bell",
                            title: "No price alerts yet",
                            message: "Pick a stock and the price you care about. We'll let you know when it gets there.",
                            primaryTitle: "Create an alert",
                            primaryAction: { showNewAlert = true }
                        )
                        .accessibilityIdentifier("alerts.empty")
                    } footer: {
                        Text(AlertCopy.howItWorks)
                            .padding(.top, DS.Space.s)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    Section {
                        ForEach(alerts) { alert in
                            PriceAlertRow(alert: alert)
                                .listRowBackground(theme.subtleFill)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Haptics.tap()
                                        dsAnimate { alertManager.removeAlert(alert) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        alertManager.setRepeats(!alert.repeats, for: alert)
                                    } label: {
                                        alert.repeats
                                            ? Label("Notify once", systemImage: "1.circle")
                                            : Label("Notify every time", systemImage: "repeat")
                                    }
                                    Button(role: .destructive) {
                                        dsAnimate { alertManager.removeAlert(alert) }
                                    } label: {
                                        Label("Delete alert", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        let active = alertManager.alerts.filter(\.isActive).count
                        Text("\(active) active · \(alertManager.alerts.count - active) paused")
                            .textCase(nil)
                    } footer: {
                        Text(AlertCopy.howItWorks)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .navigationTitle("Price alerts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("alerts.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        showNewAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New alert")
                    .accessibilityIdentifier("alerts.new")
                }
            }
            .task { await permission.refresh() }
            .sheet(isPresented: $showNewAlert) {
                NewAlertFlow()
                    .environmentObject(alertManager)
                    .environmentObject(marketData)
                    .environmentObject(subscriptionManager)
            }
        }
    }
}

private struct PriceAlertRow: View {
    let alert: PriceAlert
    @EnvironmentObject private var alertManager: PriceAlertManager
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    private var asset: Asset? {
        let pool = marketData.watchlist + marketData.portfolio.map(\.asset) + marketData.alertOnlyAssets
            + marketData.stocks + marketData.crypto
        return pool.first { $0.symbol == alert.symbol && $0.price > 0 } ?? pool.first { $0.symbol == alert.symbol }
    }

    private var statusText: String {
        if !alert.isActive { return "Paused" }
        if alert.repeats && !alert.isArmed {
            let side = alert.condition == .above ? "below" : "above"
            let when = alert.lastTriggeredAt.map { " " + Self.when($0) } ?? ""
            return "Triggered\(when) · re-arms \(side) \(marketData.formatPrice(alert.rearmPrice))"
        }
        guard let price = asset?.price, price > 0 else { return "No live price right now" }
        let pct = abs(alert.targetPrice - price) / price * 100
        return "Now \(marketData.formatPrice(price)) · \(String(format: "%.1f%%", pct)) to go"
    }

    /// "2:14 pm" today, "16 Oct" before that.
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month())
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: alert.symbol, kind: asset?.kind ?? .stock, exchange: asset?.exchange ?? "", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(alert.symbol) \(alert.condition == .above ? "rises to" : "falls to") \(marketData.formatPrice(alert.targetPrice))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(alert.isActive ? theme.primaryText : theme.secondaryText)
                    if alert.repeats {
                        Image(systemName: "repeat")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityLabel("every time")
                    }
                }
                Text(statusText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(alert.repeats && !alert.isArmed && alert.isActive ? theme.warningColor : theme.secondaryText)
                    .accessibilityIdentifier("alerts.status.\(alert.symbol)")
            }
            Spacer(minLength: DS.Space.s)
            Toggle("Alert on", isOn: Binding(
                get: { alert.isActive },
                set: { _ in
                    Haptics.select()
                    alertManager.toggleAlert(alert)
                }
            ))
            .labelsHidden()
            .tint(DS.accent)
            .accessibilityLabel("\(alert.symbol) alert")
            .accessibilityIdentifier("alerts.toggle.\(alert.symbol)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alerts.row.\(alert.symbol)")
    }
}

/// "+" → pick one of your symbols → set the price.
private struct NewAlertFlow: View {
    @State private var picked: Asset?

    var body: some View {
        if let picked {
            AddPriceAlertSheet(asset: picked)
        } else {
            AlertSymbolPicker { picked = $0 }
        }
    }
}

private struct AlertSymbolPicker: View {
    let onPick: (Asset) -> Void
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var holdings: [Asset] {
        let watch = Set(marketData.watchlist.map(\.symbol))
        var seen = Set<String>()
        return marketData.portfolio.map(\.asset).filter { !watch.contains($0.symbol) && seen.insert($0.symbol).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                if marketData.watchlist.isEmpty && holdings.isEmpty {
                    Section {
                        EmptyStateCard(
                            systemImage: "star",
                            title: "Nothing to watch yet",
                            message: "Add stocks or crypto to your watchlist, then set alerts on them here."
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if !marketData.watchlist.isEmpty {
                    Section("Watchlist") { ForEach(marketData.watchlist) { pickRow($0) } }
                }
                if !holdings.isEmpty {
                    Section("Holdings") { ForEach(holdings) { pickRow($0) } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .navigationTitle("New alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pickRow(_ asset: Asset) -> some View {
        Button {
            Haptics.tap()
            onPick(asset)
        } label: {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(asset.name)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if asset.price > 0 {
                    Text(marketData.formatPrice(asset.price))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.subtleFill)
        .accessibilityIdentifier("alerts.pick.\(asset.symbol)")
    }
}
