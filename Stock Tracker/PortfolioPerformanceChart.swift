//
//  PortfolioPerformanceChart.swift
//  Stock Tracker
//
//  Reusable portfolio value hero: a value header that follows the scrub, the
//  period change, a DSPriceChart of the current holdings' value rebuilt from
//  real price history (PriceHistoryService.portfolioSeries), a range picker and
//  honest notes. Used by the Portfolio tab; Home can adopt it too.
//
//  The series is "today's holdings, projected back" — it is not what the
//  person actually earned (no purchase dates / cash flows), so it says so.
//

import SwiftUI
import OSLog

struct PortfolioPerformanceChart: View {
    var title: LocalizedStringKey = "Total value"
    var ranges: [TimeRange] = DSRangePicker.standard
    @Binding var range: TimeRange
    var chartHeight: CGFloat = 190
    /// Privacy mode: amounts become dots; percentages and the line stay.
    var hidesValues = false
    /// Also show today's move when another range is selected.
    var showsTodayLine = true
    var accessibilityID = "chart.price"
    /// Revolut's hero: label, balance and change centred over the chart.
    var centered = false

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    @State private var series: PortfolioSeries?
    @State private var phase: DSChartPhase = .loading
    @State private var scrubbed: DSChartPoint?
    @State private var loadedRange: TimeRange?

    /// Reload when the range, the holdings or their live prices change, so the
    /// line always ends on the value the header shows (a stale end draws a cliff).
    private var loadKey: String {
        range.rawValue + "|" + marketData.portfolio
            .map { "\($0.asset.symbol):\($0.shares):\($0.asset.price):\($0.asset.change)" }
            .joined(separator: ",")
    }

    var body: some View {
        let live = marketData.totalPortfolioValue
        let daily = marketData.dailyProfitLoss
        let points = loadedRange == range ? series?.points.chartPoints ?? [] : []
        let chartPhase: DSChartPhase = loadedRange == range ? phase : .loading
        let reference: Double? = range == .oneDay ? live - daily : points.first?.value
        let selection = chartPhase == .loading ? nil : scrubbed
        let shown = selection?.value ?? live
        let change = reference.map { shown - $0 } ?? 0
        let changePct = reference.flatMap { $0 > 0 ? change / $0 * 100 : nil }

        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: centered ? .center : .leading, spacing: DS.Space.m) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.bottom, -DS.Space.s)

            Text(hidesValues ? "••••••" : marketData.formatPrice(shown))
                .font(DS.money(40, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .motionSafeAnimation(selection == nil && !hidesValues ? DS.quick : nil, value: live)
                .accessibilityIdentifier("\(accessibilityID).value")

            VStack(alignment: .leading, spacing: 6) {
                if let changePct {
                    changeLine(percent: changePct, amount: change,
                               label: selection.map { Text(range.scrubLabel(for: $0.date)) } ?? Text(range.periodLabel))
                } else {
                    HStack(spacing: DS.Space.s) {
                        if chartPhase == .loading {
                            SkeletonBlock(width: 116, height: 18)
                                .loadingSkeleton("Loading portfolio return")
                        } else {
                            Text("—").foregroundStyle(theme.secondaryText)
                        }
                        Text(range.periodLabel).font(.subheadline).foregroundStyle(theme.secondaryText)
                    }
                    .frame(minHeight: 24)
                }
                if showsTodayLine && range != .oneDay && selection == nil {
                    changeLine(percent: marketData.dailyProfitLossPercent, amount: daily, label: Text("Today"))
                }
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)

            DSPriceChart(
                points: points,
                phase: chartPhase,
                baseline: range == .oneDay ? series?.baseline : nil,
                baselineLabel: range == .oneDay ? "Prev close" : nil,
                xMode: xMode,
                height: chartHeight,
                valueText: { hidesValues ? "•••" : marketData.formatPrice($0) },
                dateText: { range.scrubLabel(for: $0) },
                selection: $scrubbed,
                onRetry: { Task { await load(force: true) } },
                accessibilityID: accessibilityID,
                range: loadedRange
            )
            .padding(.horizontal, -4)

            DSRangePicker(options: ranges, selection: $range,
                          tint: change >= 0 ? theme.positiveColor : theme.negativeColor)

            notes
        }
        .task(id: loadKey) { await load() }
        .onChange(of: range) { _, _ in scrubbed = nil }
    }

    private func changeLine(percent: Double, amount: Double, label: Text) -> some View {
        HStack(spacing: DS.Space.s) {
            ChangePill(percent: percent, amount: hidesValues ? nil : marketData.signedMoney(amount))
            label
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Based on your current holdings' price history — not past trades or deposits.")
            if let missing = series?.missingSymbols, !missing.isEmpty {
                Text("No price history for \(missing.joined(separator: ", ")), so the chart holds \(missing.count == 1 ? "it" : "them") at today's price.")
            }
            if marketData.portfolio.contains(where: { marketData.hasNoLivePrice($0.asset) }) {
                Text(staleText)
            }
        }
        .font(.caption2)
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var staleText: String {
        let failed = marketData.portfolio.filter { marketData.hasNoLivePrice($0.asset) }.map(\.asset.symbol)
        return "No live price yet for \(failed.joined(separator: ", ")) — valued at the last known price or what you paid."
    }

    // MARK: Data

    private func load(force: Bool = false) async {
        guard !marketData.portfolio.isEmpty else { series = nil; return }
        let requestedRange = range
        let requestedKey = loadKey
        // Only flash a loading state when the range changes; live updates are silent.
        if loadedRange != requestedRange || series == nil || force { phase = .loading }
        do {
            let value = marketData.totalPortfolioValue
            let result = try await PriceHistoryService.shared.portfolioSeries(
                holdings: marketData.portfolio,
                range: requestedRange,
                liveValue: value,
                previousCloseValue: value - marketData.dailyProfitLoss,
                forceRefresh: force
            )
            guard !Task.isCancelled, loadKey == requestedKey else { return }
            series = result
            phase = .loaded
            loadedRange = requestedRange
        } catch {
            guard !Task.isCancelled, loadKey == requestedKey else { return }
            if series == nil || loadedRange != requestedRange {
                series = nil
                loadedRange = requestedRange
                phase = .failed("Prices for your holdings couldn't be loaded.")
            } else {
                phase = .loaded
            }
        }
    }

    /// 1D is always on a real time axis: the series holds flat wherever nothing
    /// traded (see PriceHistoryService), so gaps between sessions are honest. A
    /// single market inside its session gets the whole session as the domain so
    /// the line grows through the day. Longer ranges compress non-trading time.
    private var xMode: DSChartXMode {
        guard range == .oneDay, let points = series?.points, let first = points.first, let last = points.last
        else { return .ordinal }
        let hours = marketData.portfolio.map { TradingHours.forAsset($0.asset) }
        if let firstHours = hours.first, let h = firstHours,
           hours.allSatisfy({ $0?.timeZone == h.timeZone && $0?.openMinute == h.openMinute }),
           h.session(containing: first.date).contains(last.date) {
            return .time(domain: h.session(containing: first.date))
        }
        return .time(domain: nil)
    }
}
