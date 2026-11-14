import SwiftUI

struct HoldingSyncReview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var market: MarketData
    @EnvironmentObject private var sync: SyncManager
    @State private var discard: PortfolioLedgerChange?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These changes were saved on this iPhone. The portfolio shows the latest synced holdings. Review your changes before entering them again.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sync.holdingConflicts, id: \.revision) { change in
                    Section(change.holding.asset.symbol) {
                        if let group = market.portfolioGroups.first(where: { $0.id == change.groupID }) {
                            LabeledContent("Portfolio", value: group.name)
                        }
                        if let latest = market.allPortfolioHoldings.first(where: { $0.id == change.holding.id }) {
                            LabeledContent("Synced units", value: units(latest.shares))
                            LabeledContent("Synced average cost (USD)", value: usd(latest.avgCost))
                        } else {
                            LabeledContent("Synced holding", value: "Unavailable")
                        }
                        if change.archivedAt != nil, change.closedAt == nil {
                            LabeledContent("Pending change", value: "Remove holding")
                        } else {
                            LabeledContent("Pending units", value: units(change.holding.shares))
                            LabeledContent("Pending average cost (USD)", value: usd(change.holding.avgCost))
                        }
                        ForEach(change.holding.transactions.filter { change.changed.contains($0.id) }) { trade in
                            tradeRow(trade.type.rawValue, trade: trade)
                        }
                        ForEach(change.deleted) { trade in
                            tradeRow("Remove \(trade.type.rawValue.lowercased())", trade: trade)
                        }
                        ShareLink(item: export(change)) { Label("Share pending changes", systemImage: "square.and.arrow.up") }
                        Button("Discard pending changes", role: .destructive) { discard = change }
                    }
                }
            }
            .navigationTitle("Holding sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Discard these pending changes?", isPresented: Binding(
                get: { discard != nil }, set: { if !$0 { discard = nil } }
            ), titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) {
                    if let discard { sync.discardHoldingConflict(discard, owner: market.portfolioOwner) }
                    discard = nil
                }
                Button("Cancel", role: .cancel) { discard = nil }
            } message: {
                Text("The synced holding will remain in the account.")
            }
        }
    }

    private func units(_ shares: Double) -> String {
        shares.formatted(.number.precision(.fractionLength(0...8)))
    }

    private func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2...8)))
    }

    private func tradeRow(_ title: String, trade: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) \(units(trade.shares))")
            Text("\(trade.date.formatted(date: .abbreviated, time: .omitted)) · \(usd(trade.pricePerShare)) per unit · \(usd(trade.fees)) fees")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func export(_ change: PortfolioLedgerChange) -> String {
        let holding = change.holding
        let trades = holding.transactions.filter { change.changed.contains($0.id) }.map { ($0.type.rawValue, $0) }
        let removals = change.deleted.map { ("Remove \($0.type.rawValue.lowercased())", $0) }
        let lines = (trades + removals).map { title, trade in
            "\(title) \(units(trade.shares)) on \(trade.date.formatted()) at \(usd(trade.pricePerShare)) per unit, \(usd(trade.fees)) fees"
        }
        return (["\(holding.asset.symbol) pending changes", "\(units(holding.shares)) units, \(usd(holding.avgCost)) average cost"] + lines)
            .joined(separator: "\n")
    }
}
