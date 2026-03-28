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
    let targetPrice: Double
    let condition: AlertCondition
    let isActive: Bool
    let createdAt: Date

    init(id: UUID = UUID(), symbol: String, assetName: String, targetPrice: Double,
         condition: AlertCondition, isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.symbol = symbol
        self.assetName = assetName
        self.targetPrice = targetPrice
        self.condition = condition
        self.isActive = isActive
        self.createdAt = createdAt
    }

    func shouldTrigger(currentPrice: Double) -> Bool {
        guard isActive else { return false }
        switch condition {
        case .above: return currentPrice >= targetPrice
        case .below: return currentPrice <= targetPrice
        }
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

    var color: Color {
        switch self {
        case .above: return .green
        case .below: return .red
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

    private let alertsKey = "price_alerts"

    init() {
        loadAlerts()
        requestNotificationPermission()
    }

    func addAlert(_ alert: PriceAlert) {
        alerts.append(alert)
        saveAlerts()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
    }

    func removeAlert(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        saveAlerts()
        if SyncManager.shared.isSignedIn {
            Task { await SyncManager.shared.softDeleteAlert(id: alert.id) }
        }
    }

    func toggleAlert(_ alert: PriceAlert) {
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = PriceAlert(
                id: alert.id,
                symbol: alert.symbol,
                assetName: alert.assetName,
                targetPrice: alert.targetPrice,
                condition: alert.condition,
                isActive: !alert.isActive,
                createdAt: alert.createdAt
            )
            saveAlerts()
            if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
        }
    }

    /// Called by SyncManager after a pull. Replaces local alerts and persists.
    func applyRemoteAlerts(_ remoteAlerts: [PriceAlert]) {
        alerts = remoteAlerts
        saveAlerts()
    }

    func checkAlerts(for assets: [Asset]) {
        for asset in assets {
            let triggered = alerts.filter { $0.symbol == asset.symbol && $0.shouldTrigger(currentPrice: asset.price) }
            for alert in triggered {
                sendNotification(for: alert, currentPrice: asset.price)
                removeAlert(alert)
            }
        }
    }

    private func sendNotification(for alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Price Alert: \(alert.symbol)")
        content.body = String(localized: "\(alert.assetName) is now $\(String(format: "%.2f", currentPrice)) (\(alert.condition.rawValue) $\(String(format: "%.2f", alert.targetPrice)))")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLogger.general.error("Failed to schedule alert: \(error)") }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { AppLogger.general.error("Notification permission error: \(error)") }
        }
    }

    private func saveAlerts() {
        DataPersistenceManager.shared.savePriceAlerts(alerts)
        syncAlertsToWidgetData()
    }

    private func loadAlerts() { alerts = DataPersistenceManager.shared.loadPriceAlerts() }

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

// MARK: - Add Price Alert Sheet (Redesigned)

