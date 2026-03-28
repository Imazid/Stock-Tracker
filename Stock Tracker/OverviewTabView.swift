//
//  OverviewTabView.swift
//  Stock Tracker
//
//  Overview tab: key stats, company overview, analyst consensus preview,
//  and a compact earnings preview.
//

import SwiftUI
import OSLog

struct OverviewTabView: View {
    let stock: DetailedStock
    let insight: StockInsight?
    let isLoading: Bool

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVStack(spacing: 16) {
            // Reuse existing QuickStatsSection
            QuickStatsSection(stock: stock)

            // Company Overview (reused CompanyOverviewContent)
            if stock.companyDescription != nil || stock.sector != nil {
                CompanyOverviewContent(stock: stock)
            }

            // Analyst Consensus mini card
            analystCard

            // Earnings preview (latest 2)
            earningsPreviewCard
        }
        .padding(16)
    }

    // MARK: - Analyst Consensus Mini Card

    @ViewBuilder
    private var analystCard: some View {
        SectionCard(title: "Analyst Consensus", icon: "chart.bar.doc.horizontal") {
            if isLoading && insight == nil {
                InsightLoadingRow(count: 2)
            } else if let consensus = insight?.consensus {
                VStack(spacing: 12) {
                    // Rating bar
                    consensusBar(consensus)

                    // Labels
                    HStack {
                        Label("\(consensus.strongBuy + consensus.buy) Buy", systemImage: "arrow.up.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                        Spacer()
                        Label("\(consensus.hold) Hold", systemImage: "minus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Label("\(consensus.sell + consensus.strongSell) Sell", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.red)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text("Price Target")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "$%.2f", consensus.targetMean))
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: "(%+.1f%%)",
                            (consensus.targetMean - stock.currentPrice) / stock.currentPrice * 100))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(consensus.targetMean >= stock.currentPrice ? .green : .red)
                    }
                }
            } else {
                Text("Analyst data unavailable")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func consensusBar(_ c: AnalystConsensus) -> some View {
        let total = max(1, c.totalRatings)
        GeometryReader { geo in
            HStack(spacing: 2) {
                let segments: [(Double, Color)] = [
                    (Double(c.strongBuy) / Double(total),  Color(UIColor.systemGreen)),
                    (Double(c.buy)       / Double(total),  Color(UIColor.systemGreen).opacity(0.6)),
                    (Double(c.hold)      / Double(total),  Color(UIColor.systemGray3)),
                    (Double(c.sell)      / Double(total),  Color(UIColor.systemRed).opacity(0.6)),
                    (Double(c.strongSell) / Double(total), Color(UIColor.systemRed)),
                ]
                ForEach(segments.indices, id: \.self) { i in
                    if segments[i].0 > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segments[i].1)
                            .frame(width: geo.size.width * segments[i].0)
                    }
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: - Earnings Preview Card

    @ViewBuilder
    private var earningsPreviewCard: some View {
        SectionCard(title: "Recent Earnings", icon: "dollarsign.circle.fill") {
            if isLoading && insight == nil {
                InsightLoadingRow(count: 2)
            } else if let entries = insight?.earnings, !entries.isEmpty {
                VStack(spacing: 10) {
                    ForEach(entries.prefix(2)) { entry in
                        EarningsPreviewRow(entry: entry)
                        if entry.id != entries.prefix(2).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            } else {
                Text("Earnings data unavailable")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Earnings Preview Row

private struct EarningsPreviewRow: View {
    let entry: EarningsEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.quarter)
                    .font(.subheadline.weight(.semibold))
                Text(entry.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                BeatMissChip(label: "EPS", beat: entry.epsBeat,
                             actual: entry.epsActual, est: entry.epsEst, isEPS: true)
                BeatMissChip(label: "Rev", beat: entry.revenueBeat,
                             actual: entry.revenueActual, est: entry.revenueEst, isEPS: false)
            }
            PriceMoveBadge(move: entry.priceMove1D)
                .padding(.leading, 6)
        }
    }
}

// MARK: - Shared Sub-components

struct BeatMissChip: View {
    let label: String
    let beat: Bool
    let actual: Double
    let est: Double
    let isEPS: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(isEPS ? String(format: "$%.2f", actual) : "\(actual.compactFormatted())B")
                .font(.caption.weight(.semibold))
            Image(systemName: beat ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(beat ? .green : .red)
                .padding(3)
                .background((beat ? Color.green : Color.red).opacity(0.15))
                .clipShape(Circle())
        }
    }
}

struct PriceMoveBadge: View {
    let move: Double

    var body: some View {
        Text(String(format: "%+.1f%%", move))
            .font(.caption.weight(.semibold))
            .foregroundColor(move >= 0 ? .green : .red)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((move >= 0 ? Color.green : Color.red).opacity(0.12))
            .cornerRadius(6)
    }
}

struct InsightLoadingRow: View {
    let count: Int
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 14)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(width: 60, height: 14)
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}

// MARK: - Reusable Section Card

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}
