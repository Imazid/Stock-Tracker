//
//  PremiumWidgets.swift
//  Stock Tracker Widget
//
//  Three Pro / Black tier widgets:
//    1. AssetAllocationWidget  — mini pie chart (.systemSmall, .systemMedium)
//    2. RiskScoreWidget        — arc gauge (.systemSmall)
//    3. WeeklyPerformanceWidget — bar chart (.systemMedium)
//
//  Free-tier users see a TokenPremiumGateView instead of content.
//

import WidgetKit
import SwiftUI

// MARK: - Shared Premium Entry

struct PremiumEntry: TimelineEntry {
    let date: Date
    let data: WidgetPremiumData
}

// MARK: - Shared Premium Provider

struct PremiumProvider: TimelineProvider {
    func placeholder(in context: Context) -> PremiumEntry {
        PremiumEntry(date: Date(), data: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (PremiumEntry) -> Void) {
        completion(PremiumEntry(date: Date(), data: context.isPreview ? .placeholder : (WidgetPremiumData.read() ?? .placeholder)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PremiumEntry>) -> Void) {
        let data = WidgetPremiumData.read() ?? .placeholder
        let entry = PremiumEntry(date: Date(), data: data)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Legacy Gate (kept for backward compat; now forwards to TokenPremiumGateView)

struct PremiumGateView: View {
    let featureName: String
    var body: some View {
        TokenPremiumGateView(featureName: featureName)
    }
}

// MARK: ─────────────────────────────────────────────────────────────────────
// MARK: 1. ASSET ALLOCATION WIDGET
// MARK: ─────────────────────────────────────────────────────────────────────

struct AssetAllocationEntryView: View {
    var entry: PremiumEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if entry.data.isPremium {
            switch family {
            case .systemMedium: AllocationMediumView(data: entry.data)
            default:            AllocationSmallView(data: entry.data)
            }
        } else {
            PremiumGateView(featureName: "Asset\nAllocation")
        }
    }
}

// MARK: Allocation — Small

struct AllocationSmallView: View {
    let data: WidgetPremiumData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeaderRow(icon: "chart.pie.fill", title: "Allocation")
                .padding(.bottom, 8)

            Spacer()

            ZStack {
                AllocationPieView(slices: data.allocationSlices, size: 72)
                Text("\(data.allocationSlices.count > 1 ? "\(data.allocationSlices.count - 1)" : "0")\nHoldings")
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(WidgetColor.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(data.allocationSlices.prefix(2)) { slice in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(red: slice.colorR, green: slice.colorG, blue: slice.colorB))
                            .frame(width: 5, height: 5)
                        Text(slice.symbol)
                            .font(WidgetFont.microTiny(.semibold))
                            .foregroundColor(WidgetColor.textPrimary)
                        Spacer()
                        Text(String(format: "%.1f%%", slice.percent))
                            .font(WidgetFont.microTiny())
                            .foregroundColor(WidgetColor.textSecondary)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asset allocation, \(data.allocationSlices.count) holdings")
    }
}

// MARK: Allocation — Medium

struct AllocationMediumView: View {
    let data: WidgetPremiumData

    var body: some View {
        HStack(spacing: WidgetSpacing.sectionGap) {
            ZStack {
                AllocationPieView(slices: data.allocationSlices, size: 100)
                VStack(spacing: 0) {
                    MicroLabel(text: "Portfolio")
                    Text("Mix")
                        .font(WidgetFont.microSmall(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                }
            }
            .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 0) {
                MicroLabel(text: "Asset Allocation")
                    .padding(.bottom, 8)

                ForEach(Array(data.allocationSlices.enumerated()), id: \.1.id) { i, slice in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: slice.colorR, green: slice.colorG, blue: slice.colorB))
                            .frame(width: 10, height: 10)
                        Text(slice.symbol)
                            .font(WidgetFont.microSmall(.semibold))
                            .foregroundColor(WidgetColor.textPrimary)
                        Spacer()
                        Text(String(format: "%.1f%%", slice.percent))
                            .font(WidgetFont.microSmall(.bold))
                            .foregroundColor(WidgetColor.textSecondary)
                    }
                    .padding(.vertical, 3)

                    if i < data.allocationSlices.count - 1 {
                        Rectangle().fill(WidgetGlass.strokeColor).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Asset allocation, \(data.allocationSlices.count) holdings")
    }
}

// MARK: Pie Chart Shape

struct AllocationPieView: View {
    let slices: [AllocationSlice]
    let size: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2
            let innerRadius = radius * 0.45
            let total = slices.reduce(0) { $0 + $1.percent }
            guard total > 0 else { return }

            var startAngle = Angle.degrees(-90)

            for slice in slices {
                let sweep = Angle.degrees(360 * slice.percent / total)
                let endAngle = startAngle + sweep

                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius,
                            startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.closeSubpath()

                ctx.fill(path, with: .color(
                    Color(red: slice.colorR, green: slice.colorG, blue: slice.colorB)
                ))

                startAngle = endAngle
            }

            let hole = Path(ellipseIn: CGRect(
                x: center.x - innerRadius, y: center.y - innerRadius,
                width: innerRadius * 2, height: innerRadius * 2
            ))
            ctx.blendMode = .clear
            ctx.fill(hole, with: .color(.black))
        }
        .frame(width: size, height: size)
    }
}

// MARK: Widget Declaration — Asset Allocation

struct AssetAllocationWidget: Widget {
    let kind: String = "AssetAllocationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PremiumProvider()) { entry in
            AssetAllocationEntryView(entry: entry)
        }
        .configurationDisplayName("Asset Allocation")
        .description("Visualise your portfolio mix. Requires Pro.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: ─────────────────────────────────────────────────────────────────────
// MARK: 2. RISK SCORE WIDGET
// MARK: ─────────────────────────────────────────────────────────────────────

struct RiskScoreEntryView: View {
    var entry: PremiumEntry

    var body: some View {
        if entry.data.isPremium {
            RiskScoreContentView(data: entry.data)
        } else {
            PremiumGateView(featureName: "Risk\nScore")
        }
    }
}

struct RiskScoreContentView: View {
    let data: WidgetPremiumData
    private var score: Double { data.riskScore }
    private var riskLabel: String {
        switch score {
        case 0..<30:  return "Low"
        case 30..<60: return "Moderate"
        case 60..<80: return "High"
        default:      return "Very High"
        }
    }
    private var riskColor: Color {
        switch score {
        case 0..<30:  return WidgetColor.positiveStandard
        case 30..<60: return WidgetColor.warning
        case 60..<80: return Color(red: 1.0, green: 0.5, blue: 0.1)
        default:      return WidgetColor.negativeStandard
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeaderRow(icon: "gauge.open.with.lines.needle.33percent", title: "Risk Score")
                .padding(.bottom, 6)

            Spacer()

            ZStack {
                RiskArcShape(progress: 1.0)
                    .stroke(WidgetGlass.strokeColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))

                RiskArcShape(progress: score / 100)
                    .stroke(riskColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))

                VStack(spacing: 2) {
                    Text(String(format: "%.0f", score))
                        .font(WidgetFont.primaryLarge(.black))
                        .foregroundColor(WidgetColor.textPrimary)
                    Text(riskLabel)
                        .font(WidgetFont.microSmall(.bold))
                        .foregroundColor(riskColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)

            Spacer()

            MicroLabel(text: "Concentration-weighted risk index")
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Risk score \(String(format: "%.0f", score)), \(riskLabel)")
    }
}

struct RiskArcShape: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY + 10)
        let radius = min(rect.width, rect.height) * 0.46
        let startDegrees = 165.0
        let endDegrees   = startDegrees + 210 * progress
        var p = Path()
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(startDegrees),
                 endAngle:   .degrees(endDegrees),
                 clockwise: false)
        return p
    }
}

// MARK: Widget Declaration — Risk Score

struct RiskScoreWidget: Widget {
    let kind: String = "RiskScoreWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PremiumProvider()) { entry in
            RiskScoreEntryView(entry: entry)
        }
        .configurationDisplayName("Risk Score")
        .description("Portfolio concentration risk. Requires Pro.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: ─────────────────────────────────────────────────────────────────────
// MARK: 3. WEEKLY PERFORMANCE WIDGET
// MARK: ─────────────────────────────────────────────────────────────────────

struct WeeklyPerformanceEntryView: View {
    var entry: PremiumEntry

    var body: some View {
        if entry.data.isPremium {
            WeeklyPerformanceContentView(data: entry.data)
        } else {
            PremiumGateView(featureName: "Weekly\nPerformance")
        }
    }
}

struct WeeklyPerformanceContentView: View {
    let data: WidgetPremiumData
    private let cbMode = WidgetColorblindMode.current
    private var weeklyPositive: Bool { data.weeklyChangePercent >= 0 }
    private static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WidgetHeaderRow(icon: "calendar.badge.clock", title: "Weekly Performance")
                Spacer()
                DeltaChip(value: data.weeklyChangePercent, size: .compact, mode: cbMode)
            }
            .padding(.bottom, 10)

            if data.weeklyValues.count >= 2 {
                WeeklyBarChart(values: data.weeklyValues, cbMode: cbMode, weeklyPositive: weeklyPositive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(WidgetColor.textTertiary.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: CGFloat.random(in: 15...50))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            let (bestIdx, worstIdx) = bestWorstIndices(in: data.weeklyValues)
            HStack {
                if bestIdx < Self.dayLabels.count {
                    Label("Best: \(Self.dayLabels[bestIdx])", systemImage: "star.fill")
                        .font(WidgetFont.microTiny(.semibold))
                        .foregroundColor(WidgetColor.positive(for: cbMode))
                }
                Spacer()
                if worstIdx < Self.dayLabels.count {
                    Label("Worst: \(Self.dayLabels[worstIdx])", systemImage: "exclamationmark.triangle.fill")
                        .font(WidgetFont.microTiny(.semibold))
                        .foregroundColor(WidgetColor.negative(for: cbMode))
                }
            }
            .padding(.top, 6)
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetDeepLink.portfolio)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Weekly performance, \(weeklyPositive ? "up" : "down") \(String(format: "%.2f", abs(data.weeklyChangePercent))) percent")
    }

    private func bestWorstIndices(in values: [Double]) -> (best: Int, worst: Int) {
        guard values.count >= 2 else { return (0, 0) }
        var deltas: [Double] = []
        for i in 1..<values.count { deltas.append(values[i] - values[i - 1]) }
        let bestIdx  = (deltas.firstIndex(of: deltas.max() ?? 0)  ?? 0) + 1
        let worstIdx = (deltas.firstIndex(of: deltas.min() ?? 0) ?? 0) + 1
        return (bestIdx, worstIdx)
    }
}

struct WeeklyBarChart: View {
    let values: [Double]
    let cbMode: WidgetColorblindMode
    let weeklyPositive: Bool
    private static let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    private var accent: Color { WidgetColor.semantic(isPositive: weeklyPositive, mode: cbMode) }

    var body: some View {
        GeometryReader { geo in
            let maxVal = values.max() ?? 1
            let minVal = values.min() ?? 0
            let range  = max(maxVal - minVal, 1)
            let barW   = (geo.size.width - CGFloat(values.count - 1) * 4) / CGFloat(values.count)
            let chartH = geo.size.height - 14

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, val in
                    let normH = max(4, chartH * CGFloat((val - minVal) / range))
                    VStack(spacing: 2) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent.opacity(i == values.count - 1 ? 1.0 : 0.55))
                            .frame(width: barW, height: normH)
                        Text(i < Self.dayLabels.count ? Self.dayLabels[i] : "")
                            .font(WidgetFont.microTiny(.medium))
                            .foregroundColor(WidgetColor.textTertiary)
                            .frame(width: barW)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}

// MARK: Widget Declaration — Weekly Performance

struct WeeklyPerformanceWidget: Widget {
    let kind: String = "WeeklyPerformanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PremiumProvider()) { entry in
            WeeklyPerformanceEntryView(entry: entry)
        }
        .configurationDisplayName("Weekly Performance")
        .description("7-day portfolio bar chart. Requires Pro.")
        .supportedFamilies([.systemMedium])
    }
}
