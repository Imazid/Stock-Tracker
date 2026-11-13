//
//  HomeSummaryViews.swift
//  Stock Tracker
//
//  The top of Home, ordered the way finance apps on Mobbin lead (Yahoo Finance,
//  Public, Robinhood-style): your money first — value, today's move, chart —
//  then the things you follow, then the wider market.
//

import SwiftUI
import OSLog

// MARK: - Header

struct HomeHeader: View {
    let onSettings: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.selectTab) private var selectTab

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    var body: some View {
        // Revolut's top bar: a round profile button, a search capsule, all in Liquid Glass.
        VStack(alignment: .leading, spacing: DS.Space.l) {
            GlassEffectContainer(spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Button {
                        Haptics.tap()
                        onSettings()
                    } label: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")

                    Button {
                        Haptics.tap()
                        selectTab(.search)
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Search stocks, ETFs, crypto")
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, DS.Space.l)
                        .frame(height: 44)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("home.search")
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(greeting)
                    .font(DS.display(.title))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                MarketStatusView()
            }
        }
    }
}

// MARK: - Portfolio hero

struct PortfolioSummaryHero: View {
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @Environment(\.selectTab) private var selectTab
    @State private var sheet: AddSource?

    @AppStorage("homeChartRange") private var rangeRaw = TimeRange.oneDay.rawValue

    enum AddSource: String, Identifiable {
        case broker, manual
        var id: String { rawValue }
    }

    private static let ranges: [TimeRange] = [.oneDay, .oneWeek, .oneMonth, .threeMonths, .ytd, .oneYear]

    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { TimeRange(rawValue: rangeRaw) ?? .oneDay }, set: { rangeRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if marketData.portfolio.isEmpty {
                emptyHero
            } else {
                summary
            }
        }
        .sheet(item: $sheet) { source in
            switch source {
            case .broker: SnapTradeConnectionView()
            case .manual: ManualPositionSheet()
            }
        }
    }

    /// No holdings yet: what Home will show, and three round glass actions to get there
    /// (Revolut's Add / Move / More row). No made-up balance: an empty portfolio isn't $0.
    private var emptyHero: some View {
        VStack(spacing: DS.Space.xl) {
            VStack(spacing: DS.Space.s) {
                Text("Your portfolio")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                Text("See everything you own in one place")
                    .font(.title.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect a broker or add holdings to track your total value, today's move and all-time return.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.l)
            actionRow
        }
        .padding(.vertical, DS.Space.l)
        .frame(maxWidth: .infinity)
    }

    /// Revolut's four round frosted actions under the balance.
    private var actionRow: some View {
        GlassEffectContainer(spacing: DS.Space.l) {
            HStack(alignment: .top, spacing: 0) {
                GlassActionButton(title: "Connect", systemImage: "link",
                                  accessibilityName: "Connect a broker") { sheet = .broker }
                Spacer(minLength: 0)
                GlassActionButton(title: "Add", systemImage: "plus",
                                  accessibilityName: "Enter holdings yourself") { sheet = .manual }
                Spacer(minLength: 0)
                GlassActionButton(title: "Practice", systemImage: "graduationcap") { selectTab(.portfolio) }
                Spacer(minLength: 0)
                GlassActionButton(title: "Agents", systemImage: "sparkles") { selectTab(.agents) }
            }
        }
    }

    /// Same chart as the Portfolio tab (PortfolioPerformanceChart): real history,
    /// scrubbing, ranges, honest notes — plus a link through and the all-time line.
    private var summary: some View {
        // Unrealised on holdings with a known cost + profit banked from sales.
        let total = marketData.totalReturn
        let totalPct = marketData.totalReturnPercent
        let totalColor = total >= 0 ? theme.positiveColor : theme.negativeColor

        return VStack(alignment: .leading, spacing: DS.Space.m) {
            PortfolioPerformanceChart(
                title: "Your portfolio",
                ranges: Self.ranges,
                range: rangeBinding,
                chartHeight: 150,
                showsTodayLine: false,
                accessibilityID: "chart.price",
                centered: true
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    Haptics.tap()
                    selectTab(.portfolio)
                } label: {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44)
                }
                .offset(y: -12)
                .accessibilityIdentifier("home.portfolio.seeAll")
            }

            Divider().overlay(theme.cardBorder.opacity(0.4))

            HStack(alignment: .firstTextBaseline) {
                HeroStat(label: "All-time return",
                         value: "\(signedMoney(total)) (\(String(format: "%+.2f%%", totalPct)))",
                         tint: totalColor)
                Spacer()
                HeroStat(label: "Holdings", value: "\(marketData.portfolio.count)", alignment: .trailing)
            }
        }
        // On the section gradient, not in a card (Revolut's balance hero).
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.portfolio")
    }

    private func signedMoney(_ value: Double) -> String {
        (value >= 0 ? "+" : "−") + marketData.formatPrice(abs(value))
    }
}

private struct HeroStat: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color? = nil
    var alignment: HorizontalAlignment = .leading
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? theme.primaryText)
        }
    }
}

// MARK: - Watchlist preview

struct HomeWatchlistSection: View {
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @Environment(\.selectTab) private var selectTab
    @State private var selected: Asset?

    private var assets: [Asset] { Array(marketData.watchlist.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(
                title: "Watchlist",
                actionTitle: assets.isEmpty ? nil : "See all",
                action: { selectTab(.markets) }
            )

            if assets.isEmpty {
                EmptyStateCard(
                    systemImage: "star",
                    title: "Follow a few companies",
                    message: "Add stocks, ETFs or crypto to see live prices and today's moves here.",
                    primaryTitle: "Find stocks",
                    primaryAction: { selectTab(.search) }
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(assets) { asset in
                        HomeWatchlistRow(asset: asset) { selected = asset }
                        if asset.id != assets.last?.id {
                            Divider()
                                .overlay(theme.cardBorder.opacity(0.4))
                                .padding(.leading, 68)
                        }
                    }
                }
                .dsCard(padding: 0)
            }
        }
        .sheet(item: $selected) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
    }
}

private struct HomeWatchlistRow: View {
    let asset: Asset
    let action: () -> Void
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    private var isLoaded: Bool { asset.price > 0 }

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            AdaptiveQuoteRow {
                HStack(spacing: DS.Space.m) {
                    TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(asset.name)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            } numbers: { stacked in
                QuoteNumbers(price: asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates),
                             percent: asset.changePercent, stacked: stacked)
                    .redacted(reason: isLoaded ? [] : .placeholder)
                    .priceFlash(value: asset.price)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(FinancialAccessibility.priceChangeDescription(
            symbol: asset.symbol,
            price: asset.price,
            change: asset.change,
            changePercent: asset.changePercent
        ))
        .accessibilityHint("Opens details")
        .accessibilityIdentifier("home.watchlist.\(asset.symbol)")
    }
}
