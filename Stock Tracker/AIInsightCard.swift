//
//  AIInsightCard.swift
//  Stock Tracker
//
//  Reusable card for AI-generated insights across the app.
//  Apple Intelligence-style animated glow border + skeleton loading.
//

import SwiftUI

struct AIInsightCard: View {
    let title: String
    let icon: String
    let insightText: String?
    let isLoading: Bool
    let isLocked: Bool
    let tier: SubscriptionTier
    let onGenerate: () async -> Void
    var onRegenerate: (() async -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var glowRotation: Double = 0
    @State private var glowPulse: CGFloat = 0.7
    @State private var borderPulse: CGFloat = 0.0

    private var showGlow: Bool {
        isLoading || (insightText != nil && !insightText!.isEmpty && !isLocked)
    }

    // Apple Intelligence gradient: warm purple → blue → teal → orange → purple
    private let siriColors: [Color] = [
        Color(red: 0.65, green: 0.30, blue: 0.95),
        Color(red: 0.35, green: 0.45, blue: 1.0),
        Color(red: 0.20, green: 0.75, blue: 0.85),
        Color(red: 0.95, green: 0.55, blue: 0.25),
        Color(red: 0.90, green: 0.30, blue: 0.55),
        Color(red: 0.65, green: 0.30, blue: 0.95),
    ]

    // Static teaser shown to free-tier users
    private static let teaserTexts = [
        "Markets showed broad momentum today with tech leading gains. Your portfolio's top mover outpaced the S&P 500 by 2.1%...",
        "Volatility picked up across small-caps while large-cap defensives held steady. Keep an eye on upcoming earnings...",
        "Sector rotation continues from growth to value names. Your watchlist has three stocks near 52-week highs..."
    ]

    private var teaserText: String {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return Self.teaserTexts[dayOfYear % Self.teaserTexts.count]
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText.opacity(0.8))
                Spacer()
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if insightText != nil && !isLoading {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                        )
                }
            }

            // Content
            if isLocked {
                lockedContent(theme: theme)
            } else if isLoading {
                skeletonContent
            } else if let text = insightText, !text.isEmpty {
                insightContent(text: text, theme: theme)
            } else {
                generateButton
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(glowOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                glowRotation = 360
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowPulse = 1.0
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                borderPulse = 1.0
            }
        }
    }

    // MARK: - Apple Intelligence Glow

    @ViewBuilder
    private var glowOverlay: some View {
        if showGlow {
            // Layer 1: Pulsing crisp border — breathes width + opacity
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AngularGradient(
                        colors: siriColors,
                        center: .center,
                        angle: .degrees(glowRotation)
                    ),
                    lineWidth: isLoading
                        ? 2.0 + borderPulse * 2.0   // 2→4pt
                        : 1.5 + borderPulse * 1.0    // 1.5→2.5pt
                )
                .opacity(isLoading
                    ? 0.7 + Double(borderPulse) * 0.3   // 0.7→1.0
                    : 0.6 + Double(borderPulse) * 0.3    // 0.6→0.9
                )

            // Layer 2: Near diffused glow — pulses with border
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AngularGradient(
                        colors: siriColors,
                        center: .center,
                        angle: .degrees(glowRotation + 45)
                    ),
                    lineWidth: isLoading
                        ? 6 + borderPulse * 4      // 6→10pt
                        : 4 + borderPulse * 2       // 4→6pt
                )
                .blur(radius: isLoading ? 10 : 6)
                .opacity(Double(glowPulse) * (isLoading ? 0.85 : 0.55))

            // Layer 3: Medium ambient glow
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AngularGradient(
                        colors: siriColors,
                        center: .center,
                        angle: .degrees(glowRotation - 30)
                    ),
                    lineWidth: isLoading ? 14 : 8
                )
                .blur(radius: isLoading ? 20 : 12)
                .opacity(Double(glowPulse) * (isLoading ? 0.6 : 0.3))

            // Layer 4: Ultra-wide soft halo
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AngularGradient(
                        colors: siriColors,
                        center: .center,
                        angle: .degrees(glowRotation + 90)
                    ),
                    lineWidth: isLoading ? 22 : 12
                )
                .blur(radius: isLoading ? 30 : 18)
                .opacity(Double(glowPulse) * (isLoading ? 0.4 : 0.15))
        }
    }

    // MARK: - States

    @ViewBuilder
    private func lockedContent(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(teaserText)
                .font(.subheadline)
                .foregroundColor(theme.primaryText.opacity(0.4))
                .lineSpacing(4)
                .blur(radius: 4)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                Text("Upgrade to Pro for AI insights")
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(.purple)
        }
    }

    // MARK: - Skeleton Loading

    private var skeletonContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonLine(widthFraction: 0.92)
            SkeletonLine(widthFraction: 0.78)
            SkeletonLine(widthFraction: 0.85)
            SkeletonLine(widthFraction: 0.45)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func insightContent(text: String, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.subheadline)
                .foregroundColor(theme.primaryText.opacity(0.9))
                .lineSpacing(4)

            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                Text("AI-generated · Not financial advice")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if tier == .black, let regen = onRegenerate {
                    Button {
                        Task { await regen() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Refresh")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var generateButton: some View {
        Button {
            Task { await onGenerate() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                Text("Generate \(title)")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [.purple, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(10)
        }
    }
}

// MARK: - Skeleton Line (shimmer effect)

private struct SkeletonLine: View {
    let widthFraction: CGFloat
    @State private var shimmerOffset: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
                .frame(width: geo.size.width * widthFraction, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: shimmerOffset * geo.size.width)
                        .mask(
                            RoundedRectangle(cornerRadius: 4)
                                .frame(width: geo.size.width * widthFraction, height: 12)
                        )
                )
        }
        .frame(height: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.5
            }
        }
    }
}
