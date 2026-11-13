//
//  DetailSections.swift
//  Stock Tracker
//
//  The blocks below the chart on the stock / crypto / index detail screen,
//  after Wealthsimple / Apple Stocks (two-column stats ledger), Yahoo
//  (holdings + range bars), Revolut / Public (analyst consensus bars) and
//  Perplexity Finance (target track, EPS estimate-vs-actual dots).
//
//  Every number here is real or shown as "—". Money is stored in USD and
//  formatted through `DetailFormatter` so the whole screen uses one currency.
//

import SwiftUI
import Charts

// MARK: - Formatting

struct DetailFormatter {
    let currency: String
    let rates: [String: Double]
    /// Index levels are points, not money.
    var isPoints = false

    private var rate: Double { currency == "USD" ? 1 : (rates[currency] ?? 1) }

    func money(_ usd: Double) -> String {
        if isPoints { return usd.formatted(.number.precision(.fractionLength(2))) }
        return usd.formattedPrice(in: currency, rates: rates)
    }

    func signedMoney(_ usd: Double) -> String {
        (usd >= 0 ? "+" : "−") + money(abs(usd))
    }

    /// "A$7.51T" / "US$4.99T": the same explicit symbol as every other price on the
    /// page (the locale's currency style printed AUD as a bare "$" in Australia).
    func compactMoney(_ usd: Double) -> String {
        let value = usd * rate
        let sign = value < 0 ? "−" : ""
        return sign + Self.symbol(for: currency)
            + abs(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    static func symbol(for currency: String) -> String {
        switch currency {
        case "USD": return "US$"
        case "AUD": return "A$"
        case "CAD": return "C$"
        default:
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency
            return f.currencySymbol ?? currency + " "
        }
    }

    func compactNumber(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    func wholeNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// `fraction` 0.256 → "25.6%".
    func percent(_ fraction: Double, signed: Bool = false) -> String {
        let text = String(format: "%.1f%%", abs(fraction) * 100)
        guard signed else { return (fraction < 0 ? "−" : "") + text }
        return (fraction >= 0 ? "+" : "−") + text
    }

    func ratio(_ value: Double) -> String { String(format: "%.2f", value) }
}

// MARK: - Section scaffold

struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    var caption: String? = nil
    var identifier: String
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: title)
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// One label/value line in a ledger.
struct LedgerRow: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var detail: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint ?? theme.primaryText)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Your position

struct DetailPositionCard: View {
    let holding: PortfolioHolding
    let live: Asset
    let format: DetailFormatter
    @Environment(\.theme) private var theme

    var body: some View {
        let value = holding.shares * live.price
        let cost = holding.shares * holding.avgCost
        let total = value - cost
        let totalPct = cost > 0 ? total / cost : 0
        let today = holding.shares * live.change
        let totalTint = abs(total) < 0.005 ? theme.primaryText : (total >= 0 ? theme.positiveColor : theme.negativeColor)
        let todayTint = abs(today) < 0.005 ? theme.primaryText : (today >= 0 ? theme.positiveColor : theme.negativeColor)

        DetailSection(title: "Your position", identifier: "detail.position") {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Market value")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        Text(format.money(value))
                            .font(DS.money(26, weight: .bold))
                            .foregroundStyle(theme.primaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Shares")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        Text(holding.shares.formatted(.number.precision(.fractionLength(0...4))))
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                }
                .padding(.bottom, DS.Space.s)
                Divider().overlay(theme.cardBorder.opacity(0.4))
                LedgerRow(label: "Average cost", value: format.money(holding.avgCost))
                Divider().overlay(theme.cardBorder.opacity(0.4))
                LedgerRow(label: "Today's return", value: format.signedMoney(today), tint: todayTint,
                          detail: String(format: "%+.2f%%", live.changePercent))
                Divider().overlay(theme.cardBorder.opacity(0.4))
                LedgerRow(label: "Total return", value: format.signedMoney(total), tint: totalTint,
                          detail: format.percent(totalPct, signed: true))
            }
            .dsCard()
        }
    }
}

