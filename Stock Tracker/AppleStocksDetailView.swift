//
//  AppleStocksDetailView.swift
//  Stock Tracker
//
//  The stock / crypto / index detail screen: one calm scroll, no tab bar.
//
//    identity · price · change for the period · market status
//    chart (line or Pro candles) + range picker
//    your position (or "Own AAPL? Add")
//    key statistics
//    analysts · earnings · financials (Pro) · AI summary (Pro)   — US listings
//    about · sources
//
//  Data rules (see CLAUDE.md): the price and day change are the app's own live
//  quote; FMP / Finnhub are asked only about US stocks (they answer "BHP" with
//  the NYSE ADR and "BTC" with the Grayscale ETF); crypto facts come from
//  CoinGecko; charts are real history or an honest "unavailable".
//

import SwiftUI
import Combine
import OSLog
import TradingCore

// MARK: - Screen

struct AppleStocksDetailView: View {
    @StateObject private var model: AssetDetailViewModel
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var alertManager: PriceAlertManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var sheet: DetailSheet?
    @State private var toast: DetailToast?
    @State private var showsCompactTitle = false
    @State private var scrubbed: DSChartPoint?
    @State private var scrubbedCandle: Candle?
    /// The listing's brand colour from its logo, for the glow behind the page (Fey / Luma).
    @State private var brandTint: Color?

    /// `position` is kept for source compatibility; holdings are read live from
    /// `marketData.portfolio` so the block is never stale or missing.
    init(stock: DetailedStock, asset: Asset? = nil, position: StockPosition? = nil) {
        let seed = asset ?? Asset(
            symbol: stock.symbol, name: stock.name, price: stock.currentPrice,
            change: stock.dayChange, changePercent: stock.dayChangePercent,
            volume: Double(stock.volume), kind: stock.exchange == "Crypto" ? .crypto : .stock,
            exchange: stock.exchange)
        _model = StateObject(wrappedValue: AssetDetailViewModel(seed: seed, stock: stock))
    }

    // MARK: Derived

    private var kind: DetailAssetKind { model.kind }
    private var tracked: Asset? { model.trackedAsset(in: marketData) }
    private var live: Asset { tracked ?? model.quote }

    private var format: DetailFormatter {
        DetailFormatter(currency: marketData.preferredCurrency, rates: marketData.exchangeRates,
                        isPoints: kind == .index)
    }

    private var holding: PortfolioHolding? {
        marketData.portfolio.first { model.matches($0.asset) }
    }

    private var watchEntry: Asset? {
        marketData.watchlist.first { model.matches($0) }
    }

    private var hasActiveAlert: Bool {
        alertManager.alerts.contains { $0.symbol == live.symbol && $0.isActive }
    }

    private var isPro: Bool { subscriptions.currentTier != .free }
    private var canTrack: Bool { kind != .index }

    private var lastUpdated: Date? {
        tracked != nil ? marketData.lastQuoteRefreshDate : model.refreshedAt
    }

