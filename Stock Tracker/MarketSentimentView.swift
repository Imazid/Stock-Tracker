//
//  MarketSentimentView.swift
//  Stock Tracker
//
//  Displays a horizontal sentiment bar and market status line.
//  Sentiment data is supplied by MarketData; session is derived locally
//  from the user's preferred market (@AppStorage), mirroring MarketStatusView.
//

import SwiftUI
import UIKit
import Combine

// MARK: - MarketSentiment

enum MarketSentiment: Int, CaseIterable, Equatable {
    case veryBearish = 0
    case bearish     = 1
    case neutral     = 2
    case bullish     = 3
    case veryBullish = 4

    var displayName: String {
        switch self {
        case .veryBearish: return "Extreme Fear"
        case .bearish:     return "Bearish Sentiment"
        case .neutral:     return "Neutral Sentiment"
        case .bullish:     return "Bullish Sentiment"
        case .veryBullish: return "Extreme Greed"
        }
    }

    var tintColor: Color {
        switch self {
        case .veryBearish: return Color(UIColor.systemRed)
        case .bearish:     return Color(red: 0.85, green: 0.22, blue: 0.22)
        case .neutral:     return Color(UIColor.systemGray2)
        case .bullish:     return Color(red: 0.18, green: 0.70, blue: 0.36)
        case .veryBullish: return Color(UIColor.systemGreen)
        }
    }

    /// The two segment indices (0-based, out of 10) that are active for this sentiment.
    var activeRange: ClosedRange<Int> {
        let base = rawValue * 2
        return base...(base + 1)
    }
}

// MARK: - MarketSentimentView

struct MarketSentimentView: View {

    let sentiment: MarketSentiment
    let lastUpdated: Date

    @AppStorage("preferredMarket") private var preferredMarket: String = "US"
    @State private var session: MarketSession = .closed
    @Environment(\.colorScheme) private var colorScheme

    private let sessionTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let segmentCount = 10

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            sentimentLabel
            sentimentBar
            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { refreshSession() }
        .onReceive(sessionTimer) { _ in refreshSession() }
        .onChange(of: preferredMarket) { _, _ in refreshSession() }
    }

    // MARK: - Sentiment Label

    private var sentimentLabel: some View {
        Text(sentiment.displayName)
            .font(.headline.weight(.semibold))
            .foregroundColor(sentiment.tintColor)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.easeInOut, value: sentiment)
    }

    // MARK: - Sentiment Bar

    private var sentimentBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(segmentFill(index: index))
                    .frame(height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: sentiment)
    }

    private func segmentFill(index: Int) -> Color {
        let isActive = sentiment.activeRange.contains(index)
        let base: Color
        switch index {
        case 0, 1: base = Color(.systemRed)
        case 2, 3: base = Color(red: 0.85, green: 0.25, blue: 0.25)
        case 4, 5: base = Color(UIColor.systemGray3)
        case 6, 7: base = Color(red: 0.22, green: 0.72, blue: 0.40)
        default:   base = Color(.systemGreen)
        }
        return isActive ? base : base.opacity(0.18)
    }

    // MARK: - Status Line

    private var statusLine: some View {
        HStack(spacing: 6) {
            if session == .open {
                PulsingMarketDot(session: session)
                    .transition(.scale.combined(with: .opacity))
            }

            Text(formattedStatusText)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Spacer()
        }
        .animation(.easeInOut(duration: 0.3), value: session)
    }

    private var formattedStatusText: String {
        let tzId   = preferredMarket == "AU" ? "Australia/Sydney" : "America/New_York"
        let abbrev = preferredMarket == "AU" ? "AEST" : "EST"
        let tz     = TimeZone(identifier: tzId) ?? .current

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.timeZone  = tz
        df.locale    = .current
        let dateStr = df.string(from: lastUpdated)

        switch session {
        case .open:      return "Markets Open • \(dateStr) \(abbrev)"
        case .premarket: return "Pre-Market • \(dateStr) \(abbrev)"
        case .closed:    return "Markets Closed • \(dateStr) \(abbrev)"
        }
    }

    // MARK: - Session Refresh
    // Mirrors MarketStatusView logic; duplicated here to avoid coupling to that view.

    private func refreshSession() {
        if preferredMarket == "AU" {
            session = Self.computeSession(
                tz: "Australia/Sydney",
                openH: 10, openM: 0,
                closeH: 16, closeM: 0,
                preH: 7,   preM: 0
            )
        } else {
            session = Self.computeSession(
                tz: "America/New_York",
                openH: 9,  openM: 30,
                closeH: 16, closeM: 0,
                preH: 4,   preM: 0
            )
        }
    }

    private static func computeSession(
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
        guard weekday >= 2, weekday <= 6 else { return .closed }

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

// MARK: - PulsingMarketDot

struct PulsingMarketDot: View {
    let session: MarketSession
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if session == .open {
                Circle()
                    .fill(session.color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isPulsing ? 1.6 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.8)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
            }
            Circle()
                .fill(session.color)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            if session == .open { isPulsing = true }
        }
        .onChange(of: session) { _, newSession in
            isPulsing = newSession == .open
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        MarketSentimentView(sentiment: .bearish,     lastUpdated: Date())
        MarketSentimentView(sentiment: .neutral,     lastUpdated: Date())
        MarketSentimentView(sentiment: .veryBullish, lastUpdated: Date())
    }
    .padding()
}
