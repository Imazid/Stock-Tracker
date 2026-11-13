//
//  ClosedPositionViews.swift
//  Stock Tracker
//
//  Holdings sold down to zero (after Binance "Position history" and QuestMobile
//  "Closed P&L" on Mobbin): a "Closed positions" list under Holdings, and a sheet
//  with what was paid, what the sales brought in and the realised profit. Their
//  realised profit stays in the portfolio's total return until removed here.
//
//  Also the transaction row shared with HoldingDetailView.
//

import SwiftUI

// MARK: - Transaction row

/// One buy or sell. A sale shows the profit it realised when that's known.
struct TransactionRow: View {
    let tx: Transaction
    let asset: Asset
    var realized: Double? = nil
    var hidesValues = false

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: tx.type == .buy ? "arrow.down.left" : "arrow.up.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.subtleFill))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tx.type == .buy ? "Bought" : "Sold") \(asset.unitsText(tx.shares))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(hidesValues ? "••••" : marketData.formatPrice(tx.totalValue))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.primaryText)
                Text("at \(marketData.formatPrice(tx.pricePerShare))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                if let realized, !hidesValues {
                    Text("Realised \(marketData.signedMoney(realized))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(realized >= 0 ? theme.positiveColor : theme.negativeColor)
                }
            }
        }
        .padding(.vertical, DS.Space.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let date = tx.date.formatted(date: .abbreviated, time: .omitted)
        guard tx.fees > 0 else { return date }
        return "\(date) · fees \(marketData.formatPrice(tx.fees))"
    }
}

// MARK: - Closed position row

struct ClosedPositionRow: View {
    let position: ClosedPosition
    var hidesValues = false

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    var body: some View {
        let gain = position.realizedGain
        let known = position.ledger.costOfSold > 0
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: position.asset.symbol, kind: position.asset.kind, exchange: position.asset.exchange, size: 40)
                .opacity(0.75)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(position.asset.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    if position.asset.isASX { MarketBadge(text: "ASX") }
                }
                Text("Sold all · \(position.closedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 4) {
                if known {
                    Text(hidesValues ? "••••" : marketData.signedMoney(gain))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(gain >= 0 ? theme.positiveColor : theme.negativeColor)
                    ChangePill(percent: position.realizedPercent, compact: true)
                } else {
                    Text("Cost not set")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(.vertical, DS.Space.s + 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = ["\(position.asset.symbol), closed position",
                     "sold all on \(position.closedAt.formatted(date: .abbreviated, time: .omitted))"]
        if position.ledger.costOfSold > 0, !hidesValues {
            parts.append("realised \(marketData.signedMoney(position.realizedGain))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Closed position sheet

struct ClosedPositionSheet: View {
    let positionID: UUID

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @State private var confirmRemove = false

    private var position: ClosedPosition? { marketData.closedPositions.first { $0.id == positionID } }

    var body: some View {
        NavigationStack {
            Group {
                if let position {
                    content(position)
                } else {
                    EmptyStateCard(systemImage: "checkmark.circle", title: "Removed",
                                   message: "This closed position is no longer in your history.",
                                   primaryTitle: "Done", primaryAction: { dismiss() })
                        .padding(DS.Space.gutter)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .dsScreenBackground()
            .navigationTitle(position.map { "\($0.asset.symbol) · closed" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Remove \(position?.asset.symbol ?? "position") from history?",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    marketData.removeClosedPosition(id: positionID)
                    Haptics.success()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its trades are deleted and its realised profit no longer counts in your total return.")
            }
        }
    }

    private func content(_ p: ClosedPosition) -> some View {
        let ledger = p.ledger
        let gain = p.realizedGain
        let known = ledger.costOfSold > 0
        let fees = p.transactions.reduce(0) { $0 + $1.fees }
        let hide = valueHidden
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(spacing: DS.Space.m) {
                    TickerLogo(symbol: p.asset.symbol, kind: p.asset.kind, exchange: p.asset.exchange, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.asset.name).font(.headline).lineLimit(2)
                        Text("Held \(p.openedAt.formatted(date: .abbreviated, time: .omitted)) – \(p.closedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Realised profit")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                    if known {
                        Text(hide ? "••••" : marketData.signedMoney(gain))
                            .font(DS.money(34, weight: .bold))
                            .foregroundStyle(gain >= 0 ? theme.positiveColor : theme.negativeColor)
                            .accessibilityIdentifier("closed.realised")
                        ChangePill(percent: p.realizedPercent)
                    } else {
                        Text("Unknown — no cost was entered for these shares.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                VStack(spacing: 0) {
                    LedgerLine(label: "Cost of shares sold", value: known ? (hide ? "••••" : marketData.formatPrice(ledger.costOfSold)) : "—")
                    LedgerLine(label: "Sale proceeds", value: hide ? "••••" : marketData.formatPrice(ledger.proceeds + fees),
                               detail: fees > 0 ? "after fees \(marketData.formatPrice(ledger.proceeds))" : nil)
                    if fees > 0 {
                        LedgerLine(label: "Fees", value: hide ? "••••" : marketData.formatPrice(fees))
                    }
                    LedgerLine(label: "Sales", value: "\(ledger.sellCount)")
                }
                .dsCard()

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Transactions")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        let sorted = p.transactions.sorted { $0.date > $1.date }
                        ForEach(sorted) { tx in
                            TransactionRow(tx: tx, asset: p.asset, realized: ledger.realizedBySale[tx.id], hidesValues: hide)
                            if tx.id != sorted.last?.id { Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 44) }
                        }
                    }
                }

                Text("Realised profit is each sale's price minus your average cost at the time, after fees. It's counted in your portfolio's total return.")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Remove from history", role: .destructive) { confirmRemove = true }
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.negativeColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("closed.remove")
            }
            .padding(DS.Space.gutter)
        }
        .accessibilityIdentifier("closed.sheet")
    }
}