    private var quoteFailed: Bool {
        tracked != nil ? marketData.quoteFailures.contains(live.symbol) : model.ownQuoteFailed
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    DetailHeaderChart(
                        model: model,
                        live: live,
                        format: format,
                        lastUpdated: lastUpdated,
                        quoteFailed: quoteFailed,
                        candlesLocked: !isPro,
                        onLockedCandles: { sheet = .paywall("Candlestick Charts") },
                        scrubbed: $scrubbed,
                        scrubbedCandle: $scrubbedCandle
                    )

                    // Paper Buy / Sell and "Create agent" for assets that can be traded.
                    AssetTradeBar(asset: live)

                    if canTrack {
                        if let holding {
                            DetailPositionCard(holding: holding, live: live, format: format)
                        } else {
                            DetailOwnPrompt(symbol: live.symbol, onLinkBroker: { sheet = .broker }) { sheet = .portfolio }
                        }
                    }

                    if live.kind == .stock, let instrument = Instrument(asset: live), let origin = CompanyResearchView.origin {
                        Button {
                            sheet = .research(instrument, origin)
                        } label: {
                            Label("Research Everything", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("detail.companyResearch")
                    }

                    statistics

                    switch kind {
                    case .usStock:
                        usSections
                    case .asxStock:
                        DetailNote(systemImage: "info.circle",
                                   text: "Analyst ratings, earnings and financial statements aren't available for ASX listings yet.",
                                   identifier: "detail.asxNote")
                    case .crypto, .index, .otherStock:
                        EmptyView()
                    }

                    about

                    Text(sourcesText)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("detail.sources")
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.s)
                .padding(.bottom, DS.Space.xxl)
            }
            .accessibilityIdentifier("detail.screen")
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 170
            } action: { _, isPast in
                if isPast != showsCompactTitle { dsAnimate(DS.quick) { showsCompactTitle = isPast } }
            }
            .refreshable {
                if tracked != nil { await marketData.refreshFromAPI() }
                await model.refresh()
            }
            .dsScreenBackground(tint: brandTint)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task(id: live.symbol) {
            guard let url = TickerLogo.logoURL(symbol: live.symbol, kind: live.kind, exchange: live.exchange),
                  let image = await LogoImageCache.shared.load(url) else { return }
            let tint = LogoDisc.brandColor(of: image, key: url.absoluteString)
            dsAnimate(DS.spring) { brandTint = tint }
        }
        .overlay(alignment: .bottom) { toastView }
        .task { await model.start(isTracked: tracked != nil, candlesAllowed: isPro) }
        .onChange(of: marketData.lastQuoteRefreshDate) { _, _ in
            if model.range == .oneDay { model.loadChart() }
        }
        .onChange(of: subscriptions.currentTier) { _, tier in
            if tier == .free && model.style == .candle { model.style = .line }
        }
        .onChange(of: model.stock.dividendYield) { _, yield in
            if kind == .usStock, let yield, yield > 0 {
                marketData.updateAssetDividend(symbol: live.symbol, yieldPercent: yield * 100)
            }
        }
        .onChange(of: model.range) { _, _ in
            scrubbed = nil
            scrubbedCandle = nil
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .alert:
                AddPriceAlertSheet(asset: live)
                    .environmentObject(alertManager)
                    .environmentObject(SubscriptionManager.shared)
                    .environmentObject(marketData)
            case .portfolio:
                AddToPortfolioSheet(asset: live)
                    .environmentObject(marketData)
                    .environmentObject(SubscriptionManager.shared)
            case .broker:
                SnapTradeConnectionView()
                    .environmentObject(marketData)
            case .research(let instrument, let origin):
                CompanyResearchView(instrument: instrument, origin: origin)
            case .paywall(let feature):
                PaywallView(requiredTier: .pro, featureName: feature)
                    .environmentObject(SubscriptionManager.shared)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("detail.close")
        }
        ToolbarItem(placement: .principal) {
            if showsCompactTitle {
                VStack(spacing: 0) {
                    Text(kind == .index ? live.name : live.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(live.price > 0 ? format.money(live.price) : "—")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail.compactTitle")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canTrack {
                Button {
                    toggleWatchlist()
                } label: {
                    Image(systemName: watchEntry == nil ? "star" : "star.fill")
                        .foregroundStyle(watchEntry == nil ? theme.primaryText : DS.accent)
                }
                .accessibilityLabel(watchEntry == nil ? "Add to Watchlist" : "Remove from Watchlist")
                .accessibilityIdentifier("detail.watchlist")

                Button {
                    Haptics.tap()
                    sheet = .alert
                } label: {
                    Image(systemName: hasActiveAlert ? "bell.fill" : "bell")
                        .foregroundStyle(hasActiveAlert ? DS.accent : theme.primaryText)
                }
                .accessibilityLabel(hasActiveAlert ? "Price alert set. Add another" : "Set a price alert")
                .accessibilityIdentifier("detail.alert")
            }

            Menu {
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if canTrack {
                    Button {
                        sheet = .portfolio
                    } label: {
                        Label(holding == nil ? "Add to portfolio" : "Add more to portfolio", systemImage: "briefcase")
                    }
                    .accessibilityIdentifier("detail.menu.addToPortfolio")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("detail.more")
        }
    }

    // MARK: Actions

    private func toggleWatchlist() {
        if let entry = watchEntry {
            Haptics.tap()
            marketData.removeFromWatchlist(entry)
            show(DetailToast(text: "Removed from Watchlist", icon: "star.slash"))
            return
        }
        if let limit = subscriptions.currentTier.maxWatchlistAssets, marketData.watchlist.count >= limit {
            Haptics.warning()
            sheet = .paywall("More watchlist slots")
            return
        }
        Haptics.success()
        marketData.addToWatchlist(live)
        show(DetailToast(text: "Added to Watchlist", icon: "star.fill"))
    }

    private func show(_ newToast: DetailToast) {
        dsAnimate(DS.spring) { toast = newToast }
        UIAccessibility.post(notification: .announcement, argument: newToast.text)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: DS.Space.s) {
                Image(systemName: toast.icon)
                    .foregroundStyle(DS.accent)
                Text(toast.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(minHeight: 44)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
            .padding(.bottom, DS.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("detail.toast")
            .task(id: toast.id) {
                // A newer toast cancels this task; don't let the stale one clear it.
                guard (try? await Task.sleep(for: .seconds(4))) != nil, self.toast?.id == toast.id else { return }
                dsAnimate(DS.quick) { self.toast = nil }
            }
        }
    }

    private var shareText: String {
        let price = live.price > 0 ? format.money(live.price) : ""
        let name = kind == .index ? live.name : "\(live.name) (\(live.symbol))"
        return "\(name) \(price) \(String(format: "%+.2f%%", live.changePercent)) today"
    }

    // MARK: US sections

    @ViewBuilder
    private var usSections: some View {
        if let insight = model.insight, insight.consensus != nil || insight.targets != nil || !insight.ratingChanges.isEmpty {
            DetailAnalystsSection(insight: insight, price: live.price, format: format)
        } else if model.insightState == .loading {
            loadingSection("What analysts say")
        }
        if let next = model.nextEarnings {
            DetailNextEarningsCard(event: next, name: live.name)
        }
        if let earnings = model.insight?.earnings, earnings.contains(where: { $0.epsActual != nil }) {
            DetailEarningsSection(entries: earnings, format: format)
        }
        DetailFinancialsSection(
            isLocked: !isPro,
            income: model.stock.incomeStatements,
            statements: model.statements,
            statementsLoading: model.statementsState == .loading,
            format: format,
            onUnlock: { sheet = .paywall("Financial statements") },
            onNeedStatements: { Task { await model.loadStatements() } }
        )
        if isPro {
            DetailAISummaryCard(symbol: live.symbol, facts: aiFacts)
        }
    }

    private func loadingSection(_ title: LocalizedStringKey) -> some View {
        DetailSection(title: title, identifier: "detail.loading") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(theme.cardBorder.opacity(0.35)).frame(height: 14)
                }
            }
            .dsCard()
            .accessibilityLabel("Loading")
        }
    }

    private var aiFacts: String {
        var parts = ["\(live.name) (\(live.symbol)), a US-listed stock."]
        if live.price > 0 { parts.append("Price \(format.money(live.price)), \(String(format: "%+.2f%%", live.changePercent)) today.") }
        if model.pointsRange == .oneYear, let first = model.points.first?.price, first > 0 {
            parts.append(String(format: "Past year: %+.1f%%.", (live.price - first) / first * 100))
        }
        let s = model.stock
        if let pe = s.peRatio, pe > 0 { parts.append(String(format: "P/E %.1f.", pe)) }
        if s.marketCap > 0 { parts.append("Market cap \(format.compactMoney(s.marketCap)).") }
        if let m = s.profitMargin { parts.append("Net margin \(format.percent(m)).") }
        if let g = s.revenueGrowthYoY { parts.append("Revenue growth \(format.percent(g, signed: true)) year on year.") }
        if let c = model.insight?.consensus {
            parts.append("Analysts: \(c.buyCount) buy, \(c.hold) hold, \(c.sellCount) sell.")
        }
        if let t = model.insight?.targets { parts.append("Average price target \(format.money(t.average)).") }
        if let sector = s.sector { parts.append("Sector: \(sector).") }
        return parts.joined(separator: " ")
    }

    // MARK: Statistics

    @ViewBuilder
    private var statistics: some View {
        switch kind {
        case .crypto:
            cryptoStats
        case .index:
            DetailKeyStats(ranges: week52Range(low: live.week52Low, high: live.week52High),
                           primary: [StatItem(label: "Prev close", value: previousCloseText)],
                           format: format)
        case .asxStock, .otherStock:
            listingStats
        case .usStock:
            usStats
        }
    }

    /// ASX / other Yahoo listings. Market cap and P/E need paid data for the ASX,
    /// so they're left out rather than shown as "—" forever.
    private var listingStats: some View {
        let f = model.listingFacts
        var ranges: [RangeItem] = []
        if let lo = f?.dayLow, let hi = f?.dayHigh, hi >= lo, live.price > 0 {
            ranges.append(RangeItem(label: "Day range", low: min(lo, live.price), high: max(hi, live.price), current: live.price))
        }
        ranges += week52Range(low: live.week52Low, high: live.week52High)

        let volume = f?.volume ?? (live.volume > 0 ? live.volume : nil)
        var primary: [StatItem] = [
            StatItem(label: "Prev close", value: previousCloseText),
            StatItem(label: "Volume", value: volume.map(format.compactNumber) ?? "—"),
            StatItem(label: "Avg. volume", value: f?.avgVolume3M.map(format.compactNumber) ?? "—")
        ]
        var more: [StatItem] = []
        if let f {
            if let ttm = f.trailing12MonthDividendUSD, live.price > 0 {
                primary.append(StatItem(label: "Div. yield", value: format.percent(ttm / live.price)))
                more.append(StatItem(label: "Dividends (12M)", value: format.money(ttm)))
            } else {
                primary.append(StatItem(label: "Div. yield", value: "None (12M)"))
            }
            if let last = f.dividends.last {
                more.append(StatItem(label: "Last dividend",
                                     value: "\(format.money(last.amountUSD)) · \(last.date.formatted(.dateTime.day().month(.abbreviated).year()))"))
            }
        }
        return DetailKeyStats(
            caption: model.fundamentalsState == .failed ? "Volume and dividend figures couldn't be loaded right now." : nil,
            ranges: ranges, primary: primary, more: more,
            isLoading: model.fundamentalsState == .loading, format: format)
    }

    private var previousCloseText: String {
        let pc = live.price - live.change
        return live.price > 0 && pc > 0 ? format.money(pc) : "—"
    }

    private func week52Range(low: Double?, high: Double?) -> [RangeItem] {
        guard let low, let high, low > 0, high > low, live.price > 0 else { return [] }
        return [RangeItem(label: "52-week range", low: low, high: high, current: live.price)]
    }

    private var usStats: some View {
        let s = model.stock
        var ranges: [RangeItem] = []
        if let lo = s.dayLow, let hi = s.dayHigh, lo > 0, hi >= lo, live.price > 0 {
            ranges.append(RangeItem(label: "Day range", low: min(lo, live.price), high: max(hi, live.price), current: live.price))
        }
        let lo52 = s.week52Low > 0 ? s.week52Low : (live.week52Low ?? 0)
        let hi52 = s.week52High > 0 ? s.week52High : (live.week52High ?? 0)
        ranges += week52Range(low: lo52, high: hi52)

        // Alpaca's free IEX feed sees only a few percent of US volume; show
        // consolidated volume from FMP or nothing.
        let volume = Double(s.volume)
        var primary: [StatItem] = [
            StatItem(label: "Prev close", value: previousCloseText),
            StatItem(label: "Market cap", value: s.marketCap > 0 ? format.compactMoney(s.marketCap) : "—"),
            StatItem(label: "Volume", value: volume > 0 ? format.compactNumber(volume) : "—"),
            StatItem(label: "P/E ratio", value: s.peRatio.map(format.ratio) ?? "—"),
            StatItem(label: "Div. yield", value: s.dividendYield.flatMap { $0 > 0 ? format.percent($0) : nil } ?? "—"),
            StatItem(label: "Beta", value: s.beta.map(format.ratio) ?? "—")
        ]
        if let open = s.openPrice, open > 0 {
            primary.insert(StatItem(label: "Open", value: format.money(open)), at: 1)
        }
        if s.avgVolume > 0 {
            primary.append(StatItem(label: "Avg. volume", value: format.compactNumber(Double(s.avgVolume))))
        }

        var more: [StatItem] = []
        func add(_ label: String, _ value: String?) { if let value { more.append(StatItem(label: label, value: value)) } }
        add("Fwd P/E", s.forwardPE.map(format.ratio))
        add("PEG", s.pegRatio.map(format.ratio))
        add("Price/book", s.priceToBook.map(format.ratio))
        add("Price/sales", s.priceToSales.map(format.ratio))
        add("Gross margin", s.grossMargin.map { format.percent($0) })
        add("Op. margin", s.operatingMargin.map { format.percent($0) })
        add("Net margin", s.profitMargin.map { format.percent($0) })
        add("Revenue (FY)", s.revenue.map(format.compactMoney))
        add("Rev. growth", s.revenueGrowthYoY.map { format.percent($0, signed: true) })
        add("EPS growth", s.earningsGrowthYoY.map { format.percent($0, signed: true) })
        add("Debt/equity", s.debtToEquity.map(format.ratio))
        add("Free cash flow", s.freeCashFlow.map(format.compactMoney))
        add("Shares out.", s.sharesOutstanding > 0 ? format.compactNumber(s.sharesOutstanding) : nil)
        add("50-day avg.", s.priceAvg50.map(format.money))
        add("200-day avg.", s.priceAvg200.map(format.money))

        return DetailKeyStats(
            caption: model.fundamentalsState == .failed ? "Company figures couldn't be loaded right now." : nil,
            ranges: ranges, primary: primary, more: more,
            isLoading: model.fundamentalsState == .loading, format: format)
    }

    @ViewBuilder
    private var cryptoStats: some View {
        if let c = model.coin {
            DetailKeyStats(
                ranges: dayRange24h(c),
                primary: [
                    StatItem(label: "Market cap", value: c.marketCap.map(format.compactMoney) ?? "—"),
                    StatItem(label: "24h volume", value: c.volume24h.map(format.compactMoney) ?? "—"),
                    StatItem(label: "Rank", value: c.rank.map { "#\($0)" } ?? "—"),
                    StatItem(label: "All-time high", value: c.allTimeHigh.map { $0 >= 10_000 ? format.compactMoney($0) : format.money($0) } ?? "—"),
                    StatItem(label: "Circulating", value: c.circulatingSupply.map { format.compactNumber($0) } ?? "—"),
                    StatItem(label: "Max supply", value: c.maxSupply.map { format.compactNumber($0) } ?? "No limit")
                ],
                more: [
                    c.fullyDilutedValuation.map { StatItem(label: "Fully diluted", value: format.compactMoney($0)) },
                    c.totalSupply.map { StatItem(label: "Total supply", value: format.compactNumber($0)) },
                    c.allTimeHighDate.map { StatItem(label: "ATH date", value: $0.formatted(.dateTime.day().month(.abbreviated).year())) }
                ].compactMap { $0 },
                format: format)
        } else {
            DetailKeyStats(
                caption: model.coinState == .failed ? "Coin figures couldn't be loaded right now." : nil,
                ranges: [],
                primary: [
                    StatItem(label: "Market cap", value: "—"),
                    StatItem(label: "24h volume", value: live.volume > 0 ? format.compactMoney(live.volume) : "—")
                ],
                isLoading: model.coinState == .loading,
                format: format)
        }
    }

    private func dayRange24h(_ c: CoinFacts) -> [RangeItem] {
        guard let lo = c.low24h, let hi = c.high24h, hi > lo, live.price > 0 else { return [] }
        return [RangeItem(label: "24-hour range", low: min(lo, live.price), high: max(hi, live.price), current: live.price)]
    }

    // MARK: About

    @ViewBuilder
    private var about: some View {
        switch kind {
        case .usStock:
            let s = model.stock
            let facts = usFacts(s)
            if s.companyDescription?.isEmpty == false || !facts.isEmpty {
                DetailAboutSection(title: "About", text: s.companyDescription, facts: facts)
            }
        case .crypto:
            if let c = model.coin, c.about != nil || c.homepage != nil {
                DetailAboutSection(
                    title: "About \(c.name)",
                    text: c.about,
                    facts: c.homepage.map { [AboutFact(label: "Website", value: $0.host() ?? $0.absoluteString, link: $0)] } ?? [])
            }
        case .index:
            if let text = Self.indexDescriptions[live.symbol.uppercased()] {
                DetailAboutSection(title: "About", text: text, facts: [])
            }
        case .asxStock, .otherStock:
            EmptyView()
        }
    }

    private func usFacts(_ s: DetailedStock) -> [AboutFact] {
        var facts: [AboutFact] = []
        if let v = s.sector, !v.isEmpty { facts.append(AboutFact(label: "Sector", value: v)) }
        if let v = s.industry, !v.isEmpty { facts.append(AboutFact(label: "Industry", value: v)) }
        if let v = s.ceo, !v.isEmpty { facts.append(AboutFact(label: "CEO", value: v)) }
        if let raw = s.employees, let n = Double(raw.replacingOccurrences(of: ",", with: "")), n > 0 {
            facts.append(AboutFact(label: "Employees", value: format.wholeNumber(n)))
        }
        if let date = StockInsightService.day(s.ipoDate) {
            facts.append(AboutFact(label: "Listed since", value: date.formatted(.dateTime.month(.abbreviated).year())))
        }
        if let raw = s.website, !raw.isEmpty, let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") {
            facts.append(AboutFact(label: "Website", value: url.host() ?? raw, link: url))
        }
        return facts
    }

