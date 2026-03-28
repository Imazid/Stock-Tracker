//
//  AnalysisTabView.swift
//  Stock Tracker
//
//  Analysis tab: full analyst consensus, 52W price target range,
//  ratings table, and AI summary placeholder.
//

import SwiftUI
import OSLog

struct AnalysisTabView: View {
    let stock: DetailedStock
    let insight: StockInsight?
    let isLoading: Bool
    @EnvironmentObject var insightService: AIInsightService

    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @Environment(\.colorScheme) private var colorScheme

    // AI Summary
    @State private var aiSummary: String = ""
    @State private var aiSummaryLoading = false
    @State private var aiSummaryError: String?
    @State private var aiSummaryLoaded = false
    private let aiService = AIAgentService()

    var body: some View {
        LazyVStack(spacing: 16) {
            if isLoading && insight == nil {
                SectionCard(title: "Analyst Consensus", icon: "chart.bar.doc.horizontal") {
                    InsightLoadingRow(count: 4)
                }
                SectionCard(title: "Price Target", icon: "scope") {
                    InsightLoadingRow(count: 2)
                }
            } else {
                fullConsensusCard

                // Earnings bar chart
                let earningsEntries = insight?.earnings ?? []
                EarningsHistoryCard(stock: stock, earningsEntries: earningsEntries)

                priceTargetCard
                ratingsTableCard
                aiSummaryCard
            }
        }
        .padding(16)
    }

    // MARK: - Full Consensus Card

    @ViewBuilder
    private var fullConsensusCard: some View {
        SectionCard(title: "Analyst Consensus", icon: "chart.bar.doc.horizontal") {
            if let c = insight?.consensus {
                VStack(spacing: 16) {
                    // 5-segment bar
                    fullConsensusBar(c)

                    // Count labels beneath bar
                    HStack {
                        VStack {
                            Text("\(c.strongBuy)").font(.title3.weight(.bold)).foregroundColor(.green)
                            Text("Strong Buy").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text("\(c.buy)").font(.title3.weight(.bold)).foregroundColor(Color(UIColor.systemGreen).opacity(0.75))
                            Text("Buy").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text("\(c.hold)").font(.title3.weight(.bold)).foregroundColor(.secondary)
                            Text("Hold").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text("\(c.sell)").font(.title3.weight(.bold)).foregroundColor(Color(UIColor.systemRed).opacity(0.75))
                            Text("Sell").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack {
                            Text("\(c.strongSell)").font(.title3.weight(.bold)).foregroundColor(.red)
                            Text("Strong Sell").font(.caption2).foregroundColor(.secondary)
                        }
                    }

                    Divider().opacity(0.4)

                    // Consensus label
                    let ratio = Double(c.bullishCount) / Double(max(1, c.totalRatings))
                    HStack {
                        Text("Overall")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(ratio > 0.6 ? "Buy" : ratio > 0.4 ? "Hold" : "Sell")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(ratio > 0.6 ? .green : ratio > 0.4 ? .secondary : .red)
                    }
                }
            } else {
                Text("Consensus data unavailable").font(.subheadline).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fullConsensusBar(_ c: AnalystConsensus) -> some View {
        let total = max(1, c.totalRatings)
        GeometryReader { geo in
            HStack(spacing: 2) {
                let segments: [(Double, Color)] = [
                    (Double(c.strongBuy)  / Double(total), Color(UIColor.systemGreen)),
                    (Double(c.buy)        / Double(total), Color(UIColor.systemGreen).opacity(0.55)),
                    (Double(c.hold)       / Double(total), Color(UIColor.systemGray3)),
                    (Double(c.sell)       / Double(total), Color(UIColor.systemRed).opacity(0.55)),
                    (Double(c.strongSell) / Double(total), Color(UIColor.systemRed)),
                ]
                ForEach(segments.indices, id: \.self) { i in
                    if segments[i].0 > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(segments[i].1)
                            .frame(width: geo.size.width * segments[i].0)
                    }
                }
            }
        }
        .frame(height: 10)
    }

    // MARK: - Price Target Card

    @ViewBuilder
    private var priceTargetCard: some View {
        SectionCard(title: "Price Target", icon: "scope") {
            if let c = insight?.consensus, c.targetMean > 0 {
                priceTargetBar(c)
            } else {
                Text("Target data unavailable").font(.subheadline).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func priceTargetBar(_ c: AnalystConsensus) -> some View {
        let low     = c.targetLow
        let high    = c.targetHigh
        let mean    = c.targetMean
        let current = stock.currentPrice
        let range   = max(high - low, 1)

        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background gradient bar
                    LinearGradient(
                        colors: [Color(UIColor.systemRed).opacity(0.4),
                                 Color(UIColor.systemGray3).opacity(0.3),
                                 Color(UIColor.systemGreen).opacity(0.4)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 8)
                    .cornerRadius(4)

                    // Mean marker
                    let meanX = CGFloat((mean - low) / range) * geo.size.width
                    VStack(spacing: 0) {
                        Triangle()
                            .fill(Color.primary)
                            .frame(width: 8, height: 6)
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 1, height: 10)
                    }
                    .offset(x: max(0, min(meanX - 4, geo.size.width - 8)), y: -8)

                    // Current price marker
                    let currX = CGFloat((current - low) / range) * geo.size.width
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(currX - 6, geo.size.width - 12)), y: -2)
                }
            }
            .frame(height: 24)
            .padding(.top, 12)

            // Labels
            HStack {
                VStack(alignment: .leading) {
                    Text("Low").font(.caption2).foregroundColor(.secondary)
                    Text(String(format: "$%.0f", low)).font(.caption.weight(.semibold))
                }
                Spacer()
                VStack {
                    Text("Mean").font(.caption2).foregroundColor(.secondary)
                    Text(String(format: "$%.0f", mean)).font(.caption.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("High").font(.caption2).foregroundColor(.secondary)
                    Text(String(format: "$%.0f", high)).font(.caption.weight(.semibold))
                }
            }

            // Current price note
            let upside = (mean - current) / current * 100
            HStack {
                Circle().fill(Color.primary).frame(width: 8, height: 8)
                Text("Current: \(String(format: "$%.2f", current))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "Upside: %+.1f%%", upside))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(upside >= 0 ? .green : .red)
            }
        }
    }

    // MARK: - Ratings Table

    @ViewBuilder
    private var ratingsTableCard: some View {
        SectionCard(title: "Analyst Ratings", icon: "list.bullet.clipboard") {
            if let ratings = insight?.ratings, !ratings.isEmpty {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Firm").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Rating").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .frame(width: 80, alignment: .center)
                        Text("Target").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .frame(width: 55, alignment: .trailing)
                        Text("Date").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.bottom, 8)
                    Divider().opacity(0.4)

                    ForEach(ratings) { rating in
                        AnalystRatingRow(rating: rating, currentPrice: stock.currentPrice)
                        if rating.id != ratings.last?.id {
                            Divider().opacity(0.25)
                        }
                    }
                }
            } else {
                Text("No ratings available").font(.subheadline).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AI Summary

    @ViewBuilder
    private var aiSummaryCard: some View {
        let theme = Theme(colorScheme: colorScheme)
        SectionCard(title: "AI Analysis", icon: "sparkles") {
            if aiSummaryLoading {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.purple)
                    Text("Analyzing \(stock.symbol)...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else if let error = aiSummaryError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await loadAISummary() }
                    } label: {
                        Text("Try Again")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.8))
                            .cornerRadius(8)
                    }
                }
            } else if !aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(aiSummary)
                        .font(.subheadline)
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .lineSpacing(4)

                    HStack {
                        Text("Powered by ChatGPT. Not financial advice.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            Task { await loadAISummary() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Button {
                    Task { await loadAISummary() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.subheadline)
                        Text("Generate AI Analysis")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
            }
        }
    }

