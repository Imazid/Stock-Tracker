//
//  AssetDetailView.swift
//  Stock Tracker
//

import SwiftUI
import Charts
import Combine

struct AppleStocksDetailView: View {
    let asset: Asset?
    let position: StockPosition?

    /// Always reads the live (possibly FMP-enriched) stock from the ViewModel.
    private var stock: DetailedStock { viewModel.liveStock }

    @StateObject private var viewModel: AssetDetailViewModel
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var alertManager: PriceAlertManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    @State private var scrollOffset: CGFloat = 0
    @State private var showStickyHeader = false
    @State private var scrubbedPoint: ChartDataPoint?
    @State private var showPaywall = false
    @State private var showAlertSheet = false
    @State private var selectedTab: DetailedStockTab = .overview
    @StateObject private var insightService = StockInsightService.shared

    private var hasActiveAlert: Bool {
        alertManager.alerts.contains { $0.symbol == stock.symbol && $0.isActive }
    }

    /// Candlestick toggle is shown only for stocks (not crypto)
    private var isCryptoAsset: Bool { asset?.kind == .crypto }

    init(stock: DetailedStock, asset: Asset? = nil, position: StockPosition? = nil) {
        self.asset = asset
        self.position = position
        self._viewModel = StateObject(wrappedValue: AssetDetailViewModel(stock: stock, asset: asset))
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    scrollContent
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showStickyHeader = value < -100
                    }
                }
                .onAppear {
                    Task { await insightService.fetchInsight(for: stock.symbol, currentPrice: stock.currentPrice) }
                }
                .onChange(of: selectedTab) { _, _ in
                    Task { await insightService.fetchInsight(for: stock.symbol, currentPrice: stock.currentPrice) }
                }

                if showStickyHeader {
                    StickyHeaderView(stock: stock)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background((colorScheme == .dark ? Color(red: 0.03, green: 0.03, blue: 0.03) : Color(red: 0.98, green: 0.97, blue: 0.96)).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Candlestick Charts")
                    .environmentObject(SubscriptionManager.shared)
            }
            .onChange(of: viewModel.isLoadingFMPData) { _, newValue in
                // When FMP fetch completes, backfill dividend yield to Asset model
                if !newValue, let dy = viewModel.liveStock.dividendYield, dy > 0 {
                    marketData.updateAssetDividend(symbol: viewModel.liveStock.symbol, yieldPercent: dy * 100)
                }
            }
            .sheet(isPresented: $showAlertSheet) {
                AddPriceAlertSheet(stock: stock)
                    .environmentObject(alertManager)
                    .environmentObject(subscriptions)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // Bell: price alerts
                        Button {
                            showAlertSheet = true
                        } label: {
                            Image(systemName: hasActiveAlert ? "bell.fill" : "bell")
                                .font(.body.weight(.semibold))
                                .foregroundColor(hasActiveAlert ? .orange : .primary)
                        }

                        // Share
                        ShareLink(
                            item: "\(stock.symbol) (\(stock.name)) — \(stock.currentPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)) \(String(format: "%+.2f%%", stock.dayChangePercent)) today"
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Scroll Content

    @ViewBuilder
    private var scrollContent: some View {
        VStack(spacing: 0) {
            mainHeaderSection
                .padding(.top, 20)
                .padding(.horizontal)
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("scroll")).minY
                    )
                })

            if !isCryptoAsset {
                chartTypeToggle
                    .padding(.horizontal)
                    .padding(.top, 12)
            }

            InteractivePriceChart(
                selectedRange: $viewModel.selectedTimeRange,
                chartType: $viewModel.chartType,
                chartData: viewModel.chartData,
                candleData: viewModel.candleData,
                isLoadingCandles: viewModel.isLoadingCandles,
                stock: stock,
                isLive: viewModel.isLive,
                scrubbedPoint: $scrubbedPoint
            )
            .frame(height: 330)
            .clipped()
            .padding(.vertical, 20)
            .onDisappear { viewModel.stopLiveCandleUpdates() }

            if let position = position {
                PositionSection(stock: stock, position: position)
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }

            // MARK: - Tab Bar
            DetailedStockTabBar(selectedTab: $selectedTab)
                .padding(.top, 8)

            Divider()

            // MARK: - Tab Content
            tabContentView
                .padding(.bottom, 100)
        }
    }

    // MARK: - Expandable Sections Stack

    @ViewBuilder
    private var expandableSections: some View {
        VStack(spacing: 12) {
            ExpandableStatsSection(
                title: "Valuation",
                icon: "chart.bar.fill",
                isExpanded: $viewModel.valuationExpanded
            ) {
                ValuationMetrics(stock: stock)
            }

            ExpandableStatsSection(
                title: "Financial Health",
                icon: "heart.text.square.fill",
                isExpanded: $viewModel.financialHealthExpanded
            ) {
                FinancialHealthMetrics(stock: stock)
            }

            ExpandableStatsSection(
                title: "Growth",
                icon: "arrow.up.right",
                isExpanded: $viewModel.growthExpanded
            ) {
                GrowthMetrics(stock: stock)
            }

            if stock.dividendYield != nil {
                ExpandableStatsSection(
                    title: "Dividends",
                    icon: "dollarsign.circle.fill",
                    isExpanded: $viewModel.dividendsExpanded
                ) {
                    DividendMetrics(stock: stock)
                }
            }

            ExpandableStatsSection(
                title: "Risk & Volatility",
                icon: "waveform.path.ecg",
                isExpanded: $viewModel.riskExpanded
            ) {
                RiskMetrics(stock: stock)
            }

            if !isCryptoAsset && analystTotal > 0 {
                AnalystConsensusCard(stock: stock)
            }

            if !isCryptoAsset {
                let insight = insightService.insights[stock.symbol]
                EarningsHistoryCard(stock: stock, earningsEntries: insight?.earnings ?? [])
            }
        }
    }

    private var analystTotal: Int {
        (stock.analystStrongBuy ?? 0)
            + (stock.analystBuy ?? 0)
            + (stock.analystHold ?? 0)
            + (stock.analystSell ?? 0)
            + (stock.analystStrongSell ?? 0)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContentView: some View {
        let insight = insightService.insights[stock.symbol]
        let isLoading = insightService.loadingSymbols.contains(stock.symbol)
        switch selectedTab {
        case .overview:
            OverviewTabView(stock: stock, insight: insight, isLoading: isLoading)
        case .financials:
            FinancialsTabView(insight: insight, isLoading: isLoading, stock: stock)
        case .earnings:
            EarningsTabView(stock: stock, insight: insight, isLoading: isLoading)
        case .holders:
            HoldersTabView(insight: insight, isLoading: isLoading)
        case .analysis:
            AnalysisTabView(stock: stock, insight: insight, isLoading: isLoading)
        }
    }

    // MARK: - Chart Type Toggle

    private var chartTypeToggle: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                // Line
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        viewModel.chartType = .line
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Line")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(viewModel.chartType == .line
                        ? Color.secondary.opacity(0.2) : Color.clear)
                    .foregroundColor(viewModel.chartType == .line ? .primary : .secondary)
                    .cornerRadius(9)
                }

                // Candle (Pro-gated)
                Button {
                    if subscriptions.currentTier == .free {
                        showPaywall = true
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            viewModel.chartType = .candle
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Candle")
                            .font(.caption.weight(.medium))
                        if subscriptions.currentTier == .free {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(viewModel.chartType == .candle
                        ? Color.secondary.opacity(0.2) : Color.clear)
                    .foregroundColor(viewModel.chartType == .candle ? .primary : .secondary)
                    .cornerRadius(9)
                }
            }
            .padding(3)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    // MARK: - Main Header Section
    private var displayPrice: Double { scrubbedPoint?.price ?? stock.currentPrice }

    private var mainHeaderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Symbol and Exchange
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stock.symbol)
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                ExchangeBadge(exchange: stock.exchange)
            }

            // Company Name
            Text(stock.name)
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer().frame(height: 8)

            // Price — updates live while scrubbing the chart
            Text(displayPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.08), value: displayPrice)

            // Scrubbing: show the hovered date. At rest: show day change.
            if let point = scrubbedPoint {
                Text(point.date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: stock.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.body.weight(.semibold))

                    Text((stock.dayChange >= 0 ? "+" : "") + stock.dayChange.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.title3.weight(.semibold))

                    Text("(\(String(format: stock.isPositive ? "+%.2f%%" : "%.2f%%", stock.dayChangePercent)))")
                        .font(.title3.weight(.semibold))
                }
                .foregroundColor(stock.isPositive ? appTheme.positiveColor : appTheme.negativeColor)
                .transition(.opacity)
            }

            // Pre/After Market (if available)
            if let preMarket = stock.preMarketPrice {
                HStack(spacing: 6) {
                    Text("Pre-Market:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(preMarket.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.caption.weight(.semibold))
                }
            }

            if let afterHours = stock.afterHoursPrice {
                HStack(spacing: 6) {
                    Text("After Hours:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(afterHours.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Scroll Offset Preference Key
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Asset Detail ViewModel
@MainActor
class AssetDetailViewModel: ObservableObject {
    @Published var liveStock: DetailedStock
    let asset: Asset?
    private let quoteService = QuoteService()

    @Published var selectedTimeRange: ChartTimeRange = .oneDay {
        didSet {
            stopLiveCandleUpdates()
            candleData = []  // invalidate stale candles on range change
            loadChartData()
            if chartType == .candle { loadCandleData() }
        }
    }

    @Published var chartType: ChartDisplayType {
        didSet {
            if chartType == .candle && candleData.isEmpty {
                loadCandleData()
            } else if chartType != .candle {
                stopLiveCandleUpdates()
            }
            UserDefaults.standard.set(chartType.rawValue, forKey: "defaultChartType")
        }
    }

    @Published var chartData: [ChartDataPoint] = [] {
        didSet {
            // If candle mode is active but candles are still empty (API failed or
            // the candle task finished before chart data arrived), fill in synthetic candles.
            if chartType == .candle && candleData.isEmpty && !chartData.isEmpty && !isLoadingCandles {
                candleData = syntheticCandles(from: chartData)
            }
        }
    }
    @Published var candleData: [Candle] = []
    @Published var isLoadingChart = false
    @Published var isLoadingCandles = false
    @Published var isLive = false

    private var candleRefreshTask: Task<Void, Never>?

    @Published var valuationExpanded = false
    @Published var financialHealthExpanded = false
    @Published var growthExpanded = false
    @Published var dividendsExpanded = false
    @Published var riskExpanded = false
    @Published var companyExpanded = false
    @Published var isLoadingFMPData = false

    init(stock: DetailedStock, asset: Asset? = nil) {
        self.liveStock = stock
        self.asset = asset
        let saved = UserDefaults.standard.string(forKey: "defaultChartType") ?? "line"
        self.chartType = (saved == "candle") ? .candle : .line
        loadChartData()
        if self.chartType == .candle { loadCandleData() }
        if asset?.kind == .stock {
            Task { await self.fetchFMPData() }
        }
    }

    func loadChartData() {
        guard let asset = asset else {
            chartData = generateMockChartData(for: selectedTimeRange, currentPrice: liveStock.currentPrice)
            return
        }
        isLoadingChart = true
        Task {
            let range = selectedTimeRange.toTimeRange
            let points = await quoteService.fetchPriceHistory(for: asset, range: range)
            chartData = points.map { ChartDataPoint(date: $0.date, price: $0.price, volume: nil) }
            isLoadingChart = false
        }
    }

    func loadCandleData() {
        guard let asset = asset, asset.kind == .stock else { return }
        isLoadingCandles = true
        Task {
            let fetched = try? await quoteService.fetchHistoricalData(
                symbol: asset.symbol,
                range: selectedTimeRange.toTimeRange
            )
            if let candles = fetched, !candles.isEmpty {
                candleData = candles
            } else {
                // Fallback: synthesise OHLCV candles from the line chart points
                // so the chart is never blank after loading completes.
                candleData = syntheticCandles(from: chartData)
            }
            isLoadingCandles = false
            startLiveCandleUpdates()
        }
    }

    // MARK: - Live Candle Updates

    func startLiveCandleUpdates() {
        guard asset?.kind == .stock,
              selectedTimeRange == .oneDay,
              chartType == .candle else { return }
        stopLiveCandleUpdates()
        isLive = true
        candleRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard !Task.isCancelled, let self else { break }
                guard let symbol = self.asset?.symbol else { break }
                if let latest = await self.quoteService.fetchLatestCandle(symbol: symbol, intervalMinutes: 5) {
                    self.applyLatestCandle(latest)
                }
            }
        }
    }

    func stopLiveCandleUpdates() {
        candleRefreshTask?.cancel()
        candleRefreshTask = nil
        if isLive { isLive = false }
    }

    private func applyLatestCandle(_ latest: Candle) {
        guard !candleData.isEmpty else { return }
        let interval: TimeInterval = 5 * 60  // 5-minute bucket
        let lastDate = candleData[candleData.count - 1].date
        // If within the same 5-min bucket, replace in-place; otherwise append
        if abs(latest.date.timeIntervalSince(lastDate)) < interval {
            candleData[candleData.count - 1] = Candle(
                date: lastDate,
                open: candleData[candleData.count - 1].open,
                high: max(candleData[candleData.count - 1].high, latest.high),
                low: min(candleData[candleData.count - 1].low, latest.low),
                close: latest.close,
                volume: latest.volume
            )
        } else {
            candleData.append(latest)
        }
        liveStock.currentPrice = latest.close
    }

    // MARK: - FMP Company Data

    private func fetchFMPData() async {
        guard let asset = asset else { return }
        isLoadingFMPData = true
        async let profileTask           = FMPService.shared.fetchProfile(symbol: asset.symbol)
        async let quoteTask             = FMPService.shared.fetchQuote(symbol: asset.symbol)
        async let ratiosTask            = FMPService.shared.fetchRatios(symbol: asset.symbol)
        async let incomeStatementsTask  = FMPService.shared.fetchIncomeStatements(symbol: asset.symbol, limit: 8)
        async let analystEstimatesTask  = FMPService.shared.fetchAnalystEstimates(symbol: asset.symbol)
        async let analystRatingTask     = FMPService.shared.fetchAnalystRating(symbol: asset.symbol)
        let (profile, quote, ratios, incomeStatements, analystEstimates, analystRating) =
            await (profileTask, quoteTask, ratiosTask, incomeStatementsTask, analystEstimatesTask, analystRatingTask)
        if profile != nil || quote != nil || ratios != nil || !incomeStatements.isEmpty {
            liveStock = DetailedStock.applying(
                profile: profile,
                quote: quote,
                ratios: ratios,
                incomeStatements: incomeStatements,
                analystEstimates: analystEstimates,
                analystRating: analystRating,
                to: liveStock
            )
        }
        isLoadingFMPData = false
    }

    /// Converts line-chart points into approximate OHLCV candles with small realistic wicks.
    private func syntheticCandles(from points: [ChartDataPoint]) -> [Candle] {
        guard !points.isEmpty else { return [] }
        return points.map { pt in
            let spread = pt.price * 0.01
            let open   = pt.price - Double.random(in: 0...spread)
            let close  = pt.price
            let high   = max(open, close) + Double.random(in: 0...spread)
            let low    = min(open, close) - Double.random(in: 0...spread)
            return Candle(
                date:   pt.date,
                open:   max(0.01, open),
                high:   high,
                low:    max(0.01, low),
                close:  close,
                volume: pt.volume ?? 1_000_000
            )
        }
    }

    private func generateMockChartData(for range: ChartTimeRange, currentPrice: Double) -> [ChartDataPoint] {
        let count = range.dataPointCount
        let calendar = Calendar.current
        let now = Date()

        var points: [ChartDataPoint] = []
        var price = currentPrice * 0.95

        for i in 0..<count {
            let date = calendar.date(byAdding: range.dateComponent, value: -i, to: now)!
            price += Double.random(in: -currentPrice * 0.02...currentPrice * 0.02)
            price = max(price, currentPrice * 0.8)

            points.append(ChartDataPoint(
                date: date,
                price: price,
                volume: Double.random(in: 1_000_000...10_000_000)
            ))
        }

        return points.reversed()
    }
}

// MARK: - Company Overview Content

struct CompanyOverviewContent: View {
    let stock: DetailedStock
    @State private var showFullDescription = false

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 16) {

            // Sector / Industry chips
            if stock.sector != nil || stock.industry != nil {
                HStack(spacing: 8) {
                    if let sector = stock.sector {
                        Text(sector)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                    }
                    if let industry = stock.industry {
                        Text(industry)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.purple)
                            .cornerRadius(10)
                    }
                }
            }

            // Description
            if let desc = stock.companyDescription, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(showFullDescription ? nil : 3)
                    Button(showFullDescription ? "Show Less" : "Show More") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showFullDescription.toggle()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
                }
            }

            Divider().opacity(0.4)

            // Company facts
            VStack(spacing: 12) {
                if let ceo = stock.ceo {
                    DetailRow(label: "CEO", value: ceo)
                    Divider().opacity(0.4)
                }
                if let employees = stock.employees {
                    DetailRow(label: "Employees", value: employees)
                    Divider().opacity(0.4)
                }
                if let ipo = stock.ipoDate {
                    DetailRow(label: "IPO Date", value: ipo)
                    Divider().opacity(0.4)
                }
                if let website = stock.website, let url = URL(string: website) {
                    HStack {
                        Text("Website")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Link(website.replacingOccurrences(of: "https://", with: ""), destination: url)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}

// MARK: - Exchange Badge

struct ExchangeBadge: View {
    let exchange: String

    private var color: Color {
        switch exchange.uppercased() {
        case "NASDAQ":       return .blue
        case "NYSE":         return Color(red: 0.0, green: 0.55, blue: 0.3)
        case "AMEX", "NYSEAM": return .orange
        case "OTC", "OTCQB", "OTCQX": return .purple
        case "ASX":          return Color(red: 0.6, green: 0.1, blue: 0.1)
        default:             return .secondary
        }
    }

    var body: some View {
        Text(exchange)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .cornerRadius(6)
    }
}

// MARK: - Analyst Consensus Card

struct AnalystConsensusCard: View {
    let stock: DetailedStock

    @Environment(\.colorScheme) private var colorScheme

    private var total: Int {
        (stock.analystStrongBuy ?? 0)
            + (stock.analystBuy ?? 0)
            + (stock.analystHold ?? 0)
            + (stock.analystSell ?? 0)
            + (stock.analystStrongSell ?? 0)
    }

    private func fraction(for count: Int?) -> CGFloat {
        guard total > 0, let count = count, count > 0 else { return 0 }
        return CGFloat(count) / CGFloat(total)
    }

    private func consensusColor(_ consensus: String) -> Color {
        switch consensus.lowercased() {
        case "strong buy":  return Color(red: 0.0, green: 0.50, blue: 0.20)
        case "buy":         return .green
        case "hold", "neutral": return .orange
        case "sell":        return .red
        case "strong sell": return Color(red: 0.65, green: 0.0, blue: 0.0)
        default:            return .secondary
        }
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            // Header row
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analyst Ratings")
                        .font(.headline.weight(.semibold))
                    if let consensus = stock.analystConsensus, !consensus.isEmpty {
                        Text(consensus.capitalized)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(consensusColor(consensus))
                    }
                }
                Spacer()
                Text("\(total) analysts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Segmented rating bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if let sb = stock.analystStrongBuy, sb > 0 {
                        Capsule()
                            .fill(Color(red: 0.0, green: 0.50, blue: 0.20))
                            .frame(width: max(geo.size.width * fraction(for: sb), 4))
                    }
                    if let b = stock.analystBuy, b > 0 {
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(geo.size.width * fraction(for: b), 4))
                    }
                    if let h = stock.analystHold, h > 0 {
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: max(geo.size.width * fraction(for: h), 4))
                    }
                    if let s = stock.analystSell, s > 0 {
                        Capsule()
                            .fill(Color.red)
                            .frame(width: max(geo.size.width * fraction(for: s), 4))
                    }
                    if let ss = stock.analystStrongSell, ss > 0 {
                        Capsule()
                            .fill(Color(red: 0.65, green: 0.0, blue: 0.0))
                            .frame(width: max(geo.size.width * fraction(for: ss), 4))
                    }
                }
                .frame(height: 8)
            }
            .frame(height: 8)

            // Legend row
            HStack(alignment: .top, spacing: 0) {
                AnalystLegendItem(label: "Strong\nBuy",  count: stock.analystStrongBuy,  color: Color(red: 0.0, green: 0.50, blue: 0.20))
                Spacer()
                AnalystLegendItem(label: "Buy",          count: stock.analystBuy,         color: .green)
                Spacer()
                AnalystLegendItem(label: "Hold",         count: stock.analystHold,         color: .orange)
                Spacer()
                AnalystLegendItem(label: "Sell",         count: stock.analystSell,         color: .red)
                Spacer()
                AnalystLegendItem(label: "Strong\nSell", count: stock.analystStrongSell,  color: Color(red: 0.65, green: 0.0, blue: 0.0))
            }
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
    }
}

