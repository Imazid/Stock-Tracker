//
//  DSCharts.swift
//  Stock Tracker
//
//  One chart language for the whole app, after Robinhood / Public / Stake /
//  Perplexity Finance on Mobbin:
//  - colour = the displayed period's direction (last vs baseline)
//  - dashed baseline = previous close on 1D, the first point otherwise
//  - press-and-drag scrubbing: vertical rule, dot, time pill, the rest of the
//    line dims; the parent's header shows the scrubbed value via `selection`
//  - 1D on a real session time axis (the line grows through the day);
//    multi-day intraday ranges on an ordinal axis so nights/weekends don't
//    draw fake flat lines
//  - y-domain hugs the data (never forced to 0)
//  - honest states: loading (keeps the old line dimmed), empty, failed+retry
//  - VoiceOver audio graph via AXChartDescriptor
//
//  Charts never invent data: give them real points or an error.
//

import SwiftUI
import Charts
import OSLog

// MARK: - Model

struct DSChartPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension Array where Element == PricePoint {
    var chartPoints: [DSChartPoint] { map { DSChartPoint(date: $0.date, value: $0.price) } }
}

enum DSChartPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

enum DSChartXMode: Equatable {
    /// True time axis; pass `domain` (e.g. today's session) to leave room for the rest of the day.
    case time(domain: ClosedRange<Date>?)
    /// Evenly spaced points — use for multi-day intraday data.
    case ordinal
}

extension TimeRange {
    /// 1D is drawn on a time axis; everything else compresses non-trading time.
    var prefersTimeAxis: Bool { self == .oneDay }

    /// Readout format for a scrubbed point in this range.
    func scrubLabel(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        switch self {
        case .oneDay:              f.dateFormat = "h:mm a"
        case .oneWeek:             f.dateFormat = "EEE d MMM, h:mm a"
        case .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear:
                                   f.dateFormat = "EEE d MMM yyyy"
        default:                   f.dateFormat = "MMM yyyy"
        }
        return f.string(from: date)
    }

