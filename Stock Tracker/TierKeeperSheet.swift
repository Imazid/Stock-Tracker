//
//  TierKeeperSheet.swift
//  Stock Tracker
//
//  "Choose what to keep" — shown after a downgrade when the watchlist or the
//  portfolio has more than the new plan allows. New additions are blocked at
//  the source (MarketData.addHolding / canAddHolding), so this only appears
//  when a plan actually changes.
//

import SwiftUI

struct TierKeeperSheet: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.theme) private var theme

    @State private var step: KeeperStep = .watchlist
    @State private var selectedWatchlist: Set<UUID> = []
    @State private var selectedPortfolio: Set<UUID> = []
    @State private var showPaywall = false

    private enum KeeperStep { case watchlist, portfolio, done }

    // MARK: - Limits

    private var watchlistLimit: Int {
        FeatureGate.maxWatchlistAssets(for: subscriptionManager.currentTier) ?? Int.max
    }

    private var portfolioLimit: Int {
        FeatureGate.maxPortfolioHoldings(for: subscriptionManager.currentTier) ?? Int.max
    }

    private var needsWatchlistTrim: Bool { marketData.watchlist.count > watchlistLimit }
    private var needsPortfolioTrim: Bool { marketData.portfolio.count > portfolioLimit }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch step {
                case .watchlist:
                    if needsWatchlistTrim {
                        picker(
                            title: "Choose your watchlist",
                            subtitle: "Your \(subscriptionManager.currentTier.rawValue) plan follows \(watchlistLimit) assets and you have \(marketData.watchlist.count). Pick the \(watchlistLimit) to keep — the rest leave your watchlist.",
                            selected: selectedWatchlist.count,
                            limit: watchlistLimit,
                            confirmTitle: "Continue",
                            rows: marketData.watchlist.map { asset in
                                KeeperRowModel(id: asset.id, symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange,
                                               title: asset.symbol, subtitle: asset.name, detail: marketData.formatPrice(asset.price))
                            },
                            isSelected: { selectedWatchlist.contains($0) },
                            toggle: { toggle($0, in: &selectedWatchlist, limit: watchlistLimit) },
                            confirm: advanceFromWatchlist
                        )
                    } else {
                        Color.clear.onAppear { advanceFromWatchlist() }
                    }
                case .portfolio:
                    if needsPortfolioTrim {
                        picker(
                            title: "Choose your holdings",
                            subtitle: "Your \(subscriptionManager.currentTier.rawValue) plan tracks \(portfolioLimit) holdings and you have \(marketData.portfolio.count). Pick the \(portfolioLimit) to keep — the others and their transactions are removed from this portfolio.",
                            selected: selectedPortfolio.count,
                            limit: portfolioLimit,
                            confirmTitle: "Keep these \(portfolioLimit)",
                            rows: marketData.portfolio.sorted { $0.currentValue > $1.currentValue }.map { h in
                                KeeperRowModel(id: h.id, symbol: h.asset.symbol, kind: h.asset.kind, exchange: h.asset.exchange,
                                               title: h.asset.symbol, subtitle: h.asset.unitsText(h.shares),
                                               detail: marketData.formatPrice(h.currentValue))
                            },
                            isSelected: { selectedPortfolio.contains($0) },
                            toggle: { toggle($0, in: &selectedPortfolio, limit: portfolioLimit) },
                            confirm: {
                                applyPortfolioSelection()
                                finishSelection()
                            }
                        )
                    } else {
                        Color.clear.onAppear { finishSelection() }
                    }
                case .done:
                    Color.clear.onAppear { finishSelection() }
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .sheet(isPresented: $showPaywall) {
                PaywallView(requiredTier: subscriptionManager.currentTier == .free ? .pro : .black,
                            featureName: "Keep everything you track")
            }
            .onChange(of: subscriptionManager.currentTier) { _, _ in
                if !needsWatchlistTrim && !needsPortfolioTrim { finishSelection() }
            }
        }
    }

    // MARK: - Picker

    private struct KeeperRowModel: Identifiable {
        let id: UUID
        let symbol: String
        let kind: AssetKind
        let exchange: String
        let title: String
        let subtitle: String
        let detail: String
    }

    private func picker(title: String, subtitle: String, selected: Int, limit: Int, confirmTitle: String,
                        rows: [KeeperRowModel], isSelected: @escaping (UUID) -> Bool,
                        toggle: @escaping (UUID) -> Void, confirm: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(title)
                    .font(DS.display(.title, weight: .regular))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(selected) of \(limit) selected")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(selected == limit ? theme.primaryText : theme.secondaryText)
                    .padding(.top, DS.Space.xs)
                    .accessibilityIdentifier("keeper.count")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.gutter)

            List(rows) { row in
                Button { toggle(row.id) } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: isSelected(row.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected(row.id) ? DS.accent : theme.secondaryText.opacity(0.5))
                        TickerLogo(symbol: row.symbol, kind: row.kind, exchange: row.exchange, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.subheadline.weight(.semibold))
                            Text(row.subtitle).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1)
                        }
                        Spacer()
                        Text(row.detail)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(isSelected(row.id) ? .isSelected : [])
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            VStack(spacing: DS.Space.s) {
                Button(confirmTitle, action: confirm)
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(selected != limit)
                    .accessibilityIdentifier("keeper.confirm")
                Button("Upgrade instead") { showPaywall = true }
                    .buttonStyle(QuietTextButtonStyle())
            }
            .padding(DS.Space.gutter)
        }
    }

    // MARK: - Logic

    private func toggle(_ id: UUID, in set: inout Set<UUID>, limit: Int) {
        if set.contains(id) {
            set.remove(id)
        } else if set.count < limit {
            set.insert(id)
        } else {
            Haptics.warning()
            return
        }
        Haptics.select()
    }

    private func advanceFromWatchlist() {
        if needsWatchlistTrim {
            let idsToRemove = Set(marketData.watchlist.map(\.id)).subtracting(selectedWatchlist)
            marketData.removeMultipleFromWatchlist(idsToRemove)
        }
        if needsPortfolioTrim {
            step = .portfolio
        } else {
            finishSelection()
        }
    }

    private func applyPortfolioSelection() {
        for holding in marketData.portfolio where !selectedPortfolio.contains(holding.id) {
            marketData.removeFromPortfolio(holding)
        }
    }

    private func finishSelection() {
        subscriptionManager.clearKeeperSelection()
    }
}
