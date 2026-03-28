//
//  EarningsTabView.swift
//  Stock Tracker
//
//  Earnings tab: quarterly earnings cards with EPS/Revenue est vs actual,
//  beat/miss indicators, and 1-day price move.
//

import SwiftUI

struct EarningsTabView: View {
    let stock: DetailedStock?
    let insight: StockInsight?
    let isLoading: Bool

    @EnvironmentObject var insightService: AIInsightService
    @State private var earningsPreviewText: String?
    @State private var earningsPreviewLoading = false

    var body: some View {
        LazyVStack(spacing: 16) {
            // AI Earnings Preview (Pro/Black only)
            if SubscriptionManager.shared.currentTier != .free,
               let stock = stock, let earnings = insight?.earnings, !earnings.isEmpty {
                earningsPreviewCard(stock: stock, earnings: earnings)
            }

            if isLoading && insight == nil {
                ForEach(0..<4, id: \.self) { _ in
                    loadingCard
                }
            } else if let earnings = insight?.earnings, !earnings.isEmpty {
                ForEach(earnings) { entry in
                    EarningsCard(entry: entry)
                }
                transcriptRow
            } else {
                emptyState
            }
        }
        .padding(16)
    }

    // MARK: - Loading Placeholder

    private var loadingCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(width: 80, height: 16)
                    RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(width: 120, height: 12)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).frame(width: 60, height: 28)
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 40)
                RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 40)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .redacted(reason: .placeholder)
    }

    // MARK: - Transcript Placeholder

    private var transcriptRow: some View {
        HStack {
            Label("View Earnings Transcript", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundColor(.orange)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .foregroundColor(.secondary)
    }

    // MARK: - AI Earnings Preview

    private func earningsPreviewCard(stock: DetailedStock, earnings: [EarningsEntry]) -> some View {
        let tier = SubscriptionManager.shared.currentTier
        let isLocked = tier == .free
        let cacheKey = "earnings_preview_\(stock.symbol)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? earningsPreviewText
        return AIInsightCard(
            title: "Earnings Outlook",
            icon: "chart.bar.doc.horizontal",
            insightText: cachedText,
            isLoading: earningsPreviewLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadEarningsPreview(stock: stock, earnings: earnings) },
            onRegenerate: { await loadEarningsPreview(stock: stock, earnings: earnings, force: true) }
        )
    }

    private func loadEarningsPreview(stock: DetailedStock, earnings: [EarningsEntry], force: Bool = false) async {
        earningsPreviewLoading = true
        defer { earningsPreviewLoading = false }

        let tier = SubscriptionManager.shared.currentTier
        let cacheKey = "earnings_preview_\(stock.symbol)"

        let last4 = earnings.prefix(4)
        let earningsSummary = last4.map { e in
            let epsBeat = e.epsBeat ? "beat" : "miss"
            return "\(e.quarter) EPS \(epsBeat) ($\(String(format: "%.2f", e.epsActual)) vs $\(String(format: "%.2f", e.epsEst)))"
        }.joined(separator: "; ")

        var context = ""
        if let pe = stock.peRatio, pe > 0 { context += " P/E: \(String(format: "%.1f", pe))." }
        if stock.currentPrice > 0 { context += " Price: $\(String(format: "%.2f", stock.currentPrice))." }

        let systemPrompt = "You are an earnings analyst. Summarize the earnings outlook in 2-3 sentences. Include the beat/miss trend and what to watch."
        let userPrompt = """
        \(stock.name) (\(stock.symbol)) earnings history: \(earningsSummary).\(context) \
        Summarize the trend and what investors should watch for next quarter.
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .earningsPreview,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .earningsPreview,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { earningsPreviewText = text }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Earnings data unavailable")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Earnings Card

struct EarningsCard: View {
    let entry: EarningsEntry

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.quarter)
                        .font(.headline.weight(.semibold))
                    Text(entry.date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                PriceMoveBadge(move: entry.priceMove1D)
            }

            Divider().opacity(0.4)

            // Revenue & EPS rows
            HStack(spacing: 12) {
                if entry.hasRevenueData {
                    EarningsMetricCard(
                        label: "Revenue",
                        estimated: "\(entry.revenueEst.compactFormatted())B",
                        actual: "\(entry.revenueActual.compactFormatted())B",
                        beat: entry.revenueBeat
                    )
                }
                EarningsMetricCard(
                    label: "EPS",
                    estimated: String(format: "$%.2f", entry.epsEst),
                    actual: String(format: "$%.2f", entry.epsActual),
                    beat: entry.epsBeat
                )
            }

            // Highlights
            earningsHighlights
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    @ViewBuilder
    private var earningsHighlights: some View {
        let surprisePct = abs((entry.epsActual - entry.epsEst) / max(abs(entry.epsEst), 0.01)) * 100

        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Text("Highlights")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            var highlights: [String] = []
            let _ = {
                if entry.hasRevenueData {
                    let overallBeat = entry.revenueBeat && entry.epsBeat
                    highlights.append(overallBeat
                        ? "Beat both EPS and revenue estimates"
                        : "Missed one or more analyst estimates")
                } else {
                    highlights.append(entry.epsBeat
                        ? "Beat EPS estimate"
                        : "Missed EPS estimate")
                }
                highlights.append(String(format: "EPS surprise: %+.1f%%", entry.epsBeat ? surprisePct : -surprisePct))
                if entry.priceMove1D != 0 {
                    highlights.append("Stock moved \(String(format: "%+.1f%%", entry.priceMove1D)) the following session")
                }
            }()

            ForEach(highlights, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    Text(point)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Earnings Metric Card

private struct EarningsMetricCard: View {
    let label: String
    let estimated: String
    let actual: String
    let beat: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: beat ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 10))
                    Text(beat ? "Beat" : "Miss")
                        .font(.caption2.weight(.bold))
                }
                .foregroundColor(beat ? .green : .red)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Est")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(estimated)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(actual)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(beat ? .green : .red)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}