    static let indexDescriptions: [String: String] = [
        "^GSPC": "The S&P 500 tracks 500 of the largest companies listed in the US, weighted by market value. It's the most common yardstick for the US stock market.",
        "^IXIC": "The Nasdaq Composite tracks almost every stock listed on the Nasdaq exchange, so it leans heavily towards technology companies.",
        "^DJI": "The Dow Jones Industrial Average follows 30 large US companies and is weighted by share price rather than company size.",
        "^AXJO": "The S&P/ASX 200 tracks the 200 largest companies listed on the Australian Securities Exchange, weighted by market value."
    ]

    private var sourcesText: String {
        var text: String
        switch kind {
        case .usStock:
            text = "Prices from Alpaca (IEX); volume from Yahoo Finance. Company figures from Financial Modeling Prep and Finnhub; analyst ratings and earnings from Finnhub and FMP."
        case .asxStock:
            text = "Prices, volume and dividends from Yahoo Finance; prices may be delayed by up to 20 minutes."
        case .otherStock:
            text = "Prices from Yahoo Finance."
        case .crypto:
            text = "Prices and coin figures from CoinGecko."
        case .index:
            text = "Index levels from Yahoo Finance, in points."
        }
        if kind != .index && marketData.preferredCurrency != "USD" {
            text += " Shown in \(marketData.preferredCurrency) at today's exchange rate."
        }
        return text + " Not investment advice."
    }
}

