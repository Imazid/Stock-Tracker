//
//  TradingUI.swift
//  Stock Tracker
//
//  Shared pieces for the trading screens (order ticket, agents, activity), so
//  they read as one product: the Practice marker, status glyphs, money and
//  quantity text, risk-check lists, evidence lists and the equity chart.
//
//  House rules these components carry:
//  - Practice money is always labelled as practice. Nothing here can show a
//    simulated order, fill or balance without the word.
//  - Status is a glyph plus a word; gain and loss are an arrow plus a sign.
//    Colour helps but is never the only signal.
//  - Money shows its currency explicitly (US$ / A$), in the portfolio's own
//    currency, with no silent conversion.
//

import SwiftUI
import Charts
import TradingCore

// MARK: - Text

enum TradingFormat {
    /// The prefix for amounts in `currency`. US and Australian dollars are always told apart.
    static func symbol(_ currency: String) -> String {
        switch currency {
        case "USD": return "US$"
        case "CAD": return "C$"
        default: return Currencies.symbol(currency)
        }
    }

    /// "US$1,234.56", "£1,234.56", "¥1,234,567" — an amount already in `currency`.
    static func money(_ value: Double, _ currency: String) -> String {
        number(value, decimals: Currencies.decimals(currency), currency: currency)
    }

    private static func number(_ value: Double, decimals: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        let body = formatter.string(from: NSNumber(value: Rounding.round(abs(value), places: decimals))) ?? String(format: "%.\(decimals)f", abs(value))
        return (value < 0 ? "-" : "") + symbol(currency) + body
    }

    /// "+US$12.40" / "−US$3.10".
    static func signedMoney(_ value: Double, _ currency: String) -> String {
        (value >= 0 ? "+" : "−") + money(abs(value), currency)
    }

    /// A price can need more than two decimals (crypto under a dollar, ASX half-cents).
    static func price(_ value: Double, _ currency: String) -> String {
        if value > 0, value < 1 { return number(value, decimals: 4, currency: currency) }
        // Yen and won prices still show their fraction when there is one (a 0.1-yen tick).
        if Currencies.decimals(currency) == 0, value != value.rounded() { return number(value, decimals: 1, currency: currency) }
        return money(value, currency)
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        signed ? String(format: "%@%.2f%%", value >= 0 ? "+" : "−", abs(value)) : String(format: "%.2f%%", value)
    }

    static func quantity(_ quantity: Double, _ instrument: Instrument) -> String {
        PaperBroker.quantityText(quantity, for: instrument)
    }

    /// "12 AAPL" / "0.0125 BTC".
    static func units(_ quantity: Double, _ instrument: Instrument) -> String {
        "\(self.quantity(quantity, instrument)) \(instrument.symbol)"
    }

    /// "2 min ago", "Yesterday".
    static func relative(_ date: Date, to now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if abs(now.timeIntervalSince(date)) < 45 { return "Just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// A portfolio's name with "Practice" added only when the name doesn't already say it.
    static func accountName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Practice" }
        return name.localizedCaseInsensitiveContains("practice") ? name : "\(name) · Practice"
    }

    /// "Market buy", "Limit sell".
    static func orderTitle(_ type: OrderType, _ side: OrderSide) -> String {
        "\(type.displayName) \(side == .buy ? "buy" : "sell")"
    }
}

// MARK: - Practice marker

/// The word "Practice" in a dashed capsule. Shown wherever simulated money appears:
/// tab top bars, the order ticket, every order, fill, proposal and agent card.
struct PracticeChip: View {
    var compact = false

    var body: some View {
        Text("Practice")
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 2 : 4)
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            )
            .fixedSize()
            .accessibilityLabel("Practice money, not real")
            .accessibilityIdentifier("trading.practiceChip")
    }
}

/// One line that says what paper trading is, for sheets and confirmation steps.
struct PracticeNote: View {
    var text: LocalizedStringKey = "Practice money. No real order is sent and nothing here is financial advice."
    @Environment(\.theme) private var theme

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "graduationcap")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status

