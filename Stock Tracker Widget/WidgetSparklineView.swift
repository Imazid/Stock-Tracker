//
//  WidgetSparklineView.swift
//  Stock Tracker Widget
//
//  Reusable Canvas-based sparkline for all widgets.
//  Zero external dependencies — pure SwiftUI Path + Canvas.
//

import SwiftUI

// MARK: - SparklineView

/// A lightweight sparkline chart drawn with SwiftUI Canvas.
/// Automatically normalises input values and handles edge cases (0 or 1 point).
struct SparklineView: View {
    let points: [Double]
    let isPositive: Bool

    /// Stroke line width.
    var lineWidth: CGFloat = 1.5
    /// Whether to draw a gradient fill below the line.
    var showFill: Bool = true
    /// Whether to show a glow effect behind the line.
    var showGlow: Bool = false
    /// Whether to show a dot at the last data point.
    var showLastDot: Bool = false
    /// Optional colorblind mode override. Uses token colors when provided.
    var colorblindMode: WidgetColorblindMode? = nil

    private var lineColor: Color {
        if let mode = colorblindMode {
            return WidgetColor.semantic(isPositive: isPositive, mode: mode)
        }
        return WidgetColor.semantic(isPositive: isPositive)
    }

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2, size.width > 0, size.height > 0 else { return }

            let minVal = points.min()!
            let maxVal = points.max()!
            let range = maxVal - minVal

            // Avoid division by zero when all values are identical.
            let safeRange = range > 0 ? range : 1.0

            // Vertical padding so the line never clips at the very edge.
            let dotRadius: CGFloat = showLastDot ? 3 : 0
            let vPad: CGFloat = max(lineWidth, dotRadius + 1)
            let chartH = size.height - vPad * 2

            func x(at i: Int) -> CGFloat {
                size.width * CGFloat(i) / CGFloat(points.count - 1)
            }
            func y(for v: Double) -> CGFloat {
                // Invert: high value → small y (top of canvas).
                vPad + chartH * CGFloat(1 - (v - minVal) / safeRange)
            }

            // Build the line path.
            var linePath = Path()
            linePath.move(to: CGPoint(x: x(at: 0), y: y(for: points[0])))
            for i in 1..<points.count {
                // Smooth with a simple cubic Bézier.
                let prev = CGPoint(x: x(at: i - 1), y: y(for: points[i - 1]))
                let curr = CGPoint(x: x(at: i),     y: y(for: points[i]))
                let cp1  = CGPoint(x: prev.x + (curr.x - prev.x) * 0.5, y: prev.y)
                let cp2  = CGPoint(x: prev.x + (curr.x - prev.x) * 0.5, y: curr.y)
                linePath.addCurve(to: curr, control1: cp1, control2: cp2)
            }

            // Draw fill (gradient below the line).
            if showFill {
                var fillPath = linePath
                fillPath.addLine(to: CGPoint(x: x(at: points.count - 1), y: size.height))
                fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                fillPath.closeSubpath()

                ctx.drawLayer { layerCtx in
                    layerCtx.fill(fillPath, with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.35), lineColor.opacity(0.0)]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint:   CGPoint(x: size.width / 2, y: size.height)
                    ))
                }
            }

            // Glow effect: thin blur shadow behind line.
            if showGlow {
                ctx.drawLayer { layerCtx in
                    layerCtx.addFilter(.blur(radius: 4))
                    layerCtx.stroke(
                        linePath,
                        with: .color(lineColor.opacity(0.5)),
                        style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            // Draw the line on top.
            ctx.stroke(linePath, with: .color(lineColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Last-point dot indicator.
            if showLastDot, let last = points.last {
                let dotCenter = CGPoint(x: x(at: points.count - 1), y: y(for: last))
                let dotPath = Path(ellipseIn: CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
                ctx.fill(dotPath, with: .color(lineColor))
                // White inner dot
                let innerR: CGFloat = 1.5
                let innerPath = Path(ellipseIn: CGRect(
                    x: dotCenter.x - innerR,
                    y: dotCenter.y - innerR,
                    width: innerR * 2,
                    height: innerR * 2
                ))
                ctx.fill(innerPath, with: .color(.white))
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Positive + Glow") {
    SparklineView(
        points: [100, 105, 102, 110, 108, 115, 113, 120],
        isPositive: true,
        showGlow: true,
        showLastDot: true
    )
    .frame(width: 120, height: 40)
    .padding()
    .background(WidgetColor.bg1)
}

#Preview("Negative") {
    SparklineView(
        points: [120, 118, 115, 117, 112, 108, 110, 105],
        isPositive: false,
        showLastDot: true
    )
    .frame(width: 120, height: 40)
    .padding()
    .background(WidgetColor.bg1)
}
#endif