// MARK: - Sheet / toast models

enum DetailSheet: Identifiable {
    case alert, portfolio, broker
    case paywall(String)
    case research(Instrument, URL)

    var id: String {
        switch self {
        case .alert: return "alert"
        case .portfolio: return "portfolio"
        case .broker: return "broker"
        case .research(let instrument, _): return "research-\(instrument.id)"
        case .paywall(let feature): return "paywall-\(feature)"
        }
    }
}

struct DetailToast: Equatable {
    let id = UUID()
    let text: String
    let icon: String
}

// MARK: - View model

@MainActor
final class AssetDetailViewModel: ObservableObject {
    enum ChartStyle: String { case line, candle }
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    let seed: Asset
    let kind: DetailAssetKind

    @Published private(set) var stock: DetailedStock
    @Published private(set) var refreshedQuote: Asset?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var ownQuoteFailed = false

    @Published var range: TimeRange = .oneDay {
        didSet {
            guard oldValue != range else { return }
            loadChart()
            if style == .candle { loadCandles() }
        }
    }
    @Published var style: ChartStyle {
        didSet {
            guard oldValue != style else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            if style == .candle { loadCandles() }
        }
    }

    // Line chart
    @Published private(set) var points: [PricePoint] = []
    @Published private(set) var pointsRange: TimeRange?
    @Published private(set) var chartPhase: DSChartPhase = .loading
    // Candles
    @Published private(set) var candles: [Candle] = []
    @Published private(set) var candlesRange: TimeRange?
    @Published private(set) var candlePhase: DSChartPhase = .loading
    // Facts
    @Published private(set) var fundamentalsState: LoadState = .idle
    /// FMP didn't answer; key stats came from Finnhub alone.
    @Published private(set) var fundamentalsUsedFallback = false
    @Published private(set) var listingFacts: YahooListingFacts?
    @Published private(set) var nextEarnings: EarningsEvent?
    @Published private(set) var insight: StockInsight?
    @Published private(set) var insightState: LoadState = .idle
    @Published private(set) var coin: CoinFacts?
    @Published private(set) var coinState: LoadState = .idle
    @Published private(set) var statements: FinancialStatements?
    @Published private(set) var statementsState: LoadState = .idle

