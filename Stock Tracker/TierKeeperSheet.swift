//
//  TierKeeperSheet.swift
//  Stock Tracker
//
//  "Choose Your Keepers" — presented after a downgrade when
//  watchlist or portfolio counts exceed the new tier's limits.
//

import SwiftUI

struct TierKeeperSheet: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var step: KeeperStep = .watchlist
    @State private var selectedWatchlist: Set<UUID> = []
    @State private var selectedPortfolio: Set<UUID> = []

    private enum KeeperStep {
        case watchlist
        case portfolio
        case done
    }

    // MARK: - Limits

    private var watchlistLimit: Int {
        FeatureGate.maxWatchlistAssets(for: subscriptionManager.currentTier) ?? Int.max
    }

    private var portfolioLimit: Int {
        FeatureGate.maxPortfolioHoldings(for: subscriptionManager.currentTier) ?? Int.max
    }

    private var needsWatchlistTrim: Bool {
        marketData.watchlist.count > watchlistLimit
    }

    private var needsPortfolioTrim: Bool {
        marketData.portfolio.count > portfolioLimit
    }

    // MARK: - Body

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    switch step {
                    case .watchlist:
                        if needsWatchlistTrim {
                            watchlistPicker(theme: theme)
                        } else {
                            // Skip to portfolio or finish
                            Color.clear.onAppear { advanceFromWatchlist() }
                        }
                    case .portfolio:
                        if needsPortfolioTrim {
                            portfolioPicker(theme: theme)
                        } else {
                            Color.clear.onAppear { finishSelection() }
                        }
                    case .done:
                        Color.clear.onAppear { finishSelection() }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Watchlist Picker

    @ViewBuilder
    private func watchlistPicker(theme: Theme) -> some View {
        VStack(spacing: 0) {
            headerView(
                title: "Choose Your Watchlist",
                subtitle: "Your plan allows \(watchlistLimit) items. You have \(marketData.watchlist.count).",
                instruction: "Select \(watchlistLimit) to keep. The rest will be removed.",
                theme: theme
            )

            // Counter
            counterBadge(selected: selectedWatchlist.count, limit: watchlistLimit, theme: theme)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(marketData.watchlist) { asset in
                        keeperRow(
                            title: asset.symbol,
                            subtitle: asset.name,
                            detail: String(format: "$%.2f", asset.price),
                            isSelected: selectedWatchlist.contains(asset.id),
                            theme: theme
                        ) {
                            toggleSelection(id: asset.id, in: &selectedWatchlist, limit: watchlistLimit)
                        }
                        Divider().opacity(0.2).padding(.leading, 56)
                    }
                }
                .padding(.horizontal, 16)
            }

            continueButton(
                enabled: selectedWatchlist.count == watchlistLimit,
                theme: theme
            ) {
                advanceFromWatchlist()
            }
        }
    }

    // MARK: - Portfolio Picker

    @ViewBuilder
    private func portfolioPicker(theme: Theme) -> some View {
        VStack(spacing: 0) {
            headerView(
                title: "Choose Your Holdings",
                subtitle: "Your plan allows \(portfolioLimit) holdings. You have \(marketData.portfolio.count).",
                instruction: "Select \(portfolioLimit) to keep. The rest will be removed.",
                theme: theme
            )

            counterBadge(selected: selectedPortfolio.count, limit: portfolioLimit, theme: theme)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(marketData.portfolio) { holding in
                        keeperRow(
                            title: holding.asset.symbol,
                            subtitle: holding.asset.name,
                            detail: "\(String(format: "%.2f", holding.shares)) shares",
                            isSelected: selectedPortfolio.contains(holding.id),
                            theme: theme
                        ) {
                            toggleSelection(id: holding.id, in: &selectedPortfolio, limit: portfolioLimit)
                        }
                        Divider().opacity(0.2).padding(.leading, 56)
                    }
                }
                .padding(.horizontal, 16)
            }

            continueButton(
                enabled: selectedPortfolio.count == portfolioLimit,
                theme: theme,
                label: "Confirm"
            ) {
                applyPortfolioSelection()
                finishSelection()
            }
        }
    }

    // MARK: - Shared Components

    @ViewBuilder
    private func headerView(title: String, subtitle: String, instruction: String, theme: Theme) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
                .padding(.top, 24)

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundColor(theme.primaryText)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(theme.secondaryText)

            Text(instruction)
                .font(.caption)
                .foregroundColor(.orange)
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func counterBadge(selected: Int, limit: Int, theme: Theme) -> some View {
        HStack {
            Spacer()
            Text("\(selected) of \(limit) selected")
                .font(.caption.weight(.semibold))
                .foregroundColor(selected == limit ? .green : theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(selected == limit ? Color.green.opacity(0.15) : theme.secondaryText.opacity(0.1))
                )
            Spacer()
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func keeperRow(title: String, subtitle: String, detail: String, isSelected: Bool, theme: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .green : theme.secondaryText.opacity(0.4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func continueButton(enabled: Bool, theme: Theme, label: String = "Continue", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline.weight(.bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(enabled ? Color.blue : Color.gray.opacity(0.4))
                .cornerRadius(14)
        }
        .disabled(!enabled)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Logic

    private func toggleSelection(id: UUID, in set: inout Set<UUID>, limit: Int) {
        if set.contains(id) {
            set.remove(id)
        } else if set.count < limit {
            set.insert(id)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func advanceFromWatchlist() {
        // Apply watchlist selection — remove unselected
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
        let holdingsToRemove = marketData.portfolio.filter { !selectedPortfolio.contains($0.id) }
        for holding in holdingsToRemove {
            marketData.removeFromPortfolio(holding)
        }
    }

    private func finishSelection() {
        subscriptionManager.clearKeeperSelection()
    }
}
