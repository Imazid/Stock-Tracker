//
//  PortfolioTabViews.swift
//  Stock Tracker
//
//  Performance and Income segments of the Portfolio tab.
//
//  Performance (after Monarch / Origin on Mobbin): your holdings vs a
//  benchmark (S&P 500 via SPY, ASX 200 via STW), both as % change from the
//  start of the period, plus what moved the portfolio. The benchmark line is a
//  Black feature; everyone sees their own line. No mock data, ever.
//
//  Income estimates dividend income from trailing yields.
//

import SwiftUI
import Charts

// MARK: - Performance

struct PortfolioPerformanceTab: View {
    var onUpgrade: () -> Void = {}

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var authManager: SupabaseAuthManager
    @Environment(\.theme) private var theme
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @AppStorage("portfolioPerformanceRange") private var rangeRaw = TimeRange.oneYear.rawValue
    @AppStorage("portfolioBenchmark") private var benchmarkRaw = Benchmark.preferred.rawValue

    @State private var portfolioPoints: [PricePoint] = []
    @State private var benchmarkPoints: [PricePoint] = []
    @State private var phase: DSChartPhase = .loading
    @State private var benchmarkFailed = false
    @State private var loadedKey: String?
    @State private var benchmarkLoading = false
    @State private var contributionsLoading = true
    @State private var scrubDate: Date?
    @State private var contributions: [Contribution] = []

    static let ranges: [TimeRange] = [.oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .fiveYears]