    private static let styleKey = "detailChartStyle"
    private static let slowAfter: Double = 15
    private var chartToken = UUID()
    private var chartTask: Task<Void, Never>?
    private var candleTask: Task<Void, Never>?
    private var started = false

    init(seed: Asset, stock: DetailedStock) {
        self.seed = seed
        self.kind = DetailAssetKind(seed)
        var base = stock
        // US quotes come from Alpaca's IEX feed, which sees a few percent of the
        // day's volume; only FMP's consolidated figure is shown.
        if DetailAssetKind(seed) == .usStock { base.volume = 0 }
        self.stock = base
        let saved = UserDefaults.standard.string(forKey: Self.styleKey)
        self.style = (saved == ChartStyle.candle.rawValue && seed.kind == .stock) ? .candle : .line
    }

    deinit {
        chartTask?.cancel()
        candleTask?.cancel()
    }

    /// The best quote we have when the asset isn't tracked by MarketData.
    var quote: Asset { refreshedQuote ?? seed }

    /// Same instrument: symbol, kind and market (ASX "BHP" is not NYSE "BHP").
    func matches(_ other: Asset) -> Bool {
        other.symbol.uppercased() == seed.symbol.uppercased()
            && other.kind == seed.kind
            && QuoteService.isASX(other) == QuoteService.isASX(seed)
    }

