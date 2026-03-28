//
//  CoreValueScreen.swift
//  Stock Tracker
//
//  Feature-tour onboarding screen: three swipeable cards each showing a
//  rich, interactive-looking preview of a real app section.
//

import SwiftUI

struct CoreValueScreen: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var currentPage = 0
    @State private var headerOpacity: Double = 0

    private let features: [OnboardingFeature] = [
        OnboardingFeature(
            icon: "chart.line.uptrend.xyaxis",
            accentColor: .blue,
            title: "Watchlist",
            subtitle: "Live prices, right when you need them",
            preview: AnyView(WatchlistFeaturePreview())
        ),
        OnboardingFeature(
            icon: "briefcase.fill",
            accentColor: Color(red: 0.25, green: 0.88, blue: 0.50),
            title: "Portfolio",
            subtitle: "See your real value at a glance",
            preview: AnyView(PortfolioFeaturePreview())
        ),
        OnboardingFeature(
            icon: "sparkles",
            accentColor: .purple,
            title: "AI Insights",
            subtitle: "Your portfolio, explained simply",
            preview: AnyView(AIFeaturePreview())
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 62)

            // ── Header ───────────────────────────────────────────────────────
            VStack(spacing: 10) {
                Text("Built for investors\nwho want clarity")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                Text("Three views. One clear picture.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.48))
            }
            .padding(.horizontal, 32)
            .opacity(headerOpacity)

            Spacer().frame(height: 34)

            // ── Feature card carousel ─────────────────────────────────────────
            TabView(selection: $currentPage) {
                ForEach(Array(features.enumerated()), id: \.offset) { idx, feature in
                    FeatureCard(feature: feature)
                        .padding(.horizontal, 28)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 370)

            // ── Page dots ─────────────────────────────────────────────────────
            HStack(spacing: 8) {
                ForEach(0..<features.count, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? Color.white : Color.white.opacity(0.25))
                        .frame(width: i == currentPage ? 20 : 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                }
            }
            .padding(.top, 18)

            Spacer()

            // ── CTAs ──────────────────────────────────────────────────────────
            VStack(spacing: 14) {
                OnboardingButton(title: "Continue") { onContinue() }
                Button("Skip intro") { onSkip() }
                    .font(.body)
                    .foregroundColor(.white.opacity(0.40))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.1)) {
                headerOpacity = 1
            }
        }
    }
}

// MARK: - Feature Model

struct OnboardingFeature {
    let icon: String
    let accentColor: Color
    let title: String
    let subtitle: String
    let preview: AnyView
}

// MARK: - Feature Card

struct FeatureCard: View {
    let feature: OnboardingFeature
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Icon + title row
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(feature.accentColor.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: feature.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(feature.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    Text(feature.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 16)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Preview content
            feature.preview
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: feature.accentColor.opacity(0.14), radius: 32, y: 10)
        .scaleEffect(appeared ? 1.0 : 0.93)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.05)) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }
}

// MARK: - Watchlist Preview

struct WatchlistFeaturePreview: View {
    private let rows: [(symbol: String, name: String, price: String, change: String, isUp: Bool)] = [
        ("AAPL", "Apple",      "$178.50", "+1.24%", true),
        ("NVDA", "Nvidia",     "$495.20", "+3.87%", true),
        ("TSLA", "Tesla",      "$242.80", "−0.52%", false),
        ("MSFT", "Microsoft",  "$374.10", "+0.73%", true)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                WatchlistPreviewRow(row: rows[i])
                if i < rows.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
        )
    }
}

struct WatchlistPreviewRow: View {
    let row: (symbol: String, name: String, price: String, change: String, isUp: Bool)

    private var changeColor: Color {
        row.isUp
            ? Color(red: 0.25, green: 0.88, blue: 0.50)
            : Color(red: 1.0, green: 0.36, blue: 0.36)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Symbol badge
            Text(row.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 24)
                .background(Color.white.opacity(0.10))
                .cornerRadius(6)

            Text(row.name)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.60))

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(row.price)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)

                Text(row.change)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(changeColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(changeColor.opacity(0.16))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Portfolio Preview

struct PortfolioFeaturePreview: View {
    private let sparklinePoints: [(x: CGFloat, y: CGFloat)] = [
        (0.00, 0.72), (0.14, 0.62), (0.28, 0.68), (0.42, 0.52),
        (0.56, 0.48), (0.70, 0.36), (0.85, 0.30), (1.00, 0.18)
    ]

    private let green = Color(red: 0.25, green: 0.88, blue: 0.50)

    var body: some View {
        VStack(spacing: 14) {
            // Value row
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOTAL VALUE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.38))
                        .kerning(1.2)
                    Text("$47,284")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.38))
                        .kerning(1.2)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption.bold())
                        Text("+2.79%")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(green)
                }
            }

            // Sparkline (uses WelcomeChartLine from WelcomeScreen.swift)
            WelcomeChartLine(points: sparklinePoints)
                .stroke(
                    LinearGradient(
                        colors: [green, green.opacity(0.30)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(height: 44)

            // Top holdings bar
            HStack(spacing: 6) {
                ForEach(holdings, id: \.symbol) { h in
                    MiniHoldingChip(symbol: h.symbol, percent: h.percent, color: h.color)
                }
            }
        }
    }

    private let holdings: [(symbol: String, percent: String, color: Color)] = [
        ("AAPL", "28%", .blue),
        ("NVDA", "22%", .purple),
        ("ETH",  "18%", Color(red: 0.40, green: 0.60, blue: 1.0)),
        ("Other","32%", Color.white.opacity(0.35))
    ]
}

struct MiniHoldingChip: View {
    let symbol: String
    let percent: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color.opacity(0.28))
                .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1))
                .frame(width: 8, height: 8)

            Text(symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.72))

            Text(percent)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.40))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AI Insights Preview

struct AIFeaturePreview: View {
    @State private var showDots = true

    var body: some View {
        VStack(spacing: 10) {
            // User message bubble (right-aligned)
            HStack {
                Spacer()
                Text("How's my portfolio doing?")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.blue.opacity(0.45))
                    )
            }

            // AI response (left-aligned)
            HStack(alignment: .top, spacing: 10) {
                // AI avatar
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.28))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.purple)
                }

                Group {
                    if showDots {
                        OnboardingTypingDots()
                            .transition(.opacity)
                    } else {
                        Text("Your tech holdings are up **12%** this month, outperforming the S&P 500 by 4.2%.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: showDots)

                Spacer()
            }
        }
        .onAppear {
            showDots = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showDots = false
            }
        }
        .onDisappear {
            showDots = true
        }
    }
}

struct OnboardingTypingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(animate ? 0.85 : 0.28))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.15 : 0.85)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animate
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
        )
        .onAppear { animate = true }
    }
}
