//  PortfolioHeroView.swift
//  Stock Tracker
//  Premium hero section: value header, interactive Swift Charts line chart with
//  crosshair scrubbing, compact volume/activity bar chart, time-range selector.

import SwiftUI
import Charts

// MARK: - Activity Bar Model

private struct ActivityBar: Identifiable {
    let id = UUID()
    let date: Date
    let magnitude: Double
}

// MARK: - PortfolioHeroView

struct PortfolioHeroView: View {
    let totalValue: Double
    let totalCostBasis: Double
    let history: [PortfolioSnapshot]
    let dailyPL: Double
    let dailyPLPercent: Double
    let totalPL: Double
    let totalPLPercent: Double
    @Binding var selectedRange: PortfolioChartRange
    @Binding var scrubbedSnapshot: PortfolioSnapshot?

    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @AppStorage("portfolioValueHidden") private var valueHidden = false

    // MARK: - Computed Properties

    private var filteredHistory: [PortfolioSnapshot] {
        selectedRange.filter(history).sorted { $0.date < $1.date }
    }

    private var rangeChange: Double {
        let current = scrubbedSnapshot?.totalValue ?? filteredHistory.last?.totalValue ?? totalValue
        let base = filteredHistory.first?.totalValue ?? totalValue
        return current - base
    }

    private var rangeChangePercent: Double {
        let base = max(1, filteredHistory.first?.totalValue ?? 1)
        return rangeChange / base * 100
    }

    private var displayValue: Double {
        scrubbedSnapshot?.totalValue ?? totalValue
    }

    private var isRangePositive: Bool {
        rangeChange >= 0
    }

    private var rangeColor: Color {
        isRangePositive ? appTheme.positiveColor : appTheme.negativeColor
    }

    private var chartDomain: ClosedRange<Double> {
        let values = filteredHistory.map { $0.totalValue }
        guard let minVal = values.min(), let maxVal = values.max(), minVal != maxVal else {
            let base = filteredHistory.first?.totalValue ?? totalValue
            return (base * 0.92)...(base * 1.08)
        }
        let padding = (maxVal - minVal) * 0.08
        return (minVal - padding)...(maxVal + padding)
    }

    private var medianValue: Double {
        let values = filteredHistory.map { $0.totalValue }.sorted()
        guard !values.isEmpty else { return totalValue }
        if values.count % 2 == 1 {
            return values[values.count / 2]
        } else {
            return (values[values.count / 2 - 1] + values[values.count / 2]) / 2.0
        }
    }

    private var activityBars: [ActivityBar] {
        let sorted = filteredHistory
        guard sorted.count > 1 else { return [] }
        return zip(sorted, sorted.dropFirst()).map { prev, curr in
            ActivityBar(date: curr.date, magnitude: abs(curr.totalValue - prev.totalValue))
        }
    }

    private var formattedScrubDate: String {
        guard let snap = scrubbedSnapshot else { return "Portfolio Value" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: snap.date)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            valueHeader
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            timeRangeSelector
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if filteredHistory.count > 1 {
                mainChart
                    .padding(.horizontal, 4)

                volumeChart
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            } else {
                emptyChartPlaceholder
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Value Header

    private var valueHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label row + refresh badge
            HStack {
                Text(scrubbedSnapshot == nil ? "Portfolio" : formattedScrubDate)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: scrubbedSnapshot?.id)
                Spacer(minLength: 0)
                RefreshStatusBadge()
            }

            // Main value — tap to hide/show
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if valueHidden {
                    Text("••••••")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                } else {
                    Text(marketData.formatPrice(displayValue))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.15), value: displayValue)
                }

                Image(systemName: valueHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    valueHidden.toggle()
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            // Range change pill
            if valueHidden {
                HStack(spacing: 4) {
                    Image(systemName: isRangePositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text("••••")
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(rangeColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(rangeColor.opacity(0.10))
                .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: isRangePositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(marketData.formatPrice(abs(rangeChange)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Text(String(format: "%+.2f%%", rangeChangePercent))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundColor(rangeColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(rangeColor.opacity(0.10))
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - Main Chart

    private var mainChart: some View {
        Chart {
            // Area fill
            ForEach(filteredHistory) { snapshot in
                AreaMark(
                    x: .value("Date", snapshot.date),
                    yStart: .value("Base", chartDomain.lowerBound),
                    yEnd: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [rangeColor.opacity(0.22), rangeColor.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }

            // Line
            ForEach(filteredHistory) { snapshot in
                LineMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(rangeColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)
            }

            // Median rule
            RuleMark(y: .value("Median", medianValue))
                .foregroundStyle(Color.secondary.opacity(0.28))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

            // Scrub crosshair
            if let scrubbed = scrubbedSnapshot {
                RuleMark(x: .value("Scrub", scrubbed.date))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(
                    x: .value("Date", scrubbed.date),
                    y: .value("Value", scrubbed.totalValue)
                )
                .symbolSize(0)
                .annotation(position: .overlay, spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(rangeColor.opacity(0.18))
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(Color(UIColor.systemBackground))
                            .frame(width: 13, height: 13)
                        Circle()
                            .fill(rangeColor)
                            .frame(width: 7, height: 7)
                    }
                    .shadow(color: rangeColor.opacity(0.35), radius: 5)
                }
            }
        }
        .chartYScale(domain: chartDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 185)
        .clipped()
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let xPos = value.location.x
                                guard
                                    let date: Date = proxy.value(atX: xPos),
                                    !filteredHistory.isEmpty
                                else { return }

                                let nearest = filteredHistory.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                })

                                if nearest?.id != scrubbedSnapshot?.id {
                                    let generator = UISelectionFeedbackGenerator()
                                    generator.selectionChanged()
                                    withAnimation(.easeInOut(duration: 0.1)) {
                                        scrubbedSnapshot = nearest
                                    }
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.25)) {
                                    scrubbedSnapshot = nil
                                }
                            }
                    )
            }
        }
    }

    // MARK: - Volume / Activity Chart

    private var volumeChart: some View {
        let bars = activityBars
        let maxMag = bars.map { $0.magnitude }.max() ?? 1

        return Chart(bars) { bar in
            BarMark(
                x: .value("Date", bar.date),
                y: .value("Activity", bar.magnitude)
            )
            .foregroundStyle(rangeColor.opacity(0.30))
            .cornerRadius(2)
        }
        .chartYScale(domain: 0...(maxMag * 1.3))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 32)
        .clipped()
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(PortfolioChartRange.allCases, id: \.self) { range in
                let isSelected = selectedRange == range
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedRange = range
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(range.rawValue)
                        .font(.caption.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? rangeColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(rangeColor.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .cornerRadius(12)
    }

    // MARK: - Empty State

    private var emptyChartPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color(.systemGray6) : Color(red: 0.929, green: 0.910, blue: 0.878))
                .frame(height: 185)

            VStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))

                Text("History builds after first refresh")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
