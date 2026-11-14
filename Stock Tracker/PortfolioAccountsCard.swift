//
//  PortfolioAccountsCard.swift
//  Stock Tracker
//
//  "Accounts" on the Portfolio tab: where the holdings come from. Each connected
//  broker with its holdings, value and how fresh the sync is; the holdings you
//  added yourself; and a quiet way to connect a broker. After Coinbase's account
//  rows under the balance and Origin / Copilot's linked accounts on Mobbin.
//

import SwiftUI

struct PortfolioAccountsCard: View {
    @EnvironmentObject private var marketData: MarketData
    @ObservedObject private var broker = SnapTradeViewModel.shared
    @Environment(\.theme) private var theme

    let hidesValues: Bool
    let onManageBrokers: () -> Void

    private var manual: [PortfolioHolding] { marketData.portfolio.filter { !broker.isImported($0) } }
    private var imported: [PortfolioHolding] { marketData.portfolio.filter { $0.shares > 0 && broker.isImported($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Accounts")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                let names = broker.institutions
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    institutionRow(name).staggeredAppear(index)
                    divider
                }
                // Imported earlier, accounts not loaded yet (launch sync still running).
                if names.isEmpty && !imported.isEmpty {
                    row(icon: { InstitutionTile(name: "Brokers", size: 36) },
                        title: "Your brokers",
                        detail: broker.lastSyncFailed ? "Couldn't sync" : "Syncing…",
                        detailIsWarning: broker.lastSyncFailed,
                        value: total(imported), chevron: true, id: "portfolio.account.brokers",
                        action: onManageBrokers)
                    divider
                }
                if !manual.isEmpty {
                    row(icon: { symbolTile("square.and.pencil", tint: theme.secondaryText) },
                        title: "Added by you",
                        detail: count(manual.count),
                        value: total(manual), chevron: false, id: "portfolio.account.manual",
                        action: nil)
                }
                if !broker.pendingRemovals.isEmpty {
                    divider
                    reviewRow
                }
                if !broker.hasLinkedAccounts {
                    if !manual.isEmpty || !imported.isEmpty { divider }
                    row(icon: { symbolTile("link", tint: DS.accent) },
                        title: "Connect a broker or exchange",
                        detail: "Bring your holdings in automatically · read-only",
                        value: nil, chevron: true, id: "portfolio.account.connect",
                        action: onManageBrokers)
                }
            }
            .dsCard(padding: DS.Space.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("portfolio.accounts")
    }

    // MARK: Rows

    private func institutionRow(_ name: String) -> some View {
        let held = imported.filter { broker.institutionKey(for: $0) == name }
        let detail: String
        if broker.lastSyncFailed {
            detail = "Couldn't sync — open to try again"
        } else if let synced = broker.lastSyncedAt {
            detail = "\(count(held.count)) · \(SnapTradeViewModel.syncedText(synced))"
        } else {
            detail = count(held.count)
        }
        return row(icon: { InstitutionTile(name: name, size: 36, logoURL: broker.logoURL(for: name)) },
                   title: broker.displayName(forInstitution: name), detail: detail, detailIsWarning: broker.lastSyncFailed,
                   value: held.isEmpty ? nil : total(held), chevron: true,
                   id: "portfolio.account.\(name)", action: onManageBrokers)
    }

    private var reviewRow: some View {
        let n = broker.pendingRemovals.count
        return Button {
            Haptics.tap()
            onManageBrokers()
        } label: {
            HStack(spacing: DS.Space.m) {
                symbolTile("exclamationmark.triangle.fill", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(n == 1 ? "1 holding is no longer at your broker" : "\(n) holdings are no longer at your broker")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(broker.pendingRemovals.map(\.asset.symbol).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: DS.Space.s)
                Text("Review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
            }
            .padding(.vertical, DS.Space.s)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("portfolio.account.review")
    }

    private func row<Icon: View>(@ViewBuilder icon: () -> Icon, title: String, detail: String,
                                 detailIsWarning: Bool = false, value: String?, chevron: Bool,
                                 id: String, action: (() -> Void)?) -> some View {
        let content = HStack(spacing: DS.Space.m) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailIsWarning ? theme.negativeColor : theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Space.s)
            if let value {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
        }
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: 44)
        .contentShape(Rectangle())

        return Group {
            if let action {
                Button { Haptics.tap(); action() } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func symbolTile(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var divider: some View {
        Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 52)
    }

    // MARK: Values

    private func total(_ holdings: [PortfolioHolding]) -> String {
        hidesValues ? "••••" : marketData.formatPrice(holdings.reduce(0) { $0 + $1.currentValue })
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 holding" : "\(n) holdings" }
}
