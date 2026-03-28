//
//  SkeletonView.swift
//  Stock Tracker
//

import SwiftUI

// MARK: - Shimmer Modifier (phase-based, properly animated)

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                let w = geo.size.width
                LinearGradient(
                    stops: [
                        .init(color: .clear,                         location: max(0, phase - 0.25)),
                        .init(color: highlightColor.opacity(0.55),   location: phase),
                        .init(color: .clear,                         location: min(1, phase + 0.25)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: w * 2.5)
                .offset(x: (phase - 0.5) * w * 2.5 - w * 0.75)
            }
            .mask(content)
        )
        .onAppear {
            phase = -1
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private var highlightColor: Color {
        colorScheme == .dark ? Color.white : Color.white
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
    // Keep legacy alias
    func shimmering() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Skeleton Building Blocks

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 7
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
            .frame(width: width, height: height)
            .shimmer()
    }

    private var fillColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.07)
    }
}

struct SkeletonCircle: View {
    let size: CGFloat
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Circle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
            .frame(width: size, height: size)
            .shimmer()
    }
}

// MARK: - Watchlist Row Skeleton

struct WatchlistRowSkeleton: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 48, height: 14)
                SkeletonBlock(width: 110, height: 11)
            }
            Spacer()
            SkeletonBlock(width: 68, height: 34, cornerRadius: 8)
            VStack(alignment: .trailing, spacing: 7) {
                SkeletonBlock(width: 58, height: 14)
                SkeletonBlock(width: 42, height: 11)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        )
    }
}

// MARK: - News Hero Skeleton

struct NewsHeroSkeleton: View {
    @Environment(\.colorScheme) var colorScheme

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
        .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - News Compact Card Skeleton

struct NewsCompactSkeleton: View {
    @Environment(\.colorScheme) var colorScheme

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
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        )
    }
}

// MARK: - Portfolio Holding Row Skeleton

struct HoldingRowSkeleton: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 52, height: 14)
                SkeletonBlock(width: 130, height: 11)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                SkeletonBlock(width: 72, height: 14)
                SkeletonBlock(width: 50, height: 11)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
        )
    }
}

// MARK: - Home Portfolio Card Skeleton

struct HomePortfolioCardSkeleton: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SkeletonBlock(width: 100, height: 13, cornerRadius: 6)
                Spacer()
                SkeletonBlock(width: 60, height: 13, cornerRadius: 6)
            }
            SkeletonBlock(width: 160, height: 32, cornerRadius: 8)
            SkeletonBlock(width: 90, height: 18, cornerRadius: 6)
            SkeletonBlock(height: 60, cornerRadius: 10)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910))
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

// MARK: - Staggered Skeleton Container

/// Wraps N skeletons with staggered opacity fade-ins so they don't all pop up at once.
struct StaggeredSkeletonList<S: View>: View {
    let count: Int
    let skeleton: () -> S
    @State private var appeared = false

    var body: some View {
        ForEach(0..<count, id: \.self) { i in
            skeleton()
                .opacity(appeared ? 1 : 0)
                .animation(
                    .easeOut(duration: 0.3).delay(Double(i) * 0.07),
                    value: appeared
                )
        }
        .onAppear { appeared = true }
    }
}
