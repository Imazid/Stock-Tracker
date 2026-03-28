//
//  InteractivePriceChart.swift
//  Stock Tracker
//

import SwiftUI
import Charts

// MARK: - Chart Display Type (shared enum)

/// Controls whether the chart renders as a line/area chart or candlestick chart.
enum ChartDisplayType: String {
    case line   = "line"
    case candle = "candle"
}

// MARK: - Interactive Price Chart

struct InteractivePriceChart: View {
    @Binding var selectedRange: ChartTimeRange
    @Binding var chartType: ChartDisplayType
    let chartData: [ChartDataPoint]
    let candleData: [Candle]
    let isLoadingCandles: Bool
    let stock: DetailedStock
    let isLive: Bool
    @Binding var scrubbedPoint: ChartDataPoint?

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private var chartColor: Color { stock.isPositive ? .green : .red }

    // MARK: - Y-axis domains

    private var yDomain: ClosedRange<Double> {
        let prices = chartData.map { $0.price }
        let minP = prices.min() ?? 0
        let maxP = prices.max() ?? 1
        let pad = max((maxP - minP) * 0.04, maxP * 0.005)
        return max(0, minP - pad)...(maxP + pad)
    }

    private var candleYDomain: ClosedRange<Double> {
        let highs = candleData.map { $0.high }
        let lows  = candleData.map { $0.low }
        let minP  = lows.min()  ?? 0
        let maxP  = highs.max() ?? 1
        let pad   = max((maxP - minP) * 0.08, maxP * 0.005)
        return max(0, minP - pad)...(maxP + pad)
    }

    /// Dynamic bar width — wider when fewer candles are on screen.
    private var candleBarWidth: Double {
        let count = candleData.count
        if count <= 35  { return 0.8  }
        if count <= 90  { return 0.65 }
        if count <= 252 { return 0.55 }
        return 0.45
    }

    // Opening price for the dashed reference line.
    // For 1D this is the market open price; for longer ranges it's the period's first data point.
    // The line position determines whether the current price reads as gain (above) or loss (below).
    private var openPrice: Double {
        chartData.first?.price ?? 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if chartType == .candle {
                candleChartView
            } else {
                lineChartView
            }

            // Date axis labels below chart (line chart only)
            if chartType != .candle {
                dateAxisView
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }

            Spacer().frame(minHeight: 8, maxHeight: 12)
            timeRangeSelector
        }
    }

    // MARK: - Date Axis

    private var dateAxisView: some View {
        let count = 4
        guard chartData.count >= 2 else { return AnyView(EmptyView()) }

        // Pick count evenly-spaced indices (always include first and last)
        let indices: [Int] = (0..<count).map { i in
            i == 0 ? 0
                : i == count - 1 ? chartData.count - 1
                : (chartData.count - 1) * i / (count - 1)
        }
        let pts = indices.map { chartData[$0] }

        return AnyView(
            HStack(spacing: 0) {
                ForEach(pts.indices, id: \.self) { i in
                    if i > 0 { Spacer() }
                    Text(pts[i].date, format: axisDateFormat)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
        )
    }

    private var axisDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .oneDay:
            return .dateTime.hour().minute()
        case .oneWeek, .oneMonth:
            return .dateTime.month(.abbreviated).day()
        case .threeMonths, .oneYear:
            return .dateTime.month(.abbreviated).year(.twoDigits)
        case .fiveYears, .all:
            return .dateTime.year()
        }
    }

    // MARK: - Line Chart

    private var lineChartView: some View {
        Chart {
            // Gradient area fill — anchored to domain bottom for premium feel
            ForEach(chartData) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Price", point.price)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [chartColor.opacity(0.28), chartColor.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }

            // Line
            ForEach(chartData) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Price", point.price)
                )
                .foregroundStyle(chartColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
            }

            // Opening price reference line — price starts here, chart is green above / red below
            if !chartData.isEmpty {
                RuleMark(y: .value("Open", openPrice))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            // Crosshair while scrubbing
            if let p = scrubbedPoint {
                RuleMark(x: .value("Selected", p.date))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(
                    x: .value("Selected", p.date),
                    y: .value("Price", p.price)
                )
                .symbol(.circle)
                .symbolSize(80)
                .foregroundStyle(chartColor)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let date: Date = proxy.value(atX: value.location.x) else { return }
                                if let closest = chartData.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                }) {
                                    if scrubbedPoint?.id != closest.id {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                    scrubbedPoint = closest
                                }
                            }
                            .onEnded { _ in scrubbedPoint = nil }
                    )
            }
        }
        .padding(.horizontal)
        .frame(height: 210)
        .clipped()
    }

    // MARK: - Candlestick Chart

    private var candleChartView: some View {
        Group {
            if candleData.isEmpty {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 240)
                    if isLoadingCandles {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading candlestick data…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis.ascending.badge.clock")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Candlestick data unavailable")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                            Text("Try a different time range")
                                .font(.caption)
                                .foregroundColor(Color(UIColor.tertiaryLabel))
                        }
                    }
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    Chart {
                        ForEach(candleData) { candle in
                            let bullish = candle.isBullish
                            let bodyColor: Color = bullish ? .green : .red
                            let isLastCandle = isLive && candle.id == candleData.last?.id

                            // Wick: high → low
                            RuleMark(
                                x: .value("Date", candle.date),
                                yStart: .value("Low", candle.low),
                                yEnd: .value("High", candle.high)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(bodyColor.opacity(isLastCandle ? 0.9 : 0.7))

                            // Body: open → close
                            BarMark(
                                x: .value("Date", candle.date),
                                yStart: .value("BodyLow",  min(candle.open, candle.close)),
                                yEnd:   .value("BodyHigh", max(candle.open, candle.close)),
                                width: .ratio(candleBarWidth)
                            )
                            .foregroundStyle(bullish
                                ? Color.green.opacity(isLastCandle ? 1.0 : 0.95)
                                : Color.red.opacity(isLastCandle ? 1.0 : 0.95))
                        }

                        // Crosshair while scrubbing
                        if let p = scrubbedPoint {
                            RuleMark(x: .value("Selected", p.date))
                                .foregroundStyle(Color.primary.opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .chartYScale(domain: candleYDomain)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Color.secondary.opacity(0.15))
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            guard let date: Date = proxy.value(atX: value.location.x) else { return }
                                            if let closest = candleData.min(by: {
                                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                            }) {
                                                let pt = ChartDataPoint(date: closest.date, price: closest.close, volume: closest.volume)
                                                if scrubbedPoint?.date != closest.date {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                }
                                                scrubbedPoint = pt
                                            }
                                        }
                                        .onEnded { _ in scrubbedPoint = nil }
                                )
                        }
                    }
                    .padding(.horizontal)
                    .frame(height: 240)
                    .clipped()

                    // LIVE badge
                    if isLive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                                .modifier(PulseModifier(reduceMotion: reduceMotion))
                            Text("LIVE")
                                .font(.caption2.bold())
                                .foregroundColor(.green)
                        }
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ChartTimeRange.allCases, id: \.self) { range in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedRange = range
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(selectedRange == range ? .semibold : .regular))
                            .foregroundColor(selectedRange == range ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedRange == range ? Color.secondary.opacity(0.15) : Color.clear
                            )
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseModifier: ViewModifier {
    let reduceMotion: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}
