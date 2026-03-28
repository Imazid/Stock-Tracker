//
//  WelcomeScreen.swift
//  Stock Tracker
//
//  Hero onboarding screen: animated chart draws left-to-right, portfolio
//  value counts up, a floating price badge springs in at the chart peak.
//

import SwiftUI

struct WelcomeScreen: View {
    let onContinue: () -> Void

    @State private var chartProgress: CGFloat = 0
    @State private var portfolioValue: Double = 0
    @State private var showBadge = false
    @State private var contentOpacity: Double = 0

    private let targetValue: Double = 47_284.50

    // Normalised (x: 0-1, y: 0-1) control points for the ascending chart.
    // y = 0 is TOP of the view; y = 1 is BOTTOM.
    private let chartPoints: [(x: CGFloat, y: CGFloat)] = [
        (0.00, 0.88), (0.10, 0.80), (0.20, 0.84), (0.30, 0.70),
        (0.42, 0.72), (0.53, 0.57), (0.63, 0.49), (0.74, 0.37),
        (0.86, 0.28), (1.00, 0.14)
    ]

    var body: some View {
        ZStack {
            // Radial glow — sits behind everything
            RadialGradient(
                colors: [Color.blue.opacity(0.24), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 10,
                endRadius: 300
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 72)

                // ── Portfolio value counter ──────────────────────────────────
                VStack(spacing: 8) {
                    Text(portfolioValue, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: portfolioValue))

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.bold())
                        Text("+$1,284  (2.79%) today")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.88, blue: 0.50))
                }
                .opacity(contentOpacity)

                Spacer().frame(height: 30)

                // ── Animated chart + floating badge ──────────────────────────
                ZStack(alignment: .topTrailing) {
                    WelcomeChartCanvas(progress: chartProgress, dataPoints: chartPoints)
                        .frame(height: 185)

                    if showBadge {
                        WelcomePriceBadge()
                            .offset(x: -12, y: 4)
                            .transition(.scale(scale: 0.4, anchor: .topTrailing)
                                .combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)

                Spacer().frame(height: 52)

                // ── Headline + subtitle ──────────────────────────────────────
                VStack(spacing: 12) {
                    Text("Invest with Clarity")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("Track every position. See every move.\nAll in one place.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                }
                .padding(.horizontal, 40)
                .opacity(contentOpacity)

                Spacer()

                // ── CTA ──────────────────────────────────────────────────────
                OnboardingButton(title: "Get Started") { onContinue() }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
                    .opacity(contentOpacity)
            }
        }
        .onAppear { runEntranceAnimations() }
    }

    private func runEntranceAnimations() {
        // Static content fades in immediately
        withAnimation(.easeOut(duration: 0.55).delay(0.05)) {
            contentOpacity = 1
        }
        // Chart draws left-to-right
        withAnimation(.easeInOut(duration: 1.65).delay(0.30)) {
            chartProgress = 1
        }
        // Value counts up in sync with the chart
        withAnimation(.easeOut(duration: 1.65).delay(0.30)) {
            portfolioValue = targetValue
        }
        // Price badge pops in after the chart line reaches the end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.60)) {
                showBadge = true
            }
        }
    }
}

// MARK: - Chart Canvas

struct WelcomeChartCanvas: View {
    let progress: CGFloat
    let dataPoints: [(x: CGFloat, y: CGFloat)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Gradient area fill — revealed left-to-right as chart draws
                WelcomeChartArea(points: dataPoints)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.38), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: max(1, w * progress))
                            Color.clear
                        }
                    }

                // Soft glow layer (thicker, blurred)
                WelcomeChartLine(points: dataPoints)
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.45), Color.blue.opacity(0.25)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .blur(radius: 8)

                // Main crisp line
                WelcomeChartLine(points: dataPoints)
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                // Glowing dot at the current chart tip
                if progress > 0.97, let last = dataPoints.last {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: .cyan, radius: 8)
                        .shadow(color: .blue.opacity(0.5), radius: 20)
                        .position(x: last.x * w, y: last.y * h)
                        .opacity(Double((progress - 0.97) / 0.03))
                }
            }
        }
    }
}

// MARK: - Chart Shapes (module-internal — reused in CoreValueScreen)

struct WelcomeChartLine: Shape {
    let points: [(x: CGFloat, y: CGFloat)]

    func path(in rect: CGRect) -> Path {
        let mapped = points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) }
        return onboardingCatmullRomPath(through: mapped)
    }
}

struct WelcomeChartArea: Shape {
    let points: [(x: CGFloat, y: CGFloat)]

    func path(in rect: CGRect) -> Path {
        let mapped = points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) }
        var path = onboardingCatmullRomPath(through: mapped)
        if let last = mapped.last, let first = mapped.first {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// Catmull-Rom spline through an array of points — smooth, no overshoot.
// module-internal so CoreValueScreen can use the chart Shape types.
func onboardingCatmullRomPath(through points: [CGPoint]) -> Path {
    var path = Path()
    guard points.count >= 2 else { return path }
    path.move(to: points[0])
    for i in 1..<points.count {
        let p0 = points[max(0, i - 2)]
        let p1 = points[i - 1]
        let p2 = points[i]
        let p3 = points[min(points.count - 1, i + 1)]
        let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: cp1, control2: cp2)
    }
    return path
}

// MARK: - Floating Price Badge

struct WelcomePriceBadge: View {
    private let green = Color(red: 0.25, green: 0.88, blue: 0.50)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .bold))
            Text("+2.79%")
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundColor(green)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(green.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(green.opacity(0.4), lineWidth: 1)
                )
        )
        .shadow(color: green.opacity(0.35), radius: 14)
    }
}
