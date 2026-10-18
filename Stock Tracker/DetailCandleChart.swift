//
//  DetailCandleChart.swift
//  Stock Tracker
//
//  Candlesticks from real OHLC only (`PriceHistoryService.candles`). Drawn on
//  an ordinal axis so nights and weekends don't leave gaps; long ranges are
//  merged into wider real candles (first open, highest high, lowest low, last
//  close) rather than thinned. Scrubbing reports the candle under the finger
//  so the header can show O/H/L/C. Same honest states as `DSPriceChart`.
//

import SwiftUI
import Charts

struct DetailCandleChart: View {
    let candles: [Candle]
    var phase: DSChartPhase = .loaded
    var height: CGFloat = 240
    var maxCandles = 90
    var valueText: (Double) -> String
    var dateText: (Date) -> String
    var selection: Binding<Candle?>? = nil
    var onRetry: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var rawX: Double?

    /// Real candles merged into at most `maxCandles` buckets.
    private var shown: [Candle] {
        Self.merge(candles, maxCount: maxCandles)
    }

    static func merge(_ candles: [Candle], maxCount: Int) -> [Candle] {
        guard candles.count > maxCount, maxCount > 0 else { return candles }
        let size = Int((Double(candles.count) / Double(maxCount)).rounded(.up))
        return stride(from: 0, to: candles.count, by: size).map { start in
            let slice = candles[start..<min(start + size, candles.count)]
            return Candle(
                date: slice.first!.date,
                open: slice.first!.open,
                high: slice.map(\.high).max()!,
                low: slice.map(\.low).min()!,
                close: slice.last!.close,
                volume: nil
            )
        }
    }

    var body: some View {
        let data = shown
        ZStack {
            if data.count >= 2 {
                chart(data)
                    .opacity(phase == .loading ? 0.45 : 1)
                    .animation(DS.quick, value: phase == .loading)
                if phase == .loading { ProgressView().controlSize(.small) }
            } else {
                placeholder
            }
        }
        .frame(height: height)
        .accessibilityIdentifier("chart.candles")
        .onChange(of: rawX) { _, x in
            guard let x, !data.isEmpty else { selection?.wrappedValue = nil; return }
            let i = min(max(Int(x.rounded()), 0), data.count - 1)
            if selection?.wrappedValue?.date != data[i].date { selection?.wrappedValue = data[i] }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch phase {
        case .loading:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.subtleFill)
                .overlay(ProgressView().controlSize(.small))
                .accessibilityLabel("Loading candles")
        case .failed(let message):
            note(title: "Candles unavailable", detail: message)
        case .loaded:
            note(title: "No candles for this period", detail: nil)
        }
    }

    private func note(title: LocalizedStringKey, detail: String?) -> some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "chart.bar.xaxis")
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
            if let onRetry {
                Button("Try again") {
                    Haptics.tap()
                    onRetry()
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

    private func chart(_ data: [Candle]) -> some View {
        let lo = data.map(\.low).min() ?? 0
        let hi = data.map(\.high).max() ?? 1
        let pad = max((hi - lo) * 0.08, abs(hi) * 0.002, 0.0001)
        let selectedIndex: Int? = rawX.map { min(max(Int($0.rounded()), 0), data.count - 1) }
        let halfWidth = data.count > 60 ? 0.3 : 0.36
        let minBody = (hi - lo) * 0.004

        return Chart {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, candle in
                let tint = candle.close >= candle.open ? theme.positiveColor : theme.negativeColor
                RuleMark(
                    x: .value("Index", Double(index)),
                    yStart: .value("Low", candle.low),
                    yEnd: .value("High", candle.high)
                )
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(tint.opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.4))

                RectangleMark(
                    xStart: .value("Start", Double(index) - halfWidth),
                    xEnd: .value("End", Double(index) + halfWidth),
                    yStart: .value("Open", min(candle.open, candle.close)),
                    yEnd: .value("Close", max(max(candle.open, candle.close), min(candle.open, candle.close) + minBody))
                )
                .foregroundStyle(tint.opacity(selectedIndex == nil || selectedIndex == index ? 1 : 0.4))
            }
            if let i = selectedIndex {
                RuleMark(x: .value("Index", Double(i)))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(dateText(data[i].date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.cardBackground))
                            .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                    }
            }
        }
        .chartXScale(domain: -0.6...(Double(data.count) - 0.4))
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(theme.cardBorder.opacity(0.35))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(valueText(v)).font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .chartXSelection(value: $rawX)
        .sensoryFeedback(.selection, trigger: selectedIndex)
        .accessibilityLabel("Candlestick chart, \(data.count) candles")
        .accessibilityValue(data.last.map { "Latest close \(valueText($0.close))" } ?? "")
    }
}
