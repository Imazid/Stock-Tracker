//
//  MarketStatusView.swift
//  Stock Tracker
//
//  Shows a single market status badge for the exchange chosen in Settings.
//  Times are computed in the exchange's local timezone.
//

import SwiftUI
import Combine

struct MarketStatusView: View {
    @AppStorage("preferredMarket") private var preferredMarket: String = "US"
    @State private var session: MarketSession = .closed
    @Environment(\.colorScheme) private var colorScheme

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        sessionBadge
            .onAppear { refresh() }
            .onReceive(ticker) { _ in refresh() }
            .onChange(of: preferredMarket) { _, _ in refresh() }
    }

    // MARK: - Badge

    private var sessionBadge: some View {
        let label = preferredMarket == "AU" ? "ASX" : "NYSE"

        return HStack(spacing: 5) {
            Circle()
                .fill(session.color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.primary)
            Text("·")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(session.label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(colorScheme == .dark ? Color(UIColor.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878))
        .cornerRadius(10)
    }

    // MARK: - Logic

    private func refresh() {
        if preferredMarket == "AU" {
            session = Self.session(
                tz: "Australia/Sydney",
                openH: 10, openM: 0,
                closeH: 16, closeM: 0,
                preH: 7, preM: 0
            )
        } else {
            session = Self.session(
                tz: "America/New_York",
                openH: 9,  openM: 30,
                closeH: 16, closeM: 0,
                preH: 4, preM: 0
            )
        }
    }

    private static func session(
        tz: String,
        openH: Int, openM: Int,
        closeH: Int, closeM: Int,
        preH: Int, preM: Int
    ) -> MarketSession {
        guard let timeZone = TimeZone(identifier: tz) else { return .closed }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let now = Date()

        let weekday = cal.component(.weekday, from: now)
        guard weekday >= 2 && weekday <= 6 else { return .closed }

        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let current = h * 60 + m
        let open  = openH  * 60 + openM
        let close = closeH * 60 + closeM
        let pre   = preH   * 60 + preM

        switch current {
        case open..<close: return .open
        case pre..<open:   return .premarket
        default:           return .closed
        }
    }
}

// MARK: - Session Model

enum MarketSession {
    case open, premarket, closed

    var color: Color {
        switch self {
        case .open:      return .green
        case .premarket: return .orange
        case .closed:    return Color(UIColor.systemGray3)
        }
    }

    var label: String {
        switch self {
        case .open:      return "Open"
        case .premarket: return "Pre-Market"
        case .closed:    return "Closed"
        }
    }
}
