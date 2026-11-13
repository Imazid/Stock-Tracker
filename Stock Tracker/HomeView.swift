//
//  HomeView.swift
//  Stock Tracker
//

import SwiftUI
import Charts
import Combine

struct HomeView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var showSettings = false
    @EnvironmentObject var insightService: AIInsightService
    @State private var dailyBriefing: String?
    @State private var briefingLoading = false

    var body: some View {
        let theme = appTheme
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Sections rise in one after another the first time Home shows,
                        // and ease in/out at the scroll edges.

                        // 1. Who/when: greeting + market status
                        HomeHeader(onSettings: { showSettings = true })
                            .staggeredAppear(0)

                        // 2. Your money: value, today's move, chart, all-time
                        PortfolioSummaryHero()
                            .staggeredAppear(1).scrollCardMotion()

                        // 2b. Practice money, agents and anything waiting for a decision
                        HomeTradingSection()

                        // 3. What you follow
                        HomeWatchlistSection()
                            .staggeredAppear(2).scrollCardMotion()

                        // 4. What's next for it: earnings in the next 30 days (hidden when none)
                        HomeComingUpSection()
                            .staggeredAppear(3).scrollCardMotion()

                        // 5. The wider market — real index levels
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "Markets")
                            LiveIndicesWithGlow()
                        }
                        .staggeredAppear(4).scrollCardMotion()

                        // 6. Extras
                        dailyBriefingCard
                            .staggeredAppear(5).scrollCardMotion()
                        TrendingTickersSection()
                            .staggeredAppear(6).scrollCardMotion()
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, 60)
                }
                .refreshable { await marketData.refreshFromAPI() }
                // Earnings for "Coming up" — on the always-present scroll view (a .task on a
                // section that renders nothing until it has data never runs).
                .task(id: (marketData.watchlist.map(\.symbol) + marketData.portfolio.map(\.asset.symbol))
                        .sorted().joined(separator: ",")) {
                    await EarningsCalendar.shared.refresh(for: marketData.portfolio.map(\.asset) + marketData.watchlist)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .dsScreenBackground(style: .home)
            }

            .sheet(isPresented: $showSettings) {
                SettingsSheetView()
            }
        }
    }

    // MARK: - Daily AI Briefing

    private var dailyBriefingCard: some View {
        let tier = subscriptionManager.currentTier
        let isLocked = tier == .free
        let cacheKey = "daily_briefing_\(insightService.todayString)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? dailyBriefing
        return AIInsightCard(
            title: "Daily Briefing",
            icon: "sparkles",
            insightText: cachedText,
            isLoading: briefingLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadDailyBriefing() },
            onRegenerate: { await loadDailyBriefing(force: true) }
        )
    }

    private func loadDailyBriefing(force: Bool = false) async {
        briefingLoading = true
        defer { briefingLoading = false }

        let tier = subscriptionManager.currentTier
        let cacheKey = "daily_briefing_\(insightService.todayString)"

        // Build context from available data
        let sentiment = marketData.marketSentiment
        let portfolioMovers = marketData.portfolio
            .sorted { abs($0.asset.changePercent) > abs($1.asset.changePercent) }
            .prefix(3)
            .map { "\($0.asset.symbol) \(String(format: "%+.1f%%", $0.asset.changePercent))" }
            .joined(separator: ", ")

        let watchlistMovers = marketData.watchlist
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(3)
            .map { "\($0.symbol) \(String(format: "%+.1f%%", $0.changePercent))" }
            .joined(separator: ", ")

        let gainers = marketData.portfolio.filter { $0.asset.changePercent > 0 }.count
        let losers = marketData.portfolio.filter { $0.asset.changePercent < 0 }.count

        let systemPrompt = "You are a market analyst. Write a 2-sentence morning briefing. Be factual, no recommendations."
        let userPrompt = """
        Market sentiment: \(sentiment). \
        Portfolio: \(gainers) up, \(losers) down. Top movers: \(portfolioMovers.isEmpty ? "none" : portfolioMovers). \
        Watchlist highlights: \(watchlistMovers.isEmpty ? "none" : watchlistMovers). \
        Give a concise 2-sentence summary of today's market picture.
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .dailyBriefing,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .dailyBriefing,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.dailyCacheTTL
            )
        }
        if let text = result { dailyBriefing = text }
    }
}

/// Real index levels (Yahoo ^GSPC, ^AXJO… — points, not ETF prices) plus Bitcoin,
/// each with a real latest-session sparkline whose baseline matches its % pill.
struct LiveIndicesWithGlow: View {
    @EnvironmentObject var marketData: MarketData
    @AppStorage("preferredMarket") private var preferredMarket = "US"
    @State private var cards: [IndexCardModel] = []
    @State private var failed = false
    @State private var selected: Asset?

    struct IndexCardModel: Identifiable {
        let id: String
        let asset: Asset
        let isIndex: Bool
        var mini: MiniSeries?
    }

    private struct Spec { let name: String; let symbol: String; let kind: AssetKind }

    private var specs: [Spec] {
        let asx = Spec(name: "ASX 200", symbol: "^AXJO", kind: .stock)
        let us = [Spec(name: "S&P 500", symbol: "^GSPC", kind: .stock),
                  Spec(name: "Nasdaq", symbol: "^IXIC", kind: .stock),
                  Spec(name: "Dow Jones", symbol: "^DJI", kind: .stock)]
        let btc = Spec(name: "Bitcoin", symbol: "bitcoin", kind: .crypto)
        return preferredMarket == "AU" ? [asx] + us + [btc] : us + [asx, btc]
    }

    var body: some View {
        Group {
            if cards.isEmpty && failed {
                InlineRetryNote(text: "Market data isn't available right now.") { Task { await load() } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.m) {
                        if cards.isEmpty {
                            ForEach(0..<4, id: \.self) { _ in IndexCard.placeholder }
                        } else {
                            ForEach(cards) { card in
                                Button {
                                    Haptics.tap()
                                    selected = card.asset
                                } label: {
                                    IndexCard(model: card)
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                }
                .padding(.horizontal, -DS.Space.gutter)
            }
        }
        .task(id: marketData.lastQuoteRefreshDate) { await load() }
        .sheet(item: $selected) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
    }

    private func load() async {
        var loaded: [(Int, IndexCardModel)] = []
        await withTaskGroup(of: (Int, IndexCardModel?).self) { group in
            for (i, spec) in specs.enumerated() {
                group.addTask { @MainActor in
                    let asset: Asset?
                    if spec.kind == .crypto {
                        asset = try? await APIService.shared.fetchAssetDetails(identifier: spec.symbol, kind: .crypto, name: spec.name)
                    } else {
                        asset = try? await APIService.shared.fetchYahooQuote(symbol: spec.symbol, name: spec.name)
                    }
                    guard let asset else { return (i, nil) }
                    let mini = await PriceHistoryService.shared.miniSeries(for: asset)
                    return (i, IndexCardModel(id: spec.symbol, asset: asset, isIndex: spec.kind == .stock, mini: mini))
                }
            }
            for await (i, model) in group { if let model { loaded.append((i, model)) } }
        }
        let ordered = loaded.sorted { $0.0 < $1.0 }.map(\.1)
        if ordered.isEmpty {
            failed = true
        } else {
            failed = false
            dsAnimate(DS.quick) { cards = ordered }
        }
    }
}

private struct IndexCard: View {
    let model: LiveIndicesWithGlow.IndexCardModel
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    private var levelText: String {
        if model.isIndex {
            return model.asset.price.formatted(.number.precision(.fractionLength(2)))
        }
        return model.asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(model.asset.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Text(levelText)
                .font(DS.money(17))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ChangePill(percent: model.asset.changePercent, compact: true)
            DSSparkline(values: model.mini?.values ?? [], baseline: model.mini?.baseline)
                .frame(height: 30)
        }
        .padding(DS.Space.m + 2)
        .frame(width: 152, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(theme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(model.asset.name), \(levelText)")
        .accessibilityValue("\(model.asset.changePercent >= 0 ? "up" : "down") \(String(format: "%.2f", abs(model.asset.changePercent))) percent today")
        .accessibilityIdentifier("home.index.\(model.id)")
    }

    static var placeholder: some View {
        IndexCardPlaceholder()
    }
}

private struct IndexCardPlaceholder: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("S&P 500").font(.subheadline.weight(.semibold))
            Text("0,000.00").font(DS.money(17))
            Text("+0.00%").font(.caption)
            Rectangle().fill(theme.subtleFill).frame(height: 30)
        }
        .redacted(reason: .placeholder)
        .padding(DS.Space.m + 2)
        .frame(width: 152, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(theme.subtleFill))
        .accessibilityHidden(true)
    }
}

/// One-line failure note with a retry button.
struct InlineRetryNote: View {
    let text: LocalizedStringKey
    let retry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(theme.secondaryText)
            Text(text).font(.subheadline).foregroundStyle(theme.secondaryText)
            Spacer()
            Button("Retry") { Haptics.tap(); retry() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.accent)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, DS.Space.l)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
    }
}

/// Biggest moves today among the things you follow (real quotes, sorted by |%|).
struct TrendingTickersSection: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.theme) private var theme
    @State private var selected: Asset?

    private var movers: [Asset] {
        marketData.watchlist
            .filter { $0.price > 0 }
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        if movers.count >= 3 {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionHeader(title: "Biggest moves today")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(movers) { asset in
                            Button {
                                Haptics.tap()
                                selected = asset
                            } label: {
                                HStack(spacing: DS.Space.s) {
                                    TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 26)
                                    Text(asset.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                    ChangePill(percent: asset.changePercent, compact: true)
                                }
                                .padding(.leading, 6)
                                .padding(.trailing, 10)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(theme.subtleFill))
                                .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("\(asset.name), \(asset.changePercent >= 0 ? "up" : "down") \(String(format: "%.2f", abs(asset.changePercent))) percent")
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                }
                .padding(.horizontal, -DS.Space.gutter)
            }
            .sheet(item: $selected) { asset in
                AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(MarketData())
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(ThemeManager())
}