/// Shown when the person doesn't own it (Yahoo's "Holding AAPL now?").
struct DetailOwnPrompt: View {
    let symbol: String
    /// Yahoo's "Link broker" next to "Add manually": bring it in from the broker instead.
    var onLinkBroker: (() -> Void)? = nil
    let onAdd: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "briefcase")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(DS.accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Own \(symbol)?")
                    .font(.subheadline.weight(.semibold))
                Text("Add it to your portfolio to track your return.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let onLinkBroker, !SnapTradeViewModel.shared.hasLinkedAccounts {
                    Button {
                        Haptics.tap()
                        onLinkBroker()
                    } label: {
                        Label("Or link your broker", systemImage: "link")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DS.accent)
                            .frame(minHeight: 32, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("detail.position.linkBroker")
                }
            }
            Spacer(minLength: DS.Space.s)
            Button {
                Haptics.tap()
                onAdd()
            } label: {
                Text("Add")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DS.Space.l)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(theme.primaryText.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(theme.primaryText)
            .accessibilityLabel("Add \(symbol) to your portfolio")
            .accessibilityIdentifier("detail.position.add")
        }
        .dsCard(padding: DS.Space.m)
    }
}

// MARK: - Key statistics

struct StatItem: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct RangeItem: Identifiable {
    let label: String
    let low: Double
    let high: Double
    let current: Double
    var id: String { label }
}

struct DetailKeyStats: View {
    var caption: String? = nil
    let ranges: [RangeItem]
    let primary: [StatItem]
    var more: [StatItem] = []
    var isLoading = false
    let format: DetailFormatter
    @State private var showsMore = false
    @Environment(\.theme) private var theme

    var body: some View {
        DetailSection(title: "Key statistics", caption: caption, identifier: "detail.stats") {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ForEach(ranges) { item in
                    RangeBar(item: item, format: format)
                }
                if !ranges.isEmpty && !primary.isEmpty {
                    Divider().overlay(theme.cardBorder.opacity(0.4))
                }
                grid(primary + (showsMore ? more : []))
                    .redacted(reason: isLoading ? .placeholder : [])
                if !more.isEmpty {
                    Button {
                        Haptics.tap()
                        dsAnimate { showsMore.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsMore ? "Show less" : "Show all statistics")
                            Image(systemName: showsMore ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DS.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("detail.stats.more")
                }
            }
            .dsCard()
        }
    }

    private func grid(_ items: [StatItem]) -> some View {
        let columns = [GridItem(.flexible(), spacing: DS.Space.xl), GridItem(.flexible(), spacing: DS.Space.xl)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Long labels ("Free cash flow" next to "A$204.33B") wrap rather
                        // than truncate; the number always gets its full width.
                        Text(item.label)
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(item.value)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .layoutPriority(1)
                    }
                    .padding(.vertical, 10)
                    Divider().overlay(theme.cardBorder.opacity(0.3))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "Low ——●—— High" (Yahoo's day / 52-week range).
struct RangeBar: View {
    let item: RangeItem
    let format: DetailFormatter
    @Environment(\.theme) private var theme

    private var fraction: Double {
        guard item.high > item.low else { return 0.5 }
        return min(max((item.current - item.low) / (item.high - item.low), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.label)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            GeometryReader { geo in
                let x = geo.size.width * fraction
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.cardBorder.opacity(0.5)).frame(height: 4)
                    Circle()
                        .fill(theme.primaryText)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(x - 5, 0), geo.size.width - 10))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack {
                Text(format.money(item.low))
                Spacer()
                Text(format.money(item.high))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(theme.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue("Low \(format.money(item.low)), high \(format.money(item.high)), now \(format.money(item.current))")
    }
}

// MARK: - Analysts

struct DetailAnalystsSection: View {
    let insight: StockInsight
    let price: Double
    let format: DetailFormatter
    @Environment(\.theme) private var theme

    var body: some View {
        DetailSection(title: "What analysts say", caption: caption, identifier: "detail.analysts") {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let c = insight.consensus {
                    consensus(c)
                }
                if let t = insight.targets {
                    if insight.consensus != nil { Divider().overlay(theme.cardBorder.opacity(0.4)) }
                    targets(t)
                }
                if !insight.ratingChanges.isEmpty {
                    if insight.consensus != nil || insight.targets != nil { Divider().overlay(theme.cardBorder.opacity(0.4)) }
                    changes(Array(insight.ratingChanges.prefix(4)))
                }
            }
            .dsCard()
        }
    }

    private var caption: String? {
        guard let c = insight.consensus else { return nil }
        return "Based on \(c.total) analyst\(c.total == 1 ? "" : "s") this month"
    }

    private func consensus(_ c: AnalystConsensus) -> some View {
        let verdictTint: Color = {
            switch c.verdict {
            case .buy: return theme.positiveColor
            case .sell: return theme.negativeColor
            case .hold: return theme.primaryText
            }
        }()
        return HStack(alignment: .center, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Consensus")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Text(c.verdict.rawValue)
                    .font(DS.money(28, weight: .bold))
                    .foregroundStyle(verdictTint)
            }
            .frame(minWidth: 92, alignment: .leading)
            VStack(spacing: 8) {
                bar("Buy", count: c.buyCount, total: c.total, tint: theme.positiveColor)
                bar("Hold", count: c.hold, total: c.total, tint: theme.secondaryText)
                bar("Sell", count: c.sellCount, total: c.total, tint: theme.negativeColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analyst consensus \(c.verdict.rawValue). \(c.buyCount) buy, \(c.hold) hold, \(c.sellCount) sell.")
    }

    private func bar(_ label: String, count: Int, total: Int, tint: Color) -> some View {
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        return HStack(spacing: DS.Space.s) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.cardBorder.opacity(0.35))
                    Capsule().fill(tint).frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 6)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.primaryText)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func targets(_ t: PriceTargets) -> some View {
        let upside = price > 0 ? (t.average - price) / price : 0
        let lo = min(t.low, price), hi = max(t.high, price)
        let span = max(hi - lo, 0.0001)
        func x(_ v: Double, _ w: CGFloat) -> CGFloat { w * CGFloat((v - lo) / span) }
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Average price target")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    Text(format.money(t.average))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(upside >= 0 ? "Upside" : "Downside")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    Text(format.percent(upside, signed: true))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(upside >= 0 ? theme.positiveColor : theme.negativeColor)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.cardBorder.opacity(0.4)).frame(height: 4)
                    Capsule().fill(DS.accent.opacity(0.45))
                        .frame(width: max(x(t.high, w) - x(t.low, w), 4), height: 4)
                        .offset(x: x(t.low, w))
                    Circle().strokeBorder(DS.accent, lineWidth: 2)
                        .background(Circle().fill(theme.background))
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(x(t.average, w) - 6, 0), w - 12))
                    Circle().fill(theme.primaryText)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(x(price, w) - 5, 0), w - 10))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                labelled("Low", format.money(t.low))
                Spacer()
                labelled("Now", format.money(price), alignment: .center)
                Spacer()
                labelled("High", format.money(t.high), alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Average price target \(format.money(t.average)), \(format.percent(upside, signed: true)) from now. Low \(format.money(t.low)), high \(format.money(t.high)).")
    }

    private func labelled(_ title: String, _ value: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(theme.secondaryText)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(theme.primaryText)
        }
    }

