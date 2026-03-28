//
//  LiveActivityManager.swift
//  Stock Tracker
//
//  Manages ActivityKit Live Activities for real-time stock price tracking
//  on the Lock Screen and Dynamic Island.
//
//  NOTE: StockLiveActivityAttributes is defined identically here (main app)
//  and in Stock_Tracker_WidgetLiveActivity.swift (widget extension).
//  Each target compiles its own copy — no symbol clash.
//

import Foundation
import Combine
import ActivityKit

// MARK: - Activity Attributes (main app copy)

struct StockLiveActivityAttributes: ActivityAttributes {
    let symbol: String
    let companyName: String

    struct ContentState: Codable, Hashable {
        var price: Double
        var change: Double
        var changePercent: Double
        var isMarketOpen: Bool
        var lastUpdated: Date

        var isPositive: Bool { changePercent >= 0 }
    }
}

// MARK: - Manager

@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    @Published var activeSymbols: Set<String> = []

    private init() {}

    // MARK: - Public API

    func isTracking(_ symbol: String) -> Bool {
        activeSymbols.contains(symbol.uppercased())
    }

    func startTracking(symbol: String, name: String, price: Double, change: Double, changePercent: Double) async {
        let sym = symbol.uppercased()
        guard !isTracking(sym) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attrs = StockLiveActivityAttributes(symbol: sym, companyName: name)
        let state = StockLiveActivityAttributes.ContentState(
            price: price,
            change: change,
            changePercent: changePercent,
            isMarketOpen: isMarketCurrentlyOpen(),
            lastUpdated: Date()
        )

        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
            _ = try Activity<StockLiveActivityAttributes>.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
            activeSymbols.insert(sym)
        } catch {
            // ActivityKit not available in simulator or entitlement missing — fail silently
        }
    }

    func stopTracking(_ symbol: String) async {
        let sym = symbol.uppercased()
        let activities = Activity<StockLiveActivityAttributes>.activities
        for activity in activities where activity.attributes.symbol == sym {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeSymbols.remove(sym)
    }

    func toggleTracking(symbol: String, name: String, price: Double, change: Double, changePercent: Double) async {
        if isTracking(symbol) {
            await stopTracking(symbol)
        } else {
            await startTracking(symbol: symbol, name: name, price: price, change: change, changePercent: changePercent)
        }
    }

    func updateAll(assets: [Asset]) async {
        guard !activeSymbols.isEmpty else { return }
        let activities = Activity<StockLiveActivityAttributes>.activities
        for activity in activities {
            let sym = activity.attributes.symbol
            guard let asset = assets.first(where: { $0.symbol.uppercased() == sym }) else { continue }
            let state = StockLiveActivityAttributes.ContentState(
                price: asset.price,
                change: asset.change,
                changePercent: asset.changePercent,
                isMarketOpen: isMarketCurrentlyOpen(),
                lastUpdated: Date()
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
            await activity.update(content)
        }
    }

    func stopAll() async {
        let activities = Activity<StockLiveActivityAttributes>.activities
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activeSymbols.removeAll()
    }

    // MARK: - Helpers

    private func isMarketCurrentlyOpen() -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        guard weekday >= 2, weekday <= 6 else { return false }
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let minutes = hour * 60 + minute
        return minutes >= 9 * 60 + 30 && minutes < 16 * 60
    }
}
