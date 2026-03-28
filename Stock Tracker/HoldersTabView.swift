//
//  HoldersTabView.swift
//  Stock Tracker
//
//  Holders tab: institutional ownership list.
//

import SwiftUI

struct HoldersTabView: View {
    let insight: StockInsight?
    let isLoading: Bool

    var body: some View {
        LazyVStack(spacing: 16) {
            if isLoading && insight == nil {
                SectionCard(title: "Top Institutional Holders", icon: "building.columns.fill") {
                    InsightLoadingRow(count: 5)
                }
            } else if let holders = insight?.holders, !holders.isEmpty {
                holdersCard(holders: holders)
            } else {
                emptyState
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func holdersCard(holders: [InstitutionalHolder]) -> some View {
        SectionCard(title: "Top Institutional Holders", icon: "building.columns.fill") {
            VStack(spacing: 0) {
                // Column headers
                HStack {
                    Text("Institution")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Shares")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text("Value")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text("Chg%")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.bottom, 8)

                Divider().opacity(0.4)

                ForEach(holders) { holder in
                    HolderRow(holder: holder)
                    if holder.id != holders.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.3.fill")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Holders data unavailable")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Holder Row

private struct HolderRow: View {
    let holder: InstitutionalHolder

    var body: some View {
        HStack(spacing: 0) {
            Text(holder.name)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%.1fM", holder.shares))
                .font(.subheadline.monospacedDigit())
                .frame(width: 60, alignment: .trailing)

            Text(String(format: "$%.2fB", holder.value))
                .font(.subheadline.monospacedDigit())
                .frame(width: 60, alignment: .trailing)

            changeChip
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var changeChip: some View {
        let positive = holder.changePercent >= 0
        Text(String(format: "%+.1f%%", holder.changePercent))
            .font(.caption.weight(.semibold))
            .foregroundColor(positive ? .green : .red)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((positive ? Color.green : Color.red).opacity(0.12))
            .cornerRadius(5)
    }
}