struct AddPriceAlertSheet: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    let symbol: String
    let assetName: String
    let currentPrice: Double
    let changePercent: Double

    // Convenience init from Asset
    init(asset: Asset) {
        self.symbol = asset.symbol
        self.assetName = asset.name
        self.currentPrice = asset.price
        self.changePercent = asset.changePercent
    }

    // Init from DetailedStock
    init(stock: DetailedStock) {
        self.symbol = stock.symbol
        self.assetName = stock.name
        self.currentPrice = stock.currentPrice
        self.changePercent = stock.dayChangePercent
    }

    @State private var selectedCondition: AlertCondition = .above
    @State private var targetPriceText: String = ""
    @FocusState private var priceFocused: Bool

    private var alertLimit: Int? { subscriptionManager.currentTier.maxPriceAlerts }
    private var alertCount: Int { alertManager.alerts.count }
    private var canAddMore: Bool { subscriptionManager.canAddPriceAlert(currentCount: alertCount) }

    private var targetPrice: Double? { Double(targetPriceText) }
    private var isValid: Bool { targetPrice != nil && targetPrice! > 0 && canAddMore }

    private var priceIsPositive: Bool { changePercent >= 0 }

    private var quickTargets: [(label: String, price: Double)] {
        [
            ("Current", currentPrice),
            ("+5%",  currentPrice * 1.05),
            ("+10%", currentPrice * 1.10),
            ("-5%",  currentPrice * 0.95),
            ("-10%", currentPrice * 0.90),
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                (colorScheme == .dark ? Color(UIColor.systemGroupedBackground) : Color(red: 0.980, green: 0.973, blue: 0.961)).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {

                        // ── Header card ──────────────────────────────
                        headerCard
                            .padding(.horizontal)
                            .padding(.top, 20)

                        // ── Condition selector ───────────────────────
                        conditionSelector
                            .padding(.horizontal)
                            .padding(.top, 24)

                        // ── Price input ──────────────────────────────
                        priceInputCard
                            .padding(.horizontal)
                            .padding(.top, 16)

                        // ── Quick targets ────────────────────────────
                        quickTargetsRow
                            .padding(.top, 16)

                        // ── Notification preview ─────────────────────
                        notificationPreviewCard
                            .padding(.top, 24)

                        // ── Quota note (free tier) ───────────────────
                        if let limit = alertLimit {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                Text("\(alertCount) of \(limit) alerts used")
                                    .font(.caption)
                            }
                            .foregroundColor(alertCount >= limit ? .red : .secondary)
                            .padding(.top, 12)
                        }

                        // ── Set Alert button ─────────────────────────
                        setAlertButton
                            .padding(.horizontal)
                            .padding(.top, 28)
                            .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("New Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    priceFocused = true
                }
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.8), .blue.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                Text(String(symbol.prefix(2)))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(symbol)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.primary)
                Text(assetName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(currentPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.title3.weight(.bold))
                    .foregroundColor(.primary)
                HStack(spacing: 3) {
                    Image(systemName: priceIsPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))
                    Text(String(format: "%+.2f%%", changePercent))
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(priceIsPositive ? .green : .red)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Condition Selector

    private var conditionSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alert when price goes")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                ForEach(AlertCondition.allCases, id: \.self) { condition in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            selectedCondition = condition
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: condition.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(condition.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            selectedCondition == condition
                                ? condition.color.opacity(0.15)
                                : Color(UIColor.secondarySystemGroupedBackground)
                        )
                        .foregroundColor(
                            selectedCondition == condition ? condition.color : .secondary
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    selectedCondition == condition ? condition.color.opacity(0.5) : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                        .cornerRadius(14)
                    }
                }
            }
        }
    }

    // MARK: - Price Input

    private var priceInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Target Price")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            HStack(alignment: .center, spacing: 10) {
                Text("$")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.secondary)

                TextField("0.00", text: $targetPriceText)
                    .focused($priceFocused)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.primary)

                if !targetPriceText.isEmpty {
                    Button {
                        targetPriceText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        priceFocused ? selectedCondition.color.opacity(0.4) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .animation(.easeInOut(duration: 0.2), value: priceFocused)
        }
    }

    // MARK: - Quick Targets

    private var quickTargetsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Set")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Spacer().frame(width: 8)
                    ForEach(quickTargets, id: \.label) { item in
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                targetPriceText = String(format: "%.2f", item.price)
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            VStack(spacing: 2) {
                                Text(item.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.primary)
                                Text(item.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    Spacer().frame(width: 8)
                }
            }
        }
    }

    // MARK: - Notification Preview

    private var notificationTitle: String {
        "Price Alert: \(symbol)"
    }

    private var notificationBody: String {
        if let price = targetPrice, price > 0 {
            let priceStr = marketData.formatPrice(price)
            return "\(assetName) is now \(priceStr) (\(selectedCondition.rawValue) \(priceStr))"
        }
        return "You'll be notified when \(assetName) hits your target."
    }

    private var notificationPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notification Preview", systemImage: "bell")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 12) {
                // App icon
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.9), .blue.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Stock Tracker")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("now")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Text(notificationTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(notificationBody)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut(duration: 0.15), value: notificationBody)
                }
            }
            .padding(12)
            .background(
                Color(UIColor.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Set Alert Button

    private var setAlertButton: some View {
        Button {
            guard let price = targetPrice else { return }
            let alert = PriceAlert(
                symbol: symbol,
                assetName: assetName,
                targetPrice: price,
                condition: selectedCondition
            )
            alertManager.addAlert(alert)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Set Price Alert")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                isValid
                    ? LinearGradient(
                        colors: [selectedCondition.color, selectedCondition.color.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
                    : LinearGradient(
                        colors: [Color.secondary.opacity(0.3), Color.secondary.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
            )
            .foregroundColor(isValid ? .white : .secondary)
            .cornerRadius(16)
        }
        .disabled(!isValid)
        .animation(.easeInOut(duration: 0.2), value: isValid)
    }
}

// MARK: - Price Alerts List View (Redesigned)

struct PriceAlertsView: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss

    private var activeCount: Int { alertManager.alerts.filter { $0.isActive }.count }
    private var pausedCount: Int { alertManager.alerts.count - activeCount }

    var body: some View {
        NavigationStack {
            ZStack {
                (colorScheme == .dark ? Color(UIColor.systemGroupedBackground) : Color(red: 0.980, green: 0.973, blue: 0.961)).ignoresSafeArea()

                if alertManager.alerts.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        summaryBar
                        alertsList
                    }
                }
            }
            .navigationTitle("Price Alerts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: 10) {
            summaryPill(
                value: activeCount,
                label: "Active",
                icon: "bell.fill",
                color: .green
            )
            summaryPill(
                value: pausedCount,
                label: "Paused",
                icon: "bell.slash.fill",
                color: .secondary
            )
            summaryPill(
                value: alertManager.alerts.count,
                label: "Total",
                icon: "list.bullet",
                color: .blue
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func summaryPill(value: Int, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.2), Color.pink.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)
                    .blur(radius: 10)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom)
                    )
            }

            VStack(spacing: 6) {
                Text("No Price Alerts")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                Text("Open any stock and tap the bell icon\nto set your first alert.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    // MARK: - Alerts List

    private var alertsList: some View {
        List {
            ForEach(alertManager.alerts) { alert in
                AlertCard(alert: alert)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .onDelete { indexSet in
                indexSet.forEach { alertManager.removeAlert(alertManager.alerts[$0]) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Alert Card (Redesigned)

struct AlertCard: View {
    let alert: PriceAlert
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var marketData: MarketData

    private var currentPrice: Double? {
        marketData.watchlist.first(where: { $0.symbol == alert.symbol })?.price
        ?? marketData.portfolio.first(where: { $0.asset.symbol == alert.symbol })?.asset.price
    }

    // 0.0 – 1.0: how far price has moved toward the target
    private var progress: Double {
        guard let price = currentPrice, price > 0, alert.targetPrice > 0 else { return 0 }
        switch alert.condition {
        case .above: return min(price / alert.targetPrice, 1.0)
        case .below: return min(alert.targetPrice / price, 1.0)
        }
    }

    private var gapText: String? {
        guard let price = currentPrice, price > 0 else { return nil }
        let pct = ((alert.targetPrice - price) / price) * 100
        return String(format: "%+.1f%%", pct)
    }

    private var isTriggered: Bool {
        guard let price = currentPrice else { return false }
        return alert.shouldTrigger(currentPrice: price)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Main row ───────────────────────────────────
            HStack(spacing: 12) {
                conditionBadge

                // Symbol + condition + current price
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(alert.symbol)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(alert.isActive ? .primary : .secondary)
                        if isTriggered {
                            Text("TRIGGERED")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    Text("\(alert.condition.rawValue) \(alert.targetPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(alert.isActive ? alert.condition.color : .secondary)
                    if let price = currentPrice {
                        Text("Now \(price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Toggle + gap badge
                VStack(alignment: .trailing, spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { alert.isActive },
                        set: { _ in
                            alertManager.toggleAlert(alert)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.glass(tint: alert.condition.color))

                    if let gap = gapText, !isTriggered {
                        Text(gap)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(alert.condition.color.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(alert.condition.color.opacity(0.1), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, (currentPrice != nil && !isTriggered && alert.isActive) ? 10 : 14)

            // ── Progress bar (live price only, not triggered) ──
            if let price = currentPrice, !isTriggered, alert.isActive {
                progressSection(currentPrice: price)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            alert.isActive ? alert.condition.color.opacity(0.22) : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .opacity(alert.isActive ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: alert.isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.symbol) alert: \(alert.condition.rawValue) \(alert.targetPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)), \(alert.isActive ? "active" : "inactive")")
    }

    // MARK: - Condition Badge

    private var conditionBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(alert.condition.color.opacity(alert.isActive ? 0.15 : 0.07))
                .frame(width: 46, height: 46)
            Image(systemName: alert.condition.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(alert.isActive ? alert.condition.color : .secondary)
        }
    }

    // MARK: - Progress Section

    private func progressSection(currentPrice: Double) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [alert.condition.color.opacity(0.5), alert.condition.color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, geo.size.width * progress), height: 5)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 5)

            HStack {
                Text(currentPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%% of the way", progress * 100))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(alert.condition.color.opacity(0.75))
                Spacer()
                Text(alert.targetPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// Keep legacy AlertRow for any existing callers
typealias AlertRow = AlertCard
