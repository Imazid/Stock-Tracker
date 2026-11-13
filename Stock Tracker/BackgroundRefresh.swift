//
//  BackgroundRefresh.swift
//  Stock Tracker
//
//  Best-effort price-alert checks while the app is closed. iOS decides when
//  (and whether) to run app-refresh tasks, so alerts are "checked when prices
//  update — in the app, and in the background when iOS allows".
//

import Foundation
import BackgroundTasks
import OSLog

@MainActor
final class BackgroundRefresh {
    static let shared = BackgroundRefresh()
    /// Must match BGTaskSchedulerPermittedIdentifiers in Stock-Tracker-Info.plist.
    nonisolated static let taskID = "Cubeplay.Stock-Tracker.refresh"

    weak var marketData: MarketData?

    /// Asks iOS for a refresh no sooner than 15 minutes from now.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.general.info("Background refresh not scheduled: \(error.localizedDescription)")
        }
    }

    func run() async {
        schedule()   // keep the chain going
        await marketData?.refreshForAlertCheck()
        // Best effort: let due agents look at the market and waiting paper orders trade.
        await TradingStore.shared.backgroundTick()
    }
}