private struct AnalystLegendItem: View {
    let label: String
    let count: Int?
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(count ?? 0)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor((count ?? 0) > 0 ? color : .secondary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 44)
    }
}

// MARK: - Earnings History Card

struct EarningsHistoryCard: View {
    let stock: DetailedStock
    let earningsEntries: [EarningsEntry]
    @State private var showEPS = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var appTheme

    // Use insight entries (actual vs estimate) if available, else fall back to income statement data
    private var displayedEntries: [EarningsEntry] {
        if !earningsEntries.isEmpty {
            return Array(earningsEntries.prefix(5).reversed())
        }
        // Fallback: convert EarningsPeriod → EarningsEntry (no estimate data)
        return Array(stock.earningsHistory.prefix(5).reversed().compactMap { period -> EarningsEntry? in
            EarningsEntry(
                id: UUID(),
                quarter: period.label,
                date: "",
                revenueEst: 0,
                revenueActual: (period.revenue ?? 0) / 1_000_000_000,
                epsEst: 0,
                epsActual: period.eps ?? 0,
                priceMove1D: 0
            )
        })
    }

    private var hasEstimateData: Bool {
        displayedEntries.contains { $0.epsEst != 0 || $0.revenueEst != 0 }
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .center) {
                Text("Earnings")
                    .font(.title3.weight(.bold))

                Spacer()

                if hasEstimateData {
                    // Legend
                    HStack(spacing: 12) {
                        legendDot(color: .white.opacity(0.5), label: "Consensus EPS")
                    }
                }

                HStack(spacing: 2) {
                    earningsToggleButton(title: "EPS", isSelected: showEPS) { showEPS = true }
                    earningsToggleButton(title: "Revenue", isSelected: !showEPS) { showEPS = false }
                }
                .padding(3)
                .background(colorScheme == .dark ? Color(.systemGray5) : theme.cardBackground)
                .cornerRadius(10)
            }