    func trackedAsset(in data: MarketData) -> Asset? {
        if let h = data.portfolio.first(where: { matches($0.asset) }), h.asset.price > 0 { return h.asset }
        let pool = seed.kind == .crypto ? data.crypto : data.stocks
        if let a = pool.first(where: matches), a.price > 0 { return a }
        if let a = data.watchlist.first(where: matches), a.price > 0 { return a }
        return nil
    }

    // MARK: Lifecycle

    func start(isTracked: Bool, candlesAllowed: Bool) async {
        guard !started else { return }
        started = true
        if !candlesAllowed && style == .candle { style = .line }
        loadChart()
        if style == .candle { loadCandles() }
        async let a: Void = loadFundamentals()
        async let b: Void = loadInsight()
        async let c: Void = loadCoin()
        async let d: Void = refreshQuote(skip: isTracked)
        async let e: Void = loadNextEarnings()
        _ = await (a, b, c, d, e)
    }

    func refresh() async {
        loadChart(force: true)
        if style == .candle { loadCandles(force: true) }
        await refreshQuote()
        if kind == .crypto { await loadCoin() }
    }

    // MARK: Charts

    func loadChart(force: Bool = false) {
        chartTask?.cancel()
        let requested = range
        let token = UUID()
        chartToken = token
        if pointsRange != requested || points.isEmpty || force { chartPhase = .loading }
        let asset = seed
        chartTask = Task { [weak self] in
            do {
                let pts = try await PriceHistoryService.shared.history(for: asset, range: requested, forceRefresh: force)
                guard let self, !Task.isCancelled, self.range == requested else { return }
                self.points = pts
                self.pointsRange = requested
                self.chartPhase = .loaded
            } catch {
                guard let self, !Task.isCancelled, self.range == requested else { return }
                if self.pointsRange != requested {
                    self.points = []
                    self.pointsRange = requested
                }
                self.chartPhase = self.points.isEmpty ? .failed(Self.message(for: error)) : .loaded
                AppLogger.api.warning("Detail chart \(asset.symbol) \(requested.rawValue) failed: \(error.localizedDescription)")
            }
        }
        // Rate-limited sources (keyless CoinGecko backs off for minutes) shouldn't
        // leave a spinner up indefinitely; say so and keep listening for the reply.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.slowAfter))
            guard let self, self.chartToken == token, self.chartPhase == .loading,
                  self.pointsRange != requested || self.points.isEmpty else { return }
            self.chartPhase = .failed("The price source is busy. Try again in a minute.")
        }
    }

    func loadCandles(force: Bool = false) {
        guard seed.kind == .stock else { return }
        candleTask?.cancel()
        let requested = range
        if candlesRange != requested || candles.isEmpty || force { candlePhase = .loading }
        let asset = seed
        candleTask = Task { [weak self] in
            do {
                let result = try await PriceHistoryService.shared.candles(for: asset, range: requested)
                guard let self, !Task.isCancelled, self.range == requested else { return }
                self.candles = result
                self.candlesRange = requested
                self.candlePhase = .loaded
            } catch {
                guard let self, !Task.isCancelled, self.range == requested else { return }
                self.candles = []
                self.candlesRange = requested
                self.candlePhase = .failed(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "You're offline."
        }
        return "Price history for this period isn't available right now."
    }

    // MARK: Facts

    private func loadFundamentals() async {
        switch kind {
        case .usStock: await loadUSFundamentals()
        case .asxStock, .otherStock: await loadListingFacts()
        case .crypto, .index: return
        }
    }

    /// FMP (richest, 250 calls/day free) and Finnhub (60/min, free) in parallel;
    /// Finnhub only fills what FMP left empty, so key stats survive FMP's quota running out.
    private func loadUSFundamentals() async {
        fundamentalsState = .loading
        let symbol = seed.symbol.uppercased()
        let hasFMP = MarketDataProxy.available(debugKey: SecretsConfig.fmpAPIKey)
        async let p = hasFMP ? FMPService.shared.fetchProfile(symbol: symbol) : nil
        async let q = hasFMP ? FMPService.shared.fetchQuote(symbol: symbol) : nil
        async let r = hasFMP ? FMPService.shared.fetchRatios(symbol: symbol) : nil
        async let i = hasFMP ? FMPService.shared.fetchIncomeStatements(symbol: symbol, limit: 4) : []
        async let f = try? APIService.shared.fetchFinnhubFundamentals(symbol: symbol)
        // Consolidated volume + day range (Alpaca's free IEX feed sees a few % of volume).
        async let y = try? APIService.shared.fetchYahooListingFacts(symbol: symbol)
        let (profile, fmpQuote, ratios, income, finnhub, yahoo) = await (p, q, r, i, f, y)
        let fmpAnswered = profile != nil || fmpQuote != nil || ratios != nil || !income.isEmpty
        guard fmpAnswered || finnhub != nil || yahoo != nil else {
            fundamentalsState = .failed
            return
        }
        var updated = stock
        if fmpAnswered {
            updated = DetailedStock.applying(profile: profile, quote: fmpQuote, ratios: ratios,
                                             incomeStatements: income, to: updated)
        }
        if let finnhub { updated = DetailedStock.filling(from: finnhub, to: updated) }
        if let yahoo {
            if updated.volume <= 0, let v = yahoo.volume { updated.volume = Int(v) }
            if updated.avgVolume <= 0, let v = yahoo.avgVolume3M { updated.avgVolume = Int(v) }
            if updated.dayHigh == nil, updated.dayLow == nil, let hi = yahoo.dayHigh, let lo = yahoo.dayLow {
                updated.dayHigh = hi
                updated.dayLow = lo
            }
        }
        stock = updated
        fundamentalsUsedFallback = !fmpAnswered
        fundamentalsState = .loaded
    }

    /// ASX/other Yahoo listings: day range, volume, 3-month average, dividends.
    private func loadListingFacts() async {
        fundamentalsState = .loading
        let symbol = kind == .asxStock ? QuoteService.finnhubASXSymbol(for: seed.symbol) : seed.symbol
        if let facts = try? await APIService.shared.fetchYahooListingFacts(symbol: symbol) {
            listingFacts = facts
            fundamentalsState = .loaded
        } else {
            fundamentalsState = .failed
        }
    }

    private func loadNextEarnings() async {
        guard kind == .usStock else { return }
        nextEarnings = await EarningsCalendar.shared.next(for: seed.symbol)
    }

    private func loadInsight() async {
        guard kind == .usStock else { return }
        insightState = .loading
        let result = await StockInsightService.shared.insight(for: seed.symbol)
        insight = result
        insightState = result.isEmpty ? .failed : .loaded
    }

    private func loadCoin() async {
        guard kind == .crypto, let id = QuoteService.coinGeckoID(for: seed.symbol) else { return }
        if coin == nil { coinState = .loading }
        Task { [weak self] in
            // Keyless CoinGecko can back off for minutes; don't leave skeletons up.
            try? await Task.sleep(for: .seconds(Self.slowAfter))
            guard let self, self.coin == nil, self.coinState == .loading else { return }
            self.coinState = .failed
        }
        do {
            coin = try await CoinGeckoCoinService.shared.facts(for: id)
            coinState = .loaded
        } catch {
            if coin == nil { coinState = .failed }
        }
    }

    func loadStatements() async {
        guard kind == .usStock, statementsState != .loading, statements?.isEmpty != false else { return }
        statementsState = .loading
        let result = await StockInsightService.shared.statements(for: seed.symbol)
        statements = result
        statementsState = result.isEmpty ? .failed : .loaded
    }

    /// Prices an asset nobody tracks (opened from search or an index card).
    private func refreshQuote(skip: Bool = false) async {
        guard !skip else { return }
        let current = quote
        let service = QuoteService()
        var fresh: Asset?
        switch kind {
        case .index:
            if let api = try? await APIService.shared.fetchYahooQuote(symbol: seed.symbol, name: seed.name) {
                fresh = service.mergedAsset(old: current, api: api)
            }
        case .crypto:
            fresh = await service.refreshCryptoPrices(for: [current]).first
        case .usStock, .asxStock, .otherStock:
            fresh = await service.refreshStockQuotes(for: [current]).first
        }
        ownQuoteFailed = service.lastFailedSymbols.contains(seed.symbol) || (kind == .index && fresh == nil)
        if let fresh, fresh.price > 0, !ownQuoteFailed {
            refreshedQuote = fresh
            refreshedAt = Date()
        }
    }
}