/// A glyph and a word, tinted. The word carries the meaning; the tint only helps.
struct StatusLabel: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
            Text(text)
                .font((compact ? Font.caption : Font.subheadline).weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension OrderStatus {
    var glyph: String {
        switch self {
        case .pendingSubmit: return "arrow.up.circle"
        case .accepted: return "clock"
        case .partiallyFilled: return "circle.lefthalf.filled"
        case .filled: return "checkmark.circle.fill"
        case .canceled: return "slash.circle"
        case .rejected: return "exclamationmark.circle.fill"
        case .expired: return "hourglass"
        }
    }
}

extension ProposalStatus {
    var glyph: String {
        switch self {
        case .pending: return "hand.raised"
        case .submitted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle"
        case .expired: return "hourglass"
        case .blocked: return "shield.slash"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

extension TradingAgent {
    /// "Running", "Paused by you", "Paused: daily loss limit" …
    var statusText: String {
        switch status {
        case .active: return "Running"
        case .stopped: return "Stopped"
        case .paused:
            switch pauseReason {
            case .some(.user), .none: return "Paused by you"
            case .some(.killSwitch): return "Paused by Pause all"
            case .some(.dailyLossLimit): return "Paused: daily loss limit"
            case .some(.drawdownLimit): return "Paused: drawdown limit"
            case .some(.repeatedErrors): return "Paused: no market data"
            }
        }
    }

    var statusGlyph: String {
        switch status {
        case .active: return "play.circle.fill"
        case .paused: return pauseReason == .user || pauseReason == nil ? "pause.circle" : "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        }
    }

    var needsAttention: Bool {
        status == .paused && pauseReason != .user && pauseReason != .killSwitch && pauseReason != nil
    }
}

extension AgentMode {
    var glyph: String {
        switch self {
        case .researchOnly: return "doc.text.magnifyingglass"
        case .signals: return "dot.radiowaves.left.and.right"
        case .paper: return "graduationcap"
        case .approvalRequired: return "hand.raised"
        case .autonomousLive: return "bolt"
        }
    }
}

// MARK: - Gain / loss

/// A signed amount with an arrow: "▲ +US$12.40".
struct GainLossText: View {
    let value: Double
    var text: String
    var font: Font = .subheadline.weight(.semibold).monospacedDigit()
    @Environment(\.theme) private var theme

    private var isFlat: Bool { abs(value) < 0.005 }
    private var tint: Color { isFlat ? theme.secondaryText : (value > 0 ? theme.positiveColor : theme.negativeColor) }

    var body: some View {
        HStack(spacing: 3) {
            if !isFlat {
                Image(systemName: value > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text).font(font).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlat ? "Unchanged" : "\(value > 0 ? "Up" : "Down") \(text.replacingOccurrences(of: "−", with: "").replacingOccurrences(of: "+", with: ""))")
    }
}

// MARK: - Rows and cards

/// "Label ........ value". Stacks at accessibility text sizes so neither side truncates.
struct TradingRow: View {
    let label: LocalizedStringKey
    let value: String
    var emphasised = false
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { labelText; valueText }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    labelText
                    Spacer(minLength: DS.Space.m)
                    valueText.multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label).font(.subheadline).foregroundStyle(theme.secondaryText)
    }

    private var valueText: some View {
        Text(value)
            .font(emphasised ? .body.weight(.semibold).monospacedDigit() : .subheadline.monospacedDigit())
            .foregroundStyle(theme.primaryText)
    }
}

/// A titled group of content on the standard card surface.
struct TradingSection<Content: View>: View {
    let title: LocalizedStringKey
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(theme.secondaryText) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Logo, symbol and name: the leading half of any row about one instrument.
struct InstrumentLabel: View {
    let instrument: Instrument
    var subtitle: String? = nil
    var logoSize: CGFloat = 36
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: instrument.logoSymbol, kind: instrument.assetClass == .crypto ? .crypto : .stock,
                       exchange: instrument.venue == .asx ? "ASX" : "", size: logoSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(instrument.symbol).font(.body.weight(.semibold)).foregroundStyle(theme.primaryText)
                Text(subtitle ?? instrument.name)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Risk checks

extension RiskCheckStatus {
    var glyph: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .notApplicable: return "minus.circle"
        }
    }

    var word: String {
        switch self {
        case .passed: return "Passed"
        case .warning: return "Warning"
        case .failed: return "Blocked"
        case .notApplicable: return "Not applicable"
        }
    }
}

/// The risk engine's verdict on one order: what blocked it first, then warnings, then
/// (folded away) everything that passed.
struct RiskReportView: View {
    let report: RiskReport
    @State private var showAll = false
    @Environment(\.theme) private var theme

    private func tint(_ status: RiskCheckStatus) -> Color {
        switch status {
        case .passed: return theme.positiveColor
        case .warning: return theme.warningColor
        case .failed: return theme.negativeColor
        case .notApplicable: return theme.secondaryText
        }
    }

    private var passed: [RiskCheck] { report.checks.filter { $0.status == .passed } }
    private var skipped: [RiskCheck] { report.checks.filter { $0.status == .notApplicable } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(report.failures) { row($0) }
            ForEach(report.warnings) { row($0) }
            if report.failures.isEmpty && report.warnings.isEmpty {
                StatusLabel(systemImage: "checkmark.shield.fill", text: "All \(passed.count) risk checks passed", tint: theme.positiveColor)
            }
            if !passed.isEmpty || !skipped.isEmpty {
                Button {
                    dsAnimate { showAll.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAll ? "Hide the other checks" : "Show all \(report.checks.count) checks")
                        Image(systemName: "chevron.down").rotationEffect(.degrees(showAll ? 180 : 0)).font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("risk.showAll")
                if showAll {
                    ForEach(passed) { row($0) }
                    ForEach(skipped) { row($0) }
                }
            }
        }
    }

    private func row(_ check: RiskCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: check.status.glyph)
                .font(.subheadline)
                .foregroundStyle(tint(check.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.id.title).font(.subheadline.weight(.semibold))
                Text(check.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.id.title), \(check.status.word). \(check.detail)")
        .accessibilityIdentifier("risk.check.\(check.id.rawValue).\(check.status.rawValue)")
    }
}

// MARK: - Evidence

/// The facts behind a signal: each rule, the numbers it compared, and whether it was met.
struct EvidenceList: View {
    let evidence: [Evidence]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Image(systemName: item.passed == true ? "checkmark" : (item.passed == false ? "xmark" : "circle.fill"))
                        .font(.system(size: item.passed == nil ? 5 : 11, weight: .bold))
                        .foregroundStyle(item.passed == true ? theme.positiveColor : theme.secondaryText)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Text(item.value).font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label): \(item.value)\(item.passed == true ? ", met" : (item.passed == false ? ", not met" : ""))")
            }
        }
    }
}