    struct Contribution: Identifiable {
        let id: UUID
        let holding: PortfolioHolding
        let change: Double      // USD
        let percent: Double
    }

    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .oneYear }
    private var benchmark: Benchmark { Benchmark(rawValue: benchmarkRaw) ?? .sp500 }
    private var canCompare: Bool { subscriptionManager.currentTier == .black }

    private var loadKey: String {
        "\(rangeRaw)|\(benchmarkRaw)|\(canCompare)|" + marketData.portfolio
            .map { "\($0.asset.symbol):\($0.shares):\($0.asset.price)" }.joined(separator: ",")
    }

    // MARK: Normalised series (% from the common start)

    private struct PctPoint: Identifiable {
        let date: Date
        let pct: Double
        var id: Date { date }
    }

    private var commonStart: Date? {
        guard let p = portfolioPoints.first?.date else { return nil }
        guard canCompare, let b = benchmarkPoints.first?.date else { return p }
        return max(p, b)
    }

    private func normalised(_ points: [PricePoint]) -> [PctPoint] {
        guard let start = commonStart else { return [] }
        let trimmed = points.filter { $0.date >= start }
        guard let base = trimmed.first?.price, base > 0 else { return [] }
        return trimmed.map { PctPoint(date: $0.date, pct: ($0.price / base - 1) * 100) }
    }

    private var portfolioPct: [PctPoint] { normalised(portfolioPoints) }
    private var benchmarkPct: [PctPoint] { canCompare ? normalised(benchmarkPoints) : [] }

    private func value(in series: [PctPoint], at date: Date?) -> Double? {
        guard let date else { return series.last?.pct }
        return series.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.pct
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if authManager.authState == .signedIn, let userId = authManager.userId {
                PortfolioPerformanceLedger(userId: userId).id(userId)
            }
            comparisonCard
            contributionCard
            if !realisedItems.isEmpty { realisedCard }
        }
        .task(id: loadKey) { await load() }
    }

    private var comparisonCard: some View {
        let mine = loadedKey == loadKey ? portfolioPct : []
        let theirs = loadedKey == loadKey ? benchmarkPct : []
        let myValue = value(in: mine, at: scrubDate)
        let theirValue = value(in: theirs, at: scrubDate)

        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Return")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canCompare { benchmarkMenu }
            }

            VStack(alignment: .leading, spacing: 6) {
                legendLine(color: DS.accent, title: "Your holdings", pct: myValue, dashed: false)
                if canCompare {
                    if benchmarkLoading || loadedKey != loadKey {
                        DataRowSkeleton()
                            .loadingSkeleton("Loading benchmark")
                    } else if benchmarkFailed {
                        HStack(spacing: DS.Space.s) {
                            Text("\(benchmark.title) data unavailable")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                            Button("Try again") { Task { await load(force: true) } }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DS.accent)
                                .frame(minHeight: 44)
                        }
                    } else {
                        legendLine(color: theme.secondaryText, title: benchmark.title, pct: theirValue, dashed: true)
                    }
                }
                Text(scrubDate.map { range.scrubLabel(for: $0) } ?? differenceText(myValue, theirValue))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            chart(mine: mine, theirs: theirs)
                .frame(height: 220)

            DSRangePicker(options: Self.ranges,
                          selection: Binding(get: { range }, set: { rangeRaw = $0.rawValue }))

            if !canCompare {
                Button(action: onUpgrade) {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(theme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compare with the S&P 500 or ASX 200")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Text("Available on Black")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("portfolio.performance.unlock")
            }

            Text("Price return of what you hold now — dividends and sales aren't in this line\(realisedItems.isEmpty ? "" : " (sales are under Realised below)"). \(canCompare ? "\(benchmark.title) is tracked by \(benchmark.asset.symbol)." : "")")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
        .accessibilityIdentifier("portfolio.performance")
    }

    private var benchmarkMenu: some View {
        Menu {
            Picker("Benchmark", selection: $benchmarkRaw) {
                ForEach(Benchmark.allCases) { b in Text(b.title).tag(b.rawValue) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("vs \(benchmark.title)")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DS.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("portfolio.benchmark")
    }

    private func legendLine(color: Color, title: String, pct: Double?, dashed: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Capsule()
                .fill(color)
                .frame(width: 16, height: 3)
                .opacity(dashed ? 0.8 : 1)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(theme.primaryText)
            Spacer()
            Text(pct.map { formatPercent($0, signed: true) } ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(pct.map { $0 >= 0 ? theme.positiveColor : theme.negativeColor } ?? theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func differenceText(_ mine: Double?, _ theirs: Double?) -> String {
        guard let mine else { return range.periodLabelString }
        guard canCompare, let theirs else { return range.periodLabelString }
        let diff = mine - theirs
        return "\(range.periodLabelString): \(String(format: "%.1f", abs(diff))) points \(diff >= 0 ? "ahead of" : "behind") the \(benchmark.title)"
    }

    @ViewBuilder
    private func chart(mine: [PctPoint], theirs: [PctPoint]) -> some View {
        if loadedKey == loadKey, phase != .loading, mine.count >= 2 {
            Chart {
                RuleMark(y: .value("Start", 0))
                    .foregroundStyle(theme.secondaryText.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                ForEach(theirs) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Return", p.pct), series: .value("Series", "Benchmark"))
                        .foregroundStyle(theme.secondaryText)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                        .interpolationMethod(.linear)
                }
                ForEach(mine) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Return", p.pct), series: .value("Series", "Portfolio"))
                        .foregroundStyle(DS.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                if let scrubDate {
                    RuleMark(x: .value("Selected", scrubDate))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $scrubDate)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(theme.cardBorder.opacity(0.35))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%+.0f%%", v)).font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: range == .fiveYears ? .dateTime.year() : .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .sensoryFeedback(.selection, trigger: scrubDate)
            .accessibilityIdentifier("portfolio.performance.chart")
        } else {
            DSPriceChart(points: [], phase: loadedKey == loadKey ? phase : .loading, onRetry: { Task { await load(force: true) } },
                         accessibilityID: "portfolio.performance.chart")
        }
    }

    // MARK: Contribution

    private var contributionCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("What moved it")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(range.periodLabelString)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            if contributionsLoading || loadedKey != loadKey {
                VStack(spacing: 0) {
                    ForEach(0..<3) { _ in DataRowSkeleton() }
                }
                .loadingSkeleton("Loading performance contributors")
            } else if contributions.isEmpty {
                Text("No price history for this period.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, DS.Space.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(contributions) { c in
                        HStack(spacing: DS.Space.m) {
                            TickerLogo(symbol: c.holding.asset.symbol, kind: c.holding.asset.kind,
                                       exchange: c.holding.asset.exchange, size: 32)
                            Text(c.holding.asset.symbol)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(valueHidden ? "••••" : marketData.signedMoney(c.change))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(c.change >= 0 ? theme.positiveColor : theme.negativeColor)
                                Text(formatPercent(c.percent, signed: true))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        .padding(.vertical, DS.Space.s)
                        .accessibilityElement(children: .combine)
                        if c.id != contributions.last?.id { Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 44) }
                    }
                }
            }
        }
        .dsCard()
        .accessibilityIdentifier("portfolio.contributions")
    }

    // MARK: Realised

    private struct RealisedItem: Identifiable {
        let id: UUID
        let asset: Asset
        let gain: Double        // USD
        let detail: String
    }

    /// Holdings with sales, then closed positions — each with the profit its sales banked.
    private var realisedItems: [RealisedItem] {
        let open = marketData.portfolio.compactMap { h -> RealisedItem? in
            let sells = h.ledger.sellCount
            guard sells > 0 else { return nil }
            return RealisedItem(id: h.id, asset: h.asset, gain: h.realizedGain,
                                detail: sells == 1 ? "1 sale · still held" : "\(sells) sales · still held")
        }
        let closed = marketData.closedPositions.map { c in
            RealisedItem(id: c.id, asset: c.asset, gain: c.realizedGain,
                         detail: "Closed \(c.closedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return open + closed
    }

    private var realisedCard: some View {
        let total = marketData.totalRealizedGain
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Realised from sales")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(valueHidden ? "••••" : marketData.signedMoney(total))
                .font(DS.money(28, weight: .bold))
                .foregroundStyle(total >= 0 ? theme.positiveColor : theme.negativeColor)
                .accessibilityIdentifier("portfolio.realised.total")
            VStack(spacing: 0) {
                ForEach(realisedItems) { item in
                    HStack(spacing: DS.Space.m) {
                        TickerLogo(symbol: item.asset.symbol, kind: item.asset.kind, exchange: item.asset.exchange, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.asset.symbol).font(.subheadline.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        Text(valueHidden ? "••••" : marketData.signedMoney(item.gain))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(item.gain >= 0 ? theme.positiveColor : theme.negativeColor)
                    }
                    .padding(.vertical, DS.Space.s)
                    .accessibilityElement(children: .combine)
                    if item.id != realisedItems.last?.id { Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 44) }
                }
            }
            Text("Sale price minus your average cost at the time, after fees. Already counted in Total return.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
        .accessibilityIdentifier("portfolio.realised")
    }

    // MARK: Data

    private func load(force: Bool = false) async {
        let holdings = marketData.portfolio
        guard !holdings.isEmpty else { return }
        let key = loadKey
        let requestedRange = range
        let requestedBenchmark = benchmark
        let compare = canCompare
        phase = .loading
        benchmarkLoading = compare
        contributionsLoading = true
        portfolioPoints = []
        benchmarkPoints = []
        contributions = []
        loadedKey = key
        scrubDate = nil
        let value = marketData.totalPortfolioValue
        let service = PriceHistoryService.shared

        do {
            let series = try await service.portfolioSeries(holdings: holdings, range: requestedRange, liveValue: value,
                                                           previousCloseValue: value - marketData.dailyProfitLoss,
                                                           forceRefresh: force)
            guard !Task.isCancelled, loadKey == key else { return }
            portfolioPoints = series.points
            phase = .loaded
        } catch {
            guard !Task.isCancelled, loadKey == key else { return }
            portfolioPoints = []
            phase = .failed("Prices for your holdings couldn't be loaded.")
        }

        if compare {
            do {
                let points = try await service.history(for: requestedBenchmark.asset, range: requestedRange, forceRefresh: force)
                guard !Task.isCancelled, loadKey == key else { return }
                benchmarkPoints = points
                benchmarkFailed = points.count < 2
            } catch {
                guard !Task.isCancelled, loadKey == key else { return }
                benchmarkPoints = []
                benchmarkFailed = true
            }
        } else {
            benchmarkPoints = []
            benchmarkFailed = false
        }

        benchmarkLoading = false

        // Per-holding change over the period: shares × (live price − first price in range).
        var out: [Contribution] = []
        for h in holdings {
            guard let points = try? await service.history(for: h.asset, range: requestedRange),
                  let start = points.first?.price, start > 0, h.asset.price > 0 else { continue }
            let change = h.shares * (h.asset.price - start)
            out.append(Contribution(id: h.id, holding: h, change: change, percent: (h.asset.price / start - 1) * 100))
        }
        guard !Task.isCancelled, loadKey == key else { return }
        contributions = out.sorted { abs($0.change) > abs($1.change) }
        contributionsLoading = false
    }
}

private extension TimeRange {
    var periodLabelString: String {
        switch self {
        case .oneDay:      return "Today"
        case .oneWeek:     return "Past week"
        case .oneMonth:    return "Past month"
        case .threeMonths: return "Past 3 months"
        case .sixMonths:   return "Past 6 months"
        case .ytd:         return "Year to date"
        case .oneYear:     return "Past year"
        case .twoYears:    return "Past 2 years"
        case .fiveYears:   return "Past 5 years"
        case .tenYears:    return "Past 10 years"
        case .all:         return "All time"
        }
    }
}

// MARK: - Income

struct PortfolioIncomeTab: View {
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var authManager: SupabaseAuthManager
    @Environment(\.theme) private var theme
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @State private var isLoading = false
    @State private var didLoad = false

    private var stocks: [PortfolioHolding] { marketData.portfolio.filter { $0.asset.kind == .stock } }
    private var payers: [PortfolioHolding] {
        stocks.filter { ($0.asset.dividend ?? 0) > 0 }
            .sorted { annualIncome($0) > annualIncome($1) }
    }
    private var noData: [PortfolioHolding] { stocks.filter { $0.asset.dividend == nil } }
    private var cryptoCount: Int { marketData.portfolio.count - stocks.count }

    private func annualIncome(_ h: PortfolioHolding) -> Double {
        (h.asset.dividend ?? 0) / 100 * h.currentValue
    }

    private var totalAnnual: Double { payers.reduce(0) { $0 + annualIncome($1) } }
    private var hasASXPayer: Bool { payers.contains { $0.asset.isASX } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if authManager.authState == .signedIn, let userId = authManager.userId {
                PortfolioCashIncomeLedger(userId: userId).id(userId)
            }
            if payers.isEmpty && !noData.isEmpty && (isLoading || !didLoad) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("Estimated yearly income").font(.subheadline.weight(.medium))
                    SkeletonBlock(width: 130, height: 32)
                    DataRowSkeleton()
                    DataRowSkeleton()
                }
                .dsCard()
                .loadingSkeleton("Loading dividend income")
            } else if payers.isEmpty {
                EmptyStateCard(
                    systemImage: "dollarsign.circle",
                    title: "No dividend estimate available",
                    message: emptyMessage
                )
                .accessibilityIdentifier("portfolio.income.empty")
            } else {
                summaryCard
                payersCard
            }
            if !noData.isEmpty && !isLoading {
                Text(noDataText)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard !noData.isEmpty else { return }
            isLoading = true
            await marketData.refreshDividendYieldsIfNeeded()
            isLoading = false
            didLoad = true
        }
    }

    private var emptyMessage: LocalizedStringKey {
        if stocks.isEmpty { return "Crypto doesn't pay dividends. Add dividend-paying stocks or ETFs to see estimated income here." }
        return "None of your holdings paid a dividend in the last 12 months that we can find."
    }

    private var noDataText: String {
        let symbols = noData.map(\.asset.symbol).joined(separator: ", ")
        return "Couldn't load dividend data for \(symbols) right now — it'll be tried again next time."
    }

    private var summaryCard: some View {
        let total = marketData.totalPortfolioValue
        let yield = total > 0 ? totalAnnual / total * 100 : 0
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Estimated yearly income")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            Text(valueHidden ? "••••" : marketData.formatPrice(totalAnnual))
                .font(DS.money(34, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityIdentifier("portfolio.income.total")
            HStack(spacing: DS.Space.l) {
                LedgerStat(label: "About a month", value: valueHidden ? "••••" : marketData.formatPrice(totalAnnual / 12))
                LedgerStat(label: "Portfolio yield", value: formatPercent(yield), alignment: .trailing)
            }
            Text(hasASXPayer
                 ? "Each stock's dividends over the last 12 months × the shares you hold. ASX figures are cash dividends — franking credits aren't included. Actual payments vary."
                 : "Each stock's dividends over the last 12 months × the shares you hold. Actual payments vary.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
    }

    private var payersCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Dividend payers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(payers) { h in
                    HStack(spacing: DS.Space.m) {
                        TickerLogo(symbol: h.asset.symbol, kind: h.asset.kind, exchange: h.asset.exchange, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.asset.symbol).font(.subheadline.weight(.semibold))
                            Text("Yield \(String(format: "%.2f%%", h.asset.dividend ?? 0))")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(valueHidden ? "••••" : marketData.formatPrice(annualIncome(h)))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text("a year")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.vertical, DS.Space.s)
                    .accessibilityElement(children: .combine)
                    if h.id != payers.last?.id { Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 44) }
                }
            }
        }
        .dsCard()
    }
}
