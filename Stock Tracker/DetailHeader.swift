//
//  DetailHeader.swift
//  Stock Tracker
//
//  Top of the detail screen: identity, price, change for the selected period,
//  market status + freshness, then the chart and range picker.
//
//  After Public / Wealthsimple / Apple Stocks on Mobbin: the change label
//  follows the range ("Past year"), the 1D chart sits on the session with a
//  dashed previous-close line, and scrubbing turns the header into a readout
//  of the point under the finger (value, change from the baseline, time).
//

import SwiftUI

enum DetailAssetKind: Equatable {
    case usStock, asxStock, otherStock, crypto, index

    init(_ asset: Asset) {
        if asset.kind == .crypto { self = .crypto }
        else if asset.symbol.hasPrefix("^") { self = .index }
        else if QuoteService.isASX(asset) { self = .asxStock }
        else if asset.exchange.uppercased() == "INTERNATIONAL" { self = .otherStock }
        else { self = .usStock }
    }

    var isStock: Bool { self == .usStock || self == .asxStock || self == .otherStock }

    /// The exchange whose hours and holidays apply (nil = always open / unknown).
    func market(for asset: Asset) -> StockExchangeMarket? {
        switch self {
        case .usStock: return .us
        case .asxStock: return .asx
        case .index: return asset.symbol.uppercased() == "^AXJO" ? .asx : .us
        case .crypto, .otherStock: return nil
        }
    }
}

struct DetailHeaderChart: View {
    @ObservedObject var model: AssetDetailViewModel
    let live: Asset
    let format: DetailFormatter
    let lastUpdated: Date?
    let quoteFailed: Bool
    let candlesLocked: Bool
    let onLockedCandles: () -> Void
    @Binding var scrubbed: DSChartPoint?
    @Binding var scrubbedCandle: Candle?

    @Environment(\.theme) private var theme

    static let ranges: [TimeRange] = DSRangePicker.standard

    private var kind: DetailAssetKind { model.kind }
    private var hours: TradingHours? { TradingHours.forAsset(model.seed) }
    private var timeZone: TimeZone { hours?.timeZone ?? .current }
    private var marketStatus: MarketClockStatus? { kind.market(for: live).map { MarketClock.status(for: $0) } }

    private var previousClose: Double? {
        let pc = live.price - live.change
        return pc > 0 && live.price > 0 ? pc : nil
    }

    /// The series for the selected range, ending on the live price. While a new
    /// range loads the previous line stays (dimmed by the chart) without the live point.
    private var chartPoints: [DSChartPoint] {
        guard model.pointsRange == model.range else { return model.points.chartPoints }
        return PriceHistoryService.appendingLive(model.points, price: live.price).chartPoints
    }

    private var reference: Double? {
        if model.range == .oneDay { return previousClose }
        guard model.pointsRange == model.range else { return nil }
        return model.points.first?.price
    }

