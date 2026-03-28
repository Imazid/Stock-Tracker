//
//  RefreshStatusBadge.swift
//  Stock Tracker
//
//  Shows "Updating…" during a live refresh, then "Updated Xm ago" at rest.
//  Ticking via a 30-second timer so the "ago" string stays fresh.
//

import SwiftUI
import Combine

struct RefreshStatusBadge: View {
    @EnvironmentObject var marketData: MarketData
    @State private var displayText: String = ""
    // Ticks every 30 s to keep the relative-time string accurate
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            if marketData.isRefreshingQuotes {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.secondary)
                Text("Updating…")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(displayText)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(10)
        .onAppear { updateText() }
        .onChange(of: marketData.lastQuoteRefreshDate) { _, _ in updateText() }
        .onChange(of: marketData.isRefreshingQuotes) { _, _ in updateText() }
        .onReceive(ticker) { _ in updateText() }
    }

    private func updateText() {
        guard !marketData.isRefreshingQuotes else { return }
        guard let date = marketData.lastQuoteRefreshDate else {
            displayText = "Not yet updated"
            return
        }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            displayText = "Updated just now"
        } else if seconds < 3600 {
            let m = seconds / 60
            displayText = "Updated \(m)m ago"
        } else {
            let h = seconds / 3600
            displayText = "Updated \(h)h ago"
        }
    }
}