// MARK: - Equity chart

/// A portfolio's value over time, optionally against a benchmark. With a benchmark both
/// lines are rebased to percent change so they can be compared; the benchmark is dashed so
/// the two are told apart without colour.
struct EquityCurveChart: View {
    let points: [EquityPoint]
    var benchmark: [EquityPoint] = []
    var benchmarkName: String? = nil
    var currency: String = "USD"
    var height: CGFloat = 180
    @Environment(\.theme) private var theme

    private struct Sample: Identifiable {
        let id: Int
        let time: Date
        let value: Double
    }

    private var rebased: Bool { !benchmark.isEmpty }

    private func samples(_ source: [EquityPoint]) -> [Sample] {
        guard let first = source.first?.equity, first > 0 else { return [] }
        // Thin long series so the chart stays light to draw.
        let step = max(1, source.count / 240)
        return source.enumerated().compactMap { index, point in
            guard index % step == 0 || index == source.count - 1 else { return nil }
            return Sample(id: index, time: point.time, value: rebased ? (point.equity / first - 1) * 100 : point.equity)
        }
    }

    private var isUp: Bool { (points.last?.equity ?? 0) >= (points.first?.equity ?? 0) }

    var body: some View {
        let main = samples(points)
        let bench = samples(benchmark)
        if main.count < 2 {
            Text("Not enough history to draw yet.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Chart {
                if rebased {
                    RuleMark(y: .value("Start", 0))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                ForEach(bench) { sample in
                    LineMark(x: .value("Date", sample.time), y: .value("Benchmark", sample.value), series: .value("Series", "Benchmark"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(main) { sample in
                    LineMark(x: .value("Date", sample.time), y: .value("Value", sample.value), series: .value("Series", "Strategy"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(rebased ? theme.primaryText : (isUp ? theme.positiveColor : theme.negativeColor))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(theme.separator.opacity(0.3))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(rebased ? String(format: "%+.0f%%", v) : Self.compact(v))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                        .font(.caption2)
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        }
    }

    private static func compact(_ value: Double) -> String {
        if abs(value) >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if abs(value) >= 10_000 { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    /// One sentence that says what the chart shows, for VoiceOver.
    private var summary: String {
        guard let first = points.first?.equity, let last = points.last?.equity, first > 0 else { return "Value chart" }
        var text = String(format: "Value went from %@ to %@, %@.", TradingFormat.money(first, currency),
                          TradingFormat.money(last, currency), TradingFormat.percent((last / first - 1) * 100))
        if let b0 = benchmark.first?.equity, let b1 = benchmark.last?.equity, b0 > 0 {
            text += String(format: " %@ changed %@.", benchmarkName ?? "The benchmark", TradingFormat.percent((b1 / b0 - 1) * 100))
        }
        return text
    }
}

// MARK: - Where it lives

/// "On this phone" or "In your account", and whether the account could be reached.
struct TradingHomeBadge: View {
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if trading.isSwitching {
                    ProgressView().controlSize(.mini)
                    Text("Connecting to your account…")
                } else {
                    Image(systemName: trading.isAccount ? "icloud" : "iphone")
                    Text(trading.homeDescription)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            if let problem = trading.syncProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trading.syncProblem")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(trading.isAccount ? "trading.home.account" : "trading.home.device")
    }
}

// MARK: - Pause-all banner

/// Shown under the top bar on every trading screen while the kill switch is on.
struct PausedAllBanner: View {
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    var onResume: (() -> Void)? = nil

    var body: some View {
        if trading.isKillSwitchOn {
            HStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "pause.circle.fill").font(.body)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All agents are paused").font(.subheadline.weight(.semibold))
                        if let at = trading.state.accountPolicy.killSwitchAt {
                            Text("Since \(TradingFormat.time(at)). No agent can place orders.")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: DS.Space.s)
                if let onResume {
                    Button("Review", action: onResume)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Review pause-all")
                        .accessibilityIdentifier("trading.pausedAllBanner.review")
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trading.pausedAllBanner")
        }
    }
}