    private var xMode: DSChartXMode {
        guard model.range == .oneDay, let hours, let first = chartPoints.first, let last = chartPoints.last else { return .ordinal }
        let session = hours.session(containing: first.date)
        return session.contains(last.date) ? .time(domain: session) : .ordinal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            identity
            priceBlock
            statusLine
            chart
                .padding(.top, DS.Space.xs)
            DSRangePicker(options: Self.ranges, selection: $model.range, tint: DS.accent)
                .accessibilityIdentifier("detail.range")
        }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: DS.Space.m) {
            if kind == .index {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.accent.opacity(0.14)))
                    .accessibilityHidden(true)
            } else {
                TickerLogo(symbol: live.symbol, kind: live.kind,
                           exchange: kind == .asxStock ? "ASX" : live.exchange, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                Text(listingLine)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.identity")
    }

    private var displayName: String {
        let name = model.stock.name.isEmpty ? live.name : model.stock.name
        return name.isEmpty ? live.symbol : name
    }

    private var listingLine: String {
        switch kind {
        case .crypto: return "\(live.symbol) · Crypto"
        case .index: return "Index · points"
        case .asxStock: return "\(live.symbol) · ASX"
        case .otherStock: return live.symbol
        case .usStock:
            // Only name the exchange when FMP's profile says which one; quotes alone don't.
            let exchange = model.stock.exchange.uppercased()
            let known = model.fundamentalsState == .loaded && model.stock.hasProfile
                && !["", "US", "—"].contains(exchange)
            return "\(live.symbol) · \(known ? model.stock.exchange : "US")"
        }
    }

    // MARK: Price + change

    @ViewBuilder
    private var priceBlock: some View {
        let shown = scrubbedCandle?.close ?? scrubbed?.value ?? live.price
        HStack(alignment: .center) {
            Text(live.price > 0 ? format.money(shown) : "—")
                .font(DS.money(40, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: shown))
                .animation(scrubbed == nil && scrubbedCandle == nil ? DS.quick : nil, value: shown)
                .accessibilityIdentifier("detail.price")
            Spacer(minLength: DS.Space.s)
            if kind.isStock || kind == .index {
                chartStyleToggle
            }
        }
        if let candle = scrubbedCandle {
            ohlcReadout(candle)
        } else {
            changeRow(shown: shown)
        }
    }

    private func changeRow(shown: Double) -> some View {
        let isLiveDay = model.range == .oneDay && scrubbed == nil
        let change: Double? = isLiveDay ? live.change : reference.map { shown - $0 }
        let percent: Double? = {
            if isLiveDay { return live.changePercent }
            guard let ref = reference, ref > 0, let change else { return nil }
            return change / ref * 100
        }()
        return HStack(spacing: DS.Space.s) {
            if let change, let percent, live.price > 0 {
                ChangePill(percent: percent, amount: format.signedMoney(change))
                    .fixedSize()
                    .layoutPriority(1)
            } else {
                Text("—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            Text(changeLabel)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.change")
    }

    private var changeLabel: String {
        if let scrubbed { return scrubText(scrubbed.date) }
        guard model.range == .oneDay else { return Self.periodText(model.range) }
        if kind == .crypto { return "Past 24 hours" }
        guard let status = marketStatus else { return "Today" }
        switch status.phase {
        case .open: return "Today"
        case .preMarket: return "Pre-market, since last close"
        case .afterHours: return "Today, incl. after hours"
        case .closed:
            if let last = model.points.last?.date, model.pointsRange == .oneDay {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = timeZone
                if !cal.isDateInToday(last) {
                    let f = DateFormatter()
                    f.timeZone = timeZone
                    f.dateFormat = "EEE d MMM"
                    return "At close, \(f.string(from: last))"
                }
            }
            return "At close"
        }
    }

    static func periodText(_ range: TimeRange) -> String {
        switch range {
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

    private func ohlcReadout(_ c: Candle) -> some View {
        HStack(spacing: DS.Space.m) {
            ohlc("O", c.open)
            ohlc("H", c.high)
            ohlc("L", c.low)
            ohlc("C", c.close)
        }
        .frame(minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.ohlc")
    }

    private func ohlc(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(theme.secondaryText)
            Text(format.money(value)).foregroundStyle(theme.primaryText)
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var chartStyleToggle: some View {
        let isCandle = model.style == .candle
        return Button {
            Haptics.tap()
            if candlesLocked && !isCandle {
                onLockedCandles()
            } else {
                dsAnimate(DS.quick) { model.style = isCandle ? .line : .candle }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: isCandle ? "chart.xyaxis.line" : "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.subtleFill))
                    .overlay(Circle().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                if candlesLocked && !isCandle {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.accent)
                        .padding(3)
                        .background(Circle().fill(theme.background))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(isCandle ? "Show line chart" : "Show candlestick chart")
        .accessibilityHint(candlesLocked && !isCandle ? "Candlesticks are part of Pro" : "")
        .accessibilityIdentifier("detail.chartStyle")
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDot)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(quoteFailed ? theme.warningColor : theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.status")
    }

    private var statusDot: Color {
        if quoteFailed { return theme.warningColor }
        if kind == .crypto { return theme.positiveColor }
        switch marketStatus?.phase {
        case .open: return theme.positiveColor
        case .preMarket, .afterHours: return theme.warningColor
        default: return theme.secondaryText.opacity(0.5)
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if kind == .crypto {
            parts.append("Trades 24/7")
        } else if let status = marketStatus {
            let name = status.market == .asx ? "ASX" : "US market"
            switch status.phase {
            case .open: parts.append("\(name) open")
            case .preMarket: parts.append("\(name) pre-market")
            case .afterHours: parts.append("\(name) after hours")
            case .closed: parts.append(status.holiday.map { "\(name) closed · \($0)" } ?? "\(name) closed")
            }
        }
        if quoteFailed {
            parts.append("couldn't refresh — last known price")
        } else if let lastUpdated {
            parts.append("updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Chart

    private func scrubText(_ date: Date) -> String {
        let text = model.range.scrubLabel(for: date, timeZone: timeZone)
        guard hours != nil, model.range == .oneDay || model.range == .oneWeek,
              let abbreviation = timeZone.abbreviation(for: date) else { return text }
        return "\(text) \(abbreviation)"
    }

    @ViewBuilder
    private var chart: some View {
        if model.style == .candle && (kind.isStock || kind == .index) {
            DetailCandleChart(
                candles: model.candlesRange == model.range || model.candlePhase == .loading ? model.candles : [],
                phase: model.candlePhase,
                height: 240,
                valueText: { format.money($0) },
                dateText: { scrubText($0) },
                selection: $scrubbedCandle,
                onRetry: { model.loadCandles(force: true) }
            )
        } else {
            DSPriceChart(
                points: chartPoints,
                phase: model.chartPhase,
                baseline: model.range == .oneDay ? previousClose : nil,
                baselineLabel: model.range == .oneDay ? (kind == .crypto ? "24h ago" : "Prev close") : nil,
                xMode: xMode,
                height: 240,
                showsYAxis: true,
                valueText: { format.money($0) },
                dateText: { scrubText($0) },
                selection: $scrubbed,
                onRetry: { model.loadChart(force: true) },
                accessibilityID: "detail.chart"
            )
        }
    }
}