    /// Words for the period, used next to the change ("Past week").
    var periodLabel: LocalizedStringKey {
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

// MARK: - Price chart

struct DSPriceChart: View {
    let points: [DSChartPoint]
    var phase: DSChartPhase = .loaded
    /// Reference value for colour + dashed line. nil → first point.
    var baseline: Double? = nil
    /// Small label on the baseline, e.g. "Prev close".
    var baselineLabel: String? = nil
    var xMode: DSChartXMode = .ordinal
    var height: CGFloat = 220
    var showsYAxis = false
    var valueText: (Double) -> String = { String(format: "%.2f", $0) }
    var dateText: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    var selection: Binding<DSChartPoint?>? = nil
    var onRetry: (() -> Void)? = nil
    var accessibilityID: String = "chart.price"
    var range: TimeRange? = nil

    @Environment(\.theme) private var theme
    /// Raw x under the finger, in the plotted unit (index, or seconds since reference date).
    @State private var rawX: Double?
    // MARK: Derived

    private var reference: Double? { baseline ?? points.first?.value }

    private var isUp: Bool {
        guard let last = points.last?.value, let ref = reference else { return true }
        return last >= ref
    }

    private var tint: Color { isUp ? theme.positiveColor : theme.negativeColor }

    private var yDomain: ClosedRange<Double> {
        var values = points.map(\.value)
        if let baseline { values.append(baseline) }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = hi - lo
        let pad = max(span * 0.08, abs(hi) * 0.002, 0.0001)
        return (lo - pad)...(hi + pad)
    }

    private var activeIndex: Int? {
        guard let rawX, !points.isEmpty else { return nil }
        switch xMode {
        case .ordinal:
            return min(max(Int(rawX.rounded()), 0), points.count - 1)
        case .time:
            return nearestIndex(to: Date(timeIntervalSinceReferenceDate: rawX))
        }
    }

    /// 0…1 position of the selection along the *line's own* extent (Charts maps a
    /// mark's gradient to its bounds), for dimming the part after the finger.
    private var selectionFraction: Double? {
        guard let i = activeIndex, points.count > 1 else { return nil }
        switch xMode {
        case .ordinal:
            return Double(i) / Double(points.count - 1)
        case .time:
            let span = points.last!.date.timeIntervalSince(points.first!.date)
            guard span > 0 else { return nil }
            return min(max(points[i].date.timeIntervalSince(points.first!.date) / span, 0), 1)
        }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            if points.count >= 2 {
                chart
                    .opacity(phase == .loading ? 0.45 : 1)
                    .motionSafeAnimation(DS.quick, value: phase == .loading)
            } else {
                placeholder
            }
            if phase == .loading && points.count >= 2 {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: height)
        .accessibilityIdentifier(accessibilityID)
        .onChange(of: range) {
            rawX = nil
            selection?.wrappedValue = nil
        }
        .onChange(of: activeIndex) { _, index in
            selection?.wrappedValue = index.map { points[$0] }
            #if DEBUG
            if let index { AppLogger.general.notice("CHARTSCRUB \(accessibilityID) index=\(index) value=\(points[index].value)") }
            #endif
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch phase {
        case .loading:
            ChartLoadingSkeleton()
        case .failed(let message):
            chartNote(icon: "chart.line.downtrend.xyaxis", title: "Chart unavailable", detail: message, retry: onRetry)
        case .loaded:
            chartNote(icon: "chart.xyaxis.line", title: "No price history for this period", detail: nil, retry: onRetry)
        }
    }

    private func chartNote(icon: String, title: LocalizedStringKey, detail: String?, retry: (() -> Void)?) -> some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let retry {
                Button("Try again") {
                    Haptics.tap()
                    retry()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.accent)
                .frame(minHeight: 44)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var chart: some View {
        let domain = yDomain
        let lineStyle: AnyShapeStyle = {
            if let f = selectionFraction {
                return AnyShapeStyle(LinearGradient(
                    stops: [
                        .init(color: tint, location: 0),
                        .init(color: tint, location: f),
                        .init(color: tint.opacity(0.28), location: min(f + 0.0001, 1)),
                        .init(color: tint.opacity(0.28), location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing))
            }
            return AnyShapeStyle(tint)
        }()

        let base = Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                AreaMark(
                    x: xValue(index: index, point: point),
                    yStart: .value("Low", domain.lowerBound),
                    yEnd: .value("Price", point.value)
                )
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)

                LineMark(x: xValue(index: index, point: point), y: .value("Price", point.value))
                    .foregroundStyle(lineStyle)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }

            if let ref = reference {
                RuleMark(y: .value("Baseline", ref))
                    .foregroundStyle(theme.secondaryText.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        if let baselineLabel, activeIndex == nil {
                            Text("\(baselineLabel) \(valueText(ref))")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.background.opacity(0.85)))
                        }
                    }
            }

            // The latest price: a dot with a soft halo (Fey / Revolut), hidden while scrubbing.
            if activeIndex == nil, let lastIndex = points.indices.last {
                let p = points[lastIndex]
                PointMark(x: xValue(index: lastIndex, point: p), y: .value("Price", p.value))
                    .symbolSize(260)
                    .foregroundStyle(tint.opacity(0.18))
                PointMark(x: xValue(index: lastIndex, point: p), y: .value("Price", p.value))
                    .symbolSize(44)
                    .foregroundStyle(tint)
            }

            if let i = activeIndex {
                let p = points[i]
                RuleMark(x: xValue(index: i, point: p))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(dateText(p.date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.cardBackground))
                            .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                    }
                PointMark(x: xValue(index: i, point: p), y: .value("Price", p.value))
                    .symbolSize(70)
                    .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        // Only the plot draws in; the y-axis labels stay put.
        .chartPlotStyle { plot in
            plot.chartPlotReveal(range, isScrubbing: rawX != nil)
        }
        .chartYAxis {
            if showsYAxis {
                // Labels only, no grid lines: the line and its baseline carry the chart.
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(valueText(v)).font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
        }
        .accessibilityChartDescriptor(DSChartDescriptor(points: points, valueText: valueText, dateText: dateText))

        switch xMode {
        case .ordinal:
            base
                .chartXScale(domain: 0...Double(max(points.count - 1, 1)))
                .chartXSelection(value: $rawX)
                .sensoryFeedback(.selection, trigger: activeIndex)
        case .time(let sessionDomain):
            let lo = min(sessionDomain?.lowerBound ?? points.first!.date, points.first!.date)
            let hi = max(sessionDomain?.upperBound ?? points.last!.date, points.last!.date)
            base
                .chartXScale(domain: lo.timeIntervalSinceReferenceDate...max(hi.timeIntervalSinceReferenceDate, lo.timeIntervalSinceReferenceDate + 1))
                .chartXSelection(value: $rawX)
                .sensoryFeedback(.selection, trigger: activeIndex)
        }
    }

    private func xValue(index: Int, point: DSChartPoint) -> PlottableValue<Double> {
        switch xMode {
        case .ordinal: return .value("Index", Double(index))
        case .time:    return .value("Time", point.date.timeIntervalSinceReferenceDate)
        }
    }

    private func nearestIndex(to date: Date) -> Int {
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(points[lo - 1].date.timeIntervalSince(date)) < abs(points[lo].date.timeIntervalSince(date)) {
            return lo - 1
        }
        return lo
    }
}

// MARK: - Sparkline

/// Lightweight line for list rows. Renders nothing (keeps its frame) with fewer
/// than two real points — it never draws a placeholder line.
struct DSSparkline: View {
    let values: [Double]
    var baseline: Double? = nil
    var lineWidth: CGFloat = 1.5
    @Environment(\.theme) private var theme

    private var isUp: Bool {
        guard let last = values.last, let ref = baseline ?? values.first else { return true }
        return last >= ref
    }

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let lo = min(values.min()!, baseline ?? .infinity)
                let hi = max(values.max()!, baseline ?? -.infinity)
                let span = max(hi - lo, abs(hi) * 0.0005, 0.000_001)
                let w = geo.size.width, h = geo.size.height
                let y: (Double) -> CGFloat = { h - CGFloat(($0 - lo) / span) * h }
                ZStack {
                    if let baseline {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y(baseline)))
                            p.addLine(to: CGPoint(x: w, y: y(baseline)))
                        }
                        .stroke(theme.secondaryText.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                    }
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: w * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                    }
                    .stroke(isUp ? theme.positiveColor : theme.negativeColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Range picker

struct DSRangePicker: View {
    let options: [TimeRange]
    @Binding var selection: TimeRange
    var tint: Color = DS.accent
    @Environment(\.theme) private var theme

    static let standard: [TimeRange] = [.oneDay, .oneWeek, .oneMonth, .threeMonths, .ytd, .oneYear, .fiveYears]

    @Namespace private var chip

    var body: some View {
        // A capsule track with a raised chip that slides to the selection (Revolut / Coinbase).
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    guard !isOn else { return }
                    Haptics.select()
                    dsAnimate(DS.spring) { selection = option }
                } label: {
                    Text(option.rawValue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isOn ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(theme.isDark ? Color.white.opacity(0.14) : Color.white)
                                    .shadow(color: .black.opacity(theme.isDark ? 0 : 0.08), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "chip", in: chip)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(option.accessibilityName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)))
    }
}

extension TimeRange {
    var accessibilityName: String {
        switch self {
        case .oneDay: return "1 day"
        case .oneWeek: return "1 week"
        case .oneMonth: return "1 month"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .ytd: return "Year to date"
        case .oneYear: return "1 year"
        case .twoYears: return "2 years"
        case .fiveYears: return "5 years"
        case .tenYears: return "10 years"
        case .all: return "All time"
        }
    }
}

// MARK: - VoiceOver audio graph

struct DSChartDescriptor: AXChartDescriptorRepresentable {
    let points: [DSChartPoint]
    let valueText: (Double) -> String
    let dateText: (Date) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = points.map(\.value)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let x = AXCategoricalDataAxisDescriptor(
            title: "Time",
            categoryOrder: points.map { dateText($0.date) }
        )
        let y = AXNumericDataAxisDescriptor(
            title: "Price",
            range: lo...max(hi, lo + 0.0001),
            gridlinePositions: []
        ) { valueText($0) }
        let series = AXDataSeriesDescriptor(
            name: "Price",
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: dateText($0.date), y: $0.value) }
        )
        let change: String = {
            guard let f = points.first?.value, let l = points.last?.value, f != 0 else { return "" }
            let pct = (l - f) / f * 100
            return String(format: " %@ %.2f%%", pct >= 0 ? "up" : "down", abs(pct))
        }()
        return AXChartDescriptor(
            title: "Price chart",
            summary: "From \(valueText(points.first?.value ?? 0)) to \(valueText(points.last?.value ?? 0)),\(change)",
            xAxis: x,
            yAxis: y,
            additionalAxes: [],
            series: [series]
        )
    }
}
