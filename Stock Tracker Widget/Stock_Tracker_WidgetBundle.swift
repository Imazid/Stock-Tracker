//
//  Stock_Tracker_WidgetBundle.swift
//  Stock Tracker Widget
//

import WidgetKit
import SwiftUI

@main
struct StockTrackerWidgets: WidgetBundle {
    var body: some Widget {
        // ── Portfolio ────────────────────────────────────────────────────
        PortfolioWidget()          // Home (S/M/L) + Lock Screen (circular/rectangular/inline)
        MiniChartWidget()          // Home — Medium sparkline chart
        TopPerformerWidget()       // Home — Medium best-holding card

        // ── Market ───────────────────────────────────────────────────────
        SentimentWidget()          // Lock Screen circular + Home Small
        MarketOverviewWidget()     // Home — Medium/Large index overview

        // ── Watchlist / Movers ───────────────────────────────────────────
        WatchlistWidget()          // Home — S/M/L watchlist movers
        SingleStockWidget()        // Home — S/M configurable per-stock
        TopMoversWidget()          // Home — M/L gainers & losers

        // ── Alerts ───────────────────────────────────────────────────────
        PriceAlertWidget()         // Home — S/M active alerts

        // ── News & Calendar ─────────────────────────────────────────────
        NewsWidget()               // Home — M/L + Lock Screen headlines
        EventCalendarWidget()      // Home — S/M + Lock Screen calendar
        OrderLauncherWidget()      // Home — S/M trade launcher

        // ── Premium (Pro / Black) ────────────────────────────────────────
        AssetAllocationWidget()    // Home — S/M pie chart (gated)
        RiskScoreWidget()          // Home — Small arc gauge (gated)
        WeeklyPerformanceWidget()  // Home — Medium bar chart (gated)

        // ── Live Activity ────────────────────────────────────────────────
        Stock_Tracker_WidgetLiveActivity()
    }
}