            if displayedEntries.isEmpty {
                Text("No earnings data available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                // Bar chart
                earningsChart(theme: theme)
                    .frame(height: 180)
                    .animation(.easeInOut(duration: 0.25), value: showEPS)

                // Beat/Miss badges
                if hasEstimateData {
                    beatMissBadges(theme: theme)
                }
            }
        }
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
    }

    // MARK: - Chart

    private func earningsChart(theme: Theme) -> some View {
        Chart {
            ForEach(displayedEntries) { entry in
                if showEPS {
                    // Estimate bar (darker)
                    if entry.epsEst != 0 {
                        BarMark(
                            x: .value("Quarter", entry.quarter),
                            y: .value("EPS", entry.epsEst)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.4), Color.purple.opacity(0.25)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                        .position(by: .value("Type", "est"))
                    }

                    // Actual bar (brighter)
                    BarMark(
                        x: .value("Quarter", entry.quarter),
                        y: .value("EPS", entry.epsActual)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.9), Color.purple.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                    .position(by: .value("Type", "actual"))

                    // Consensus line (estimate level)
                    if entry.epsEst != 0 {
                        RuleMark(
                            xStart: .value("Quarter", entry.quarter),
                            xEnd: .value("Quarter", entry.quarter),
                            y: .value("EPS", entry.epsEst)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(.white.opacity(0.5))
                        .annotation(position: entry.id == displayedEntries.last?.id ? .top : .automatic) {
                            if entry.id == displayedEntries.last?.id {
                                VStack(spacing: 2) {
                                    Text(String(format: "%.2f Est.", entry.epsEst))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.2f Actual", entry.epsActual))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.purple)
                                }
                            }
                        }
                    }
                } else {
                    // Revenue estimate
                    if entry.revenueEst != 0 {
                        BarMark(
                            x: .value("Quarter", entry.quarter),
                            y: .value("Revenue", entry.revenueEst)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.25)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                        .position(by: .value("Type", "est"))
                    }

                    // Revenue actual
                    BarMark(
                        x: .value("Quarter", entry.quarter),
                        y: .value("Revenue", entry.revenueActual)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.9), Color.blue.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                    .position(by: .value("Type", "actual"))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(.separator).opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(showEPS ? String(format: "%.2f", v) : String(format: "$%.1fB", v))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Beat/Miss Badges

    private func beatMissBadges(theme: Theme) -> some View {
        HStack(spacing: 0) {
            ForEach(displayedEntries) { entry in
                let isBeat = showEPS ? entry.epsBeat : entry.revenueBeat
                let diff: Double = showEPS
                    ? entry.epsActual - entry.epsEst
                    : entry.revenueActual - entry.revenueEst
                let hasData = showEPS ? entry.epsEst != 0 : entry.revenueEst != 0

                if hasData {
                    VStack(spacing: 4) {
                        Text(isBeat ? "BEAT" : "MISS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isBeat ? appTheme.positiveColor : appTheme.negativeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isBeat ? appTheme.positiveColor : appTheme.negativeColor, lineWidth: 1)
                            )

                        if showEPS {
                            Text("by $\(String(format: "%.2f", abs(diff)))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text("by $\(String(format: "%.1f", abs(diff)))B")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Helpers

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 3)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private func earningsToggleButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.clear)
                .foregroundColor(isSelected ? .white : .secondary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chart Time Range
enum ChartTimeRange: String, CaseIterable {
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case oneYear = "1Y"
    case fiveYears = "5Y"
    case all = "All"

    var dataPointCount: Int {
        switch self {
        case .oneDay: return 78 // 5-min intervals
        case .oneWeek: return 70 // 30-min intervals
        case .oneMonth: return 30 // daily
        case .threeMonths: return 90
        case .oneYear: return 252
        case .fiveYears: return 1260
        case .all: return 2520
        }
    }

    var dateComponent: Calendar.Component {
        switch self {
        case .oneDay: return .minute
        case .oneWeek: return .hour
        default: return .day
        }
    }

    /// Maps to the shared TimeRange enum used by QuoteService.
    var toTimeRange: TimeRange {
        switch self {
        case .oneDay:      return .oneDay
        case .oneWeek:     return .oneWeek
        case .oneMonth:    return .oneMonth
        case .threeMonths: return .threeMonths
        case .oneYear:     return .oneYear
        case .fiveYears:   return .fiveYears
        case .all:         return .all
        }
    }
}