    private func changes(_ items: [AnalystRatingChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent rating changes")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.bottom, 4)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.firm)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let date = item.date {
                            Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    Spacer(minLength: DS.Space.s)
                    Text(gradeText(item))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if item.id != items.last?.id {
                    Divider().overlay(theme.cardBorder.opacity(0.3))
                }
            }
        }
    }

    private func gradeText(_ item: AnalystRatingChange) -> String {
        if let prev = item.previousGrade, !prev.isEmpty, prev != item.newGrade {
            return "\(prev) → \(item.newGrade)"
        }
        return item.newGrade
    }
}

// MARK: - Earnings

struct DetailEarningsSection: View {
    let entries: [EarningsEntry]       // newest first
    let format: DetailFormatter
    @Environment(\.theme) private var theme

    private var shown: [EarningsEntry] { Array(entries.prefix(6).reversed()) }

    var body: some View {
        DetailSection(title: "Earnings", caption: "Earnings per share, reported vs. analysts' estimate",
                      identifier: "detail.earnings") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                chart
                    .frame(height: 170)
                legend
                if let latest = entries.first {
                    Divider().overlay(theme.cardBorder.opacity(0.4))
                    latestRow(latest)
                }
            }
            .dsCard()
        }
    }

    private var chart: some View {
        Chart {
            ForEach(shown) { entry in
                if let est = entry.epsEstimate {
                    PointMark(x: .value("Quarter", entry.label), y: .value("EPS", est))
                        .symbol {
                            Circle().strokeBorder(theme.secondaryText, lineWidth: 1.5)
                                .frame(width: 12, height: 12)
                        }
                }
                if let act = entry.epsActual {
                    PointMark(x: .value("Quarter", entry.label), y: .value("EPS", act))
                        .symbol {
                            Circle().fill(tint(entry)).frame(width: 12, height: 12)
                        }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(theme.cardBorder.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(format.money(v)).font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .accessibilityLabel("Earnings per share for the last \(shown.count) reports")
    }

    /// Hug the values (EPS can be small or negative); never force the axis to zero.
    private var yDomain: ClosedRange<Double> {
        let values = shown.flatMap { [$0.epsEstimate, $0.epsActual].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, abs(hi) * 0.05, 0.01)
        return (lo - pad)...(hi + pad)
    }

    private func tint(_ entry: EarningsEntry) -> Color {
        switch entry.beat {
        case .some(true): return theme.positiveColor
        case .some(false): return theme.negativeColor
        case .none: return theme.primaryText
        }
    }

    private var legend: some View {
        HStack(spacing: DS.Space.l) {
            HStack(spacing: 6) {
                Circle().strokeBorder(theme.secondaryText, lineWidth: 1.5).frame(width: 10, height: 10)
                Text("Estimate")
            }
            HStack(spacing: 6) {
                Circle().fill(theme.positiveColor).frame(width: 10, height: 10)
                Text("Beat")
            }
            HStack(spacing: 6) {
                Circle().fill(theme.negativeColor).frame(width: 10, height: 10)
                Text("Missed")
            }
        }
        .font(.caption)
        .foregroundStyle(theme.secondaryText)
        .accessibilityHidden(true)
    }

    private func latestRow(_ e: EarningsEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Latest · \(e.label)")
                    .font(.subheadline.weight(.semibold))
                if let date = e.periodEnd {
                    Text("Period ended \(date.formatted(.dateTime.day().month(.abbreviated).year()))")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let act = e.epsActual {
                    Text("EPS \(format.money(act))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let est = e.epsEstimate, let act = e.epsActual {
                    let diff = act - est
                    Text("\(diff >= 0 ? "Beat" : "Missed") by \(format.money(abs(diff)))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(diff >= 0 ? theme.positiveColor : theme.negativeColor)
                } else if let est = e.epsEstimate {
                    Text("Estimate \(format.money(est))")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Financials (Pro)

enum FinancialStatementKind: String, CaseIterable, Identifiable {
    case income = "Income"
    case balance = "Balance sheet"
    case cashFlow = "Cash flow"
    var id: String { rawValue }
}

struct DetailFinancialsSection: View {
    let isLocked: Bool
    let income: [FMPIncomeStatement]
    let statements: FinancialStatements?
    let statementsLoading: Bool
    let format: DetailFormatter
    let onUnlock: () -> Void
    let onNeedStatements: () -> Void
    @State private var kind: FinancialStatementKind = .income
    @Environment(\.theme) private var theme

    var body: some View {
        DetailSection(title: "Financials", caption: "Annual, as reported", identifier: "detail.financials") {
            if isLocked {
                lockedCard
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Picker("Statement", selection: $kind) {
                        ForEach(FinancialStatementKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("detail.financials.picker")
                    .onChange(of: kind) { _, new in
                        if new != .income { onNeedStatements() }
                    }
                    table
                }
                .dsCard()
            }
        }
    }

    private var lockedCard: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(DS.accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Income, balance sheet and cash flow")
                    .font(.subheadline.weight(.semibold))
                Text("Three years of statements with Pro.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: DS.Space.s)
            Button {
                Haptics.tap()
                onUnlock()
            } label: {
                Text("Unlock")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DS.Space.l)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(theme.primaryText.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(theme.primaryText)
            .accessibilityIdentifier("detail.financials.unlock")
        }
        .dsCard(padding: DS.Space.m)
    }

    private struct Line: Identifiable {
        let metric: String
        let values: [Double?]
        var perShare = false
        var id: String { metric }
    }

    @ViewBuilder
    private var table: some View {
        let content = lines
        if content.lines.isEmpty {
            if statementsLoading && kind != .income {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in DataRowSkeleton() }
                }
                .loadingSkeleton("Loading financial statements")
            } else {
                // Usually the provider's free daily quota, not the company: don't blame the company.
                Text("Statements couldn't be loaded right now. Try again later.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(content.periods, id: \.self) { p in
                        Text(p)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                .padding(.bottom, 6)
                Divider().overlay(theme.cardBorder.opacity(0.4))
                ForEach(content.lines) { line in
                    HStack(spacing: 0) {
                        Text(line.metric)
                            .font(.footnote)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(line.values.prefix(content.periods.count).enumerated()), id: \.offset) { i, v in
                            Text(v.map { line.perShare ? format.money($0) : format.compactMoney($0) } ?? "—")
                                .font(.footnote.weight(i == 0 ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(i == 0 ? theme.primaryText : theme.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    if line.id != content.lines.last?.id {
                        Divider().overlay(theme.cardBorder.opacity(0.25))
                    }
                }
            }
        }
    }

    private var lines: (periods: [String], lines: [Line]) {
        switch kind {
        case .income:
            let stmts = Array(income.prefix(3))
            let periods = stmts.map { s in s.date.map { "FY" + String($0.prefix(4)) } ?? "—" }
            let rows: [Line] = [
                Line(metric: "Revenue", values: stmts.map(\.revenue)),
                Line(metric: "Gross profit", values: stmts.map(\.grossProfit)),
                Line(metric: "Operating income", values: stmts.map(\.operatingIncome)),
                Line(metric: "Net income", values: stmts.map(\.netIncome)),
                Line(metric: "EBITDA", values: stmts.map(\.ebitda)),
                Line(metric: "EPS (diluted)", values: stmts.map { $0.epsDiluted ?? $0.eps }, perShare: true)
            ].filter { $0.values.contains { $0 != nil } }
            return (periods, rows)
        case .balance:
            let rows = statements?.balance ?? []
            return (Array((rows.first?.periods ?? []).prefix(3)), rows.map { Line(metric: $0.metric, values: $0.values) })
        case .cashFlow:
            let rows = statements?.cashFlow ?? []
            return (Array((rows.first?.periods ?? []).prefix(3)), rows.map { Line(metric: $0.metric, values: $0.values) })
        }
    }
}

// MARK: - About

struct AboutFact: Identifiable {
    let label: String
    let value: String
    var link: URL? = nil
    var id: String { label }
}

struct DetailAboutSection: View {
    let title: LocalizedStringKey
    let text: String?
    let facts: [AboutFact]
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        DetailSection(title: title, identifier: "detail.about") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .lineSpacing(3)
                        .lineLimit(expanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                    if text.count > 220 {
                        Button(expanded ? "Show less" : "Read more") {
                            Haptics.tap()
                            dsAnimate { expanded.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DS.accent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("detail.about.more")
                    }
                }
                if !facts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(facts) { fact in
                            if let url = fact.link {
                                Link(destination: url) {
                                    HStack {
                                        Text(fact.label)
                                            .font(.subheadline)
                                            .foregroundStyle(theme.secondaryText)
                                        Spacer()
                                        Text(fact.value)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(DS.accent)
                                            .lineLimit(1)
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(DS.accent)
                                    }
                                    .frame(minHeight: 44)
                                }
                            } else {
                                LedgerRow(label: fact.label, value: fact.value)
                            }
                            if fact.id != facts.last?.id {
                                Divider().overlay(theme.cardBorder.opacity(0.3))
                            }
                        }
                    }
                }
            }
            .dsCard()
        }
    }
}

// MARK: - Notes

/// A calm inline note ("Analyst data isn't available for ASX listings yet").
struct DetailNote: View {
    let systemImage: String
    let text: String
    var identifier: String = "detail.note"
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - AI summary (Pro)

struct DetailAISummaryCard: View {
    let symbol: String
    let facts: String
    @EnvironmentObject private var ai: AIInsightService
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var text: String?
    @State private var isLoading = false
    @State private var failed = false
    @Environment(\.theme) private var theme

    private var cacheKey: String { "detail_summary_\(symbol)" }

    var body: some View {
        DetailSection(title: "AI summary", identifier: "detail.ai") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let shown = text ?? ai.cached(cacheKey)?.text {
                    Text(shown)
                        .font(.subheadline)
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Written by AI from the figures on this page. It can be wrong and isn't financial advice.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else if isLoading {
                    TextSkeleton()
                        .loadingSkeleton("Summarising \(symbol)")
                    .frame(minHeight: 44)
                } else {
                    if failed {
                        Text("The summary couldn't be written just now.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Button {
                        Haptics.tap()
                        Task { await generate() }
                    } label: {
                        Label(failed ? "Try again" : "Summarise with AI", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .accessibilityIdentifier("detail.ai.generate")
                }
            }
            .dsCard()
        }
    }

    private func generate() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        let system = "You are a careful financial writer. In 3 short sentences, summarise where this asset stands using only the facts given: recent price move, valuation and what analysts say if provided. Be neutral. Never recommend buying or selling. Never invent numbers."
        let result = await ai.generateInsight(
            key: cacheKey, type: .holdingInsight, systemPrompt: system,
            userPrompt: facts, tier: subscriptions.currentTier, ttl: 4 * 3600, maxTokens: 180)
        if let result, !result.isEmpty { text = result } else { failed = true }
    }
}
