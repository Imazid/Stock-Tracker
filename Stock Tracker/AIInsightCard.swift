//
//  AIInsightCard.swift
//  Stock Tracker
//
//  Reusable card for AI-generated insights across the app.
//  Animated loading and a quiet accent for generated insights.
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
    @AppStorage("aiPortfolioContextEnabled") private var includePortfolioContext = false
    private var showsBorder: Bool {
        !isLocked && includePortfolioContext && (isLoading || insightText?.isEmpty == false)
    }

    // Teaser shown (blurred) to free-tier users. It describes the feature rather
    // than making up claims about the market or the person's holdings.
    private static let teaserTexts = [
        "A short summary of today's market and the biggest moves in your watchlist and portfolio, written fresh each day from live prices.",
        "Each morning: what moved, by how much, and which of the companies you follow made the biggest moves.",
        "A plain-English recap of today's session for the stocks and crypto you track — facts only, no recommendations."
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
            ZStack(alignment: .topLeading) {
                Group {
                    if isLocked {
                        lockedContent(theme: theme)
                    } else if !includePortfolioContext {
                        Toggle("Share portfolio summary with AI", isOn: $includePortfolioContext)
                            .font(.subheadline)
                        Text("Enables insights using your tracked assets and relevant portfolio data.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    } else if isLoading {
                        skeletonContent
                    } else if let text = insightText, !text.isEmpty {
                        insightContent(text: text, theme: theme)
                    } else {
                        generateButton
                    }
                }
                .transition(.opacity)
            }
            .motionSafeAnimation(Motion.reveal, value: isLoading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.purple.opacity(showsBorder ? 0.32 : 0), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .motionSafeAnimation(DS.quick, value: showsBorder)
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
            SkeletonBlock(height: 11)
            SkeletonBlock(height: 11)
            SkeletonBlock(height: 11)
            SkeletonBlock(width: 104, height: 11)
        }
        .skeletonPulse()
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating insight")
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
