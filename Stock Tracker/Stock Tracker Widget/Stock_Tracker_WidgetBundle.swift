//
//  Stock_Tracker_WidgetBundle.swift
//  Stock Tracker Widget
//

import WidgetKit
import SwiftUI

@main
struct StockTrackerWidgets: WidgetBundle {
    var body: some Widget {
        PortfolioSummaryWidget()          // ← Your real portfolio widget
        // TopMoversWidget()              // ← Add more later if you want
        // Stock_Tracker_Widget()         // ← Remove or comment out the example
    }
}