    private func loadAISummary() async {
        aiSummaryLoading = true
        aiSummaryError = nil

        let priceStr = String(format: "%.2f", stock.currentPrice)
        let changeStr = String(format: "%.2f", stock.dayChangePercent)

        var statsContext = ""
        if let pe = stock.peRatio, pe > 0 { statsContext += " P/E: \(String(format: "%.1f", pe))." }
        if stock.marketCap > 0 { statsContext += " Market Cap: \(formatLargeNumber(stock.marketCap))." }
        if let dy = stock.dividendYield, dy > 0 { statsContext += " Dividend Yield: \(String(format: "%.2f%%", dy * 100))." }
        if let beta = stock.beta, beta > 0 { statsContext += " Beta: \(String(format: "%.2f", beta))." }
        if stock.week52High > 0 { statsContext += " 52W High: \(String(format: "%.2f", stock.week52High))." }
        if stock.week52Low > 0 { statsContext += " 52W Low: \(String(format: "%.2f", stock.week52Low))." }
        if let sector = stock.sector, !sector.isEmpty { statsContext += " Sector: \(sector)." }
        if let margin = stock.profitMargin { statsContext += " Net Margin: \(String(format: "%.1f%%", margin * 100))." }

        // Include analyst consensus if available
        if let c = insight?.consensus {
            statsContext += " Analyst consensus: \(c.strongBuy + c.buy) Buy, \(c.hold) Hold, \(c.sell + c.strongSell) Sell."
            if c.targetMean > 0 { statsContext += " Mean target: $\(String(format: "%.2f", c.targetMean))." }
        }

        let prompt = """
        Give a concise 3-4 sentence investment summary for \(stock.name) (\(stock.symbol)). \
        Current price: $\(priceStr). Daily change: \(changeStr)%.\(statsContext) \
        Cover: current sentiment, key metrics outlook, and one thing investors should watch. \
        Be balanced and factual. Do not give buy/sell recommendations.
        """

        let systemMsg = ChatMessage(
            text: "You are a concise financial analyst. Provide brief, factual investment summaries. Never recommend buying or selling. Always note this is not financial advice.",
            isUser: false,
            role: "system"
        )
        let userMsg = ChatMessage(text: prompt, isUser: true)

        do {
            let response = try await aiService.sendMessage(messages: [systemMsg, userMsg])
            aiSummary = response
            aiSummaryLoaded = true
        } catch {
            aiSummaryError = "Unable to generate analysis. Check your API key or try again."
        }

        aiSummaryLoading = false
    }

    private func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000_000 { return String(format: "$%.2fT", value / 1_000_000_000_000) }
        if value >= 1_000_000_000     { return String(format: "$%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000         { return String(format: "$%.2fM", value / 1_000_000) }
        return String(format: "$%.2f", value)
    }
}

// MARK: - Analyst Rating Row

private struct AnalystRatingRow: View {
    let rating: AnalystRating
    let currentPrice: Double

    private var ratingColor: Color {
        switch rating.ratingColor {
        case .positive: return .green
        case .negative: return .red
        case .neutral:  return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rating.firm)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(rating.analyst)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(rating.rating)
                .font(.caption.weight(.semibold))
                .foregroundColor(ratingColor)
                .frame(width: 80, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(rating.priceTarget > 0 ? String(format: "$%.0f", rating.priceTarget) : "—")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(rating.priceTarget > 0 ? .primary : .secondary)
                .frame(width: 55, alignment: .trailing)

            Text(rating.date.prefix(6).description)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Triangle Shape (for price target marker)

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
