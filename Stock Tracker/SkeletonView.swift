//
//  SkeletonView.swift
//  Stock Tracker
//

import SwiftUI

// MARK: - Skeleton building blocks

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 7
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.skeletonFill)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct SkeletonCircle: View {
    let size: CGFloat

    var body: some View {
        SkeletonBlock(width: size, height: size, cornerRadius: size / 2)
    }
}

/// The placeholder geometry stays out of the accessibility tree. VoiceOver
/// gets one loading status for the section, even when it contains many rows.
private struct LoadingSkeleton: ViewModifier {
    let label: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if reduceMotion || !Motion.isEnabled {
                content
            } else {
                content.phaseAnimator([1.0, 0.66]) { view, opacity in
                    view.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

extension View {
    func loadingSkeleton(_ label: LocalizedStringKey) -> some View {
        modifier(LoadingSkeleton(label: label))
    }
}

struct ChartSkeleton: View {
    var label: LocalizedStringKey = "Loading chart"
    var showsYAxis = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                ForEach(0..<3) { _ in
                    HStack(spacing: DS.Space.s) {
                        Rectangle()
                            .fill(theme.skeletonFill.opacity(0.55))
                            .frame(height: 1)
                        if showsYAxis { SkeletonBlock(width: 28, height: 6) }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            HStack {
                SkeletonBlock(width: 26, height: 6)
                Spacer()
                SkeletonBlock(width: 26, height: 6)
                Spacer()
                SkeletonBlock(width: 26, height: 6)
            }
            .padding(.trailing, showsYAxis ? 36 : 0)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.m)
        .loadingSkeleton(label)
    }
}

struct TextSkeleton: View {
    var lineCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(0..<lineCount, id: \.self) { line in
                SkeletonBlock(width: line == lineCount - 1 ? 104 : nil, height: 11)
            }
        }
    }
}

struct DataRowSkeleton: View {
    var body: some View {
        HStack {
            SkeletonBlock(width: 100, height: 12)
            Spacer()
            SkeletonBlock(width: 54, height: 12)
        }
        .frame(minHeight: 32)
    }
}

// MARK: - News Hero Skeleton

struct NewsHeroSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image placeholder
            SkeletonBlock(height: 200, cornerRadius: 0)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SkeletonBlock(width: 60, height: 10, cornerRadius: 5)
                    SkeletonBlock(width: 40, height: 10, cornerRadius: 5)
                }
                SkeletonBlock(height: 18)
                SkeletonBlock(height: 18)
                SkeletonBlock(width: 180, height: 18)
                SkeletonBlock(height: 13)
                SkeletonBlock(width: 220, height: 13)
            }
            .padding(16)
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - News Compact Card Skeleton

struct NewsCompactSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 70, height: 10, cornerRadius: 5)
                SkeletonBlock(height: 14)
                SkeletonBlock(width: 200, height: 14)
                SkeletonBlock(width: 100, height: 10, cornerRadius: 5)
            }
            Spacer()
            SkeletonBlock(width: 80, height: 80, cornerRadius: 10)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground)
        )
    }
}

// MARK: - Search Result Row Skeleton

struct SearchRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 40)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 55, height: 14)
                SkeletonBlock(width: 130, height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                SkeletonBlock(width: 65, height: 14)
                SkeletonBlock(width: 45, height: 11)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }
}
