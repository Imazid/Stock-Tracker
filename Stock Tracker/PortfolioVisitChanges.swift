import SwiftUI

struct PortfolioVisitSnapshot: Codable {
    struct Scope: Codable, Equatable {
        let owner: UUID?
        let portfolio: UUID
    }

    struct Position: Codable, Equatable {
        let id: UUID
        let listing: String
        let symbol: String
        let accountID: String?
        let accountLabel: String?
        let units: Double
        let averageCostUSD: Double

        init(_ holding: PortfolioHolding) {
            id = holding.id
            listing = holding.asset.quoteIdentity
            symbol = holding.asset.symbol
            accountID = holding.brokerAccount?.account_id
            accountLabel = holding.brokerAccount?.label
            units = holding.shares
            averageCostUSD = holding.avgCost.isFinite && holding.avgCost > 0 ? holding.avgCost : 0
        }
    }

    let scope: Scope
    let date: Date
    let positions: [Position]
}

struct PortfolioVisitChanges {
    struct Change: Identifiable {
        let before: PortfolioVisitSnapshot.Position?
        let after: PortfolioVisitSnapshot.Position?
        let position: PortfolioVisitSnapshot.Position
        let quantityChanged: Bool
        let costChanged: Bool
        let listingChanged: Bool
        let accountChanged: Bool

        var id: UUID { position.id }

        init?(before: PortfolioVisitSnapshot.Position?, after: PortfolioVisitSnapshot.Position?) {
            guard let position = after ?? before else { return nil }
            self.before = before
            self.after = after
            self.position = position
            quantityChanged = Self.differs(before?.units, after?.units, by: 0.00000001)
            costChanged = Self.differs(before?.averageCostUSD, after?.averageCostUSD, by: 0.01)
                || (before?.averageCostUSD == 0) != (after?.averageCostUSD == 0)
            listingChanged = before?.listing != after?.listing
            accountChanged = before?.accountID != after?.accountID
            guard before == nil || after == nil || quantityChanged || costChanged || listingChanged || accountChanged else { return nil }
        }

        var description: String {
            if before == nil { return "New open position" }
            if after == nil { return "No longer open" }
            var changes: [String] = []
            if listingChanged { changes.append("Listing") }
            if accountChanged { changes.append("Brokerage account") }
            if quantityChanged { changes.append("Quantity") }
            if costChanged { changes.append("Average cost") }
            return changes.joined(separator: " · ") + " updated"
        }

        private static func differs(_ before: Double?, _ after: Double?, by threshold: Double) -> Bool {
            guard let before, let after else { return false }
            return abs(after - before) >= threshold - min(threshold / 100, max(before.ulp, after.ulp) * 2)
        }
    }

    let since: Date?
    let changes: [Change]

    init(previous: PortfolioVisitSnapshot?, current: [PortfolioVisitSnapshot.Position]) {
        since = previous?.date
        guard let previous else {
            changes = []
            return
        }
        let before = Dictionary(previous.positions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        changes = Set(before.keys).union(after.keys).compactMap { id in
            Change(before: before[id], after: after[id])
        }.sorted { lhs, rhs in
            let order = lhs.position.symbol.localizedStandardCompare(rhs.position.symbol)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }

    var summary: String {
        guard since != nil else { return "First portfolio visit on this device" }
        switch changes.count {
        case 0: return "No position changes since your last visit"
        case 1: return "1 position changed since your last visit"
        default: return "\(changes.count) positions changed since your last visit"
        }
    }
}

struct PortfolioVisitTracker {
    struct Input: Equatable {
        let scope: PortfolioVisitSnapshot.Scope?
        let positions: [PortfolioVisitSnapshot.Position]
        let isVisiting: Bool
    }

    private var previous: PortfolioVisitSnapshot?
    private var lastInput: Input?
    private(set) var report: PortfolioVisitChanges?

    mutating func observe(_ input: Input, now: Date = Date(), store: DataPersistenceManager = .shared) {
        defer { lastInput = input }
        guard let scope = input.scope else {
            previous = nil
            report = nil
            return
        }

        let changedScope = lastInput?.scope != scope
        let newVisit = input.isVisiting && lastInput?.isVisiting != true
        if changedScope || newVisit {
            previous = store.portfolioVisit(for: scope)
        }
        report = PortfolioVisitChanges(previous: previous, current: input.positions)
        if input.isVisiting, changedScope || newVisit || lastInput?.positions != input.positions {
            store.savePortfolioVisit(PortfolioVisitSnapshot(scope: scope, date: now, positions: input.positions))
        }
    }
}

struct PortfolioVisitChangesSheet: View {
    let report: PortfolioVisitChanges
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @AppStorage("portfolioValueHidden") private var valueHidden = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(report.summary)
                        .accessibilityIdentifier("portfolio.visit.summary")
                    if let since = report.since {
                        LabeledContent("Previous visit", value: since.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("Compares position records on this device. Changes include open positions, quantities, average costs and brokerage accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !report.changes.isEmpty {
                    Section("Positions") {
                        ForEach(report.changes) { change in
                            if canOpen(change) {
                                NavigationLink(value: change.id) { row(change) }
                            } else {
                                row(change)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Changes since last visit")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { HoldingDetailView(holdingID: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("portfolio.visit.done")
                }
            }
        }
    }

    private func canOpen(_ change: PortfolioVisitChanges.Change) -> Bool {
        marketData.portfolio.contains { $0.id == change.id } || marketData.closedPositions.contains { $0.id == change.id }
    }

    private func row(_ change: PortfolioVisitChanges.Change) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(change.position.symbol).font(.headline)
            if let account = change.position.accountLabel {
                Text(account).font(.caption).foregroundStyle(.secondary)
            }
            Text(change.description).font(.subheadline)
            if !valueHidden, let before = change.before, let after = change.after {
                if change.quantityChanged {
                    Text("Units \(formatQuantity(before.units)) → \(formatQuantity(after.units))")
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("portfolio.visit.units")
                }
                if change.costChanged {
                    Text("Average cost \(cost(before.averageCostUSD)) → \(cost(after.averageCostUSD))")
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("portfolio.visit.cost")
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func cost(_ amount: Double) -> String {
        amount > 0 ? TradingFormat.money(amount, "USD") : "Unavailable"
    }
}
