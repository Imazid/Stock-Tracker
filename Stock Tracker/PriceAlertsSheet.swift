//
//  PriceAlertsSheet.swift
//  Stock Tracker
//

import SwiftUI

struct PriceAlertsSheet: View {
    var body: some View {
        PriceAlertsView()
    }
}

#Preview {
    PriceAlertsSheet()
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
}
