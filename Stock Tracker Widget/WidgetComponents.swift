//
//  WidgetComponents.swift
//  Stock Tracker Widget
//
//  Reusable building-block views for the premium widget suite.
//  All components consume WidgetDesignTokens for colors, fonts, and spacing.
//

import SwiftUI
import WidgetKit

// MARK: - HeroPriceBlock

/// Display-scale price + optional symbol, auto-sizes by family.
struct HeroPriceBlock: View {
    let value: Double
    let symbol: String?
    let family: WidgetFamily

    init(value: Double, symbol: String? = nil, family: WidgetFamily = .systemSmall) {
        self.value = value
        self.symbol = symbol
        self.family = family
    }

    private var font: Font {
        switch family {
        case .systemLarge:  return WidgetFont.displayMedium(.bold)
        case .systemMedium: return WidgetFont.primaryLarge(.bold)
        default:            return WidgetFont.primaryLarge(.bold)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let sym = symbol {
                Text(sym)
                    .font(family == .systemLarge ? WidgetFont.displaySmall(.black) : WidgetFont.primaryLarge(.black))
                    .foregroundColor(WidgetColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value, format: .currency(code: "USD").precision(.fractionLength(value >= 1000 ? 0 : 2)))
                .font(font)
                .foregroundColor(WidgetColor.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

// MARK: - DeltaChip

/// Rounded pill: arrow icon + %, colorblind-aware.
struct DeltaChip: View {
    let value: Double
    var size: ChipSize = .regular
    var mode: WidgetColorblindMode = .current

    enum ChipSize {
        case compact, regular, large
    }

    private var isPositive: Bool { value >= 0 }
    private var color: Color { WidgetColor.semantic(isPositive: isPositive, mode: mode) }

    private var iconSize: CGFloat {
        switch size {
        case .compact: return 8
        case .regular:  return 10
        case .large:    return 11
        }
    }

    private var textFont: Font {
        switch size {
        case .compact: return WidgetFont.microSmall(.bold)
        case .regular:  return WidgetFont.secondaryMedium(.bold)
        case .large:    return WidgetFont.secondaryLarge(.bold)
        }
    }

    private var hPad: CGFloat { size == .compact ? 6 : 10 }
    private var vPad: CGFloat { size == .compact ? 3 : 6 }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: iconSize, weight: .bold))
            Text("\(isPositive ? "+" : "")\(String(format: "%.2f", value))%")
                .font(textFont)
        }
        .foregroundColor(color)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: WidgetRadius.pill))
    }
}

// MARK: - WidgetHeaderRow

/// Micro icon + title + optional trailing badge.
struct WidgetHeaderRow: View {
    let icon: String
    let title: String
    var iconColor: Color = WidgetColor.textTertiary
    var trailing: String? = nil
    var trailingColor: Color = WidgetColor.textTertiary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(WidgetFont.microTiny(.bold))
                .foregroundColor(iconColor)
            Text(title)
                .font(WidgetFont.microTiny(.semibold))
                .foregroundColor(WidgetColor.textTertiary)

            if let trail = trailing {
                Spacer()
                Text(trail)
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(trailingColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(trailingColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - GlassCard

/// Container modifier: glassFill bg, glassStroke border, card radius.
struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: WidgetRadius.card)
                    .fill(WidgetGlass.fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: WidgetRadius.card)
                            .stroke(WidgetGlass.strokeColor, lineWidth: 0.5)
                    )
            )
    }
}

/// View modifier version for convenience.
struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: WidgetRadius.card)
                    .fill(WidgetGlass.fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: WidgetRadius.card)
                            .stroke(WidgetGlass.strokeColor, lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }
}

// MARK: - MicroLabel

/// Abbreviated label in micro font.
struct MicroLabel: View {
    let text: String
    var color: Color = WidgetColor.textTertiary

    var body: some View {
        Text(text)
            .font(WidgetFont.microTiny(.medium))
            .foregroundColor(color)
    }
}

// MARK: - TickerBadge

/// 2-4 char symbol in small colored rounded-rect.
struct TickerBadge: View {
    let symbol: String
    var color: Color = WidgetColor.neutral
    var width: CGFloat = 36
    var height: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.18))
                .frame(width: width, height: height)
            Text(String(symbol.prefix(4)))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }
}

// MARK: - MarketStatusDot

/// 6pt circle (green/red) + "OPEN"/"CLOSED" label.
struct MarketStatusDot: View {
    let isOpen: Bool
    var showLabel: Bool = true
    var mode: WidgetColorblindMode = .current

    private var color: Color {
        isOpen ? WidgetColor.positive(for: mode) : WidgetColor.negative(for: mode)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            if showLabel {
                Text(isOpen ? "OPEN" : "CLOSED")
                    .font(WidgetFont.microTiny(.bold))
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - PremiumGateView (Restyled)

/// Crown + "PRO" gate card, tap -> paywall deep link. Uses design tokens.
struct TokenPremiumGateView: View {
    let featureName: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(WidgetColor.premium.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundColor(WidgetColor.premium)
            }
            Text(featureName)
                .font(WidgetFont.microSmall(.bold))
                .foregroundColor(WidgetColor.textPrimary)
                .multilineTextAlignment(.center)
            Text("Pro required")
                .font(WidgetFont.microTiny(.semibold))
                .foregroundColor(WidgetColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(WidgetDeepLink.paywall)
        .widgetContainerBG()
    }
}

// MARK: - StaleOverlay

/// Subtle "last updated" indicator when data is older than threshold.
struct StaleOverlay: View {
    let date: Date
    var thresholdMinutes: Int = 30

    private var isStale: Bool {
        Date().timeIntervalSince(date) > Double(thresholdMinutes * 60)
    }

    var body: some View {
        if isStale {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("Updated \(date, format: .dateTime.hour().minute())")
                        .font(WidgetFont.microTiny(.medium))
                        .foregroundColor(WidgetColor.textTertiary.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
        }
    }
}
