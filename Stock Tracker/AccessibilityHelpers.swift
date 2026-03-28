//
//  AccessibilityHelpers.swift
//  Stock Tracker
//

import SwiftUI
import UIKit

// MARK: - Motion-Safe Animation Helpers

/// Wraps `withAnimation` checking reduce-motion preference
func motionSafeWithAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled {
        return try body()
    } else {
        return try withAnimation(animation, body)
    }
}

/// View modifier that respects reduce-motion
struct MotionSafeAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.animation(animation, value: value)
        }
    }
}

extension View {
    func motionSafeAnimation<V: Equatable>(_ animation: Animation? = .default, value: V) -> some View {
        modifier(MotionSafeAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Financial Accessibility Descriptions

struct FinancialAccessibility {
    static func priceChangeDescription(symbol: String, price: Double, change: Double, changePercent: Double) -> String {
        let direction = change >= 0 ? "up" : "down"
        let formattedPrice = String(format: "$%.2f", price)
        let formattedPercent = String(format: "%.2f", abs(changePercent))
        return "\(symbol), price \(formattedPrice), \(direction) \(formattedPercent) percent"
    }

    static func holdingDescription(symbol: String, shares: Double, currentValue: Double, profitLossPercent: Double) -> String {
        let direction = profitLossPercent >= 0 ? "gain" : "loss"
        let formattedValue = String(format: "$%.2f", currentValue)
        let formattedPercent = String(format: "%.2f", abs(profitLossPercent))
        let formattedShares = String(format: "%.2f", shares)
        return "\(symbol), \(formattedShares) shares, value \(formattedValue), \(formattedPercent) percent \(direction)"
    }

    static func chartDescription(assetName: String, timeRange: String, dataPointCount: Int, trend: String) -> String {
        return "\(assetName) \(timeRange) chart with \(dataPointCount) data points, trending \(trend)"
    }
}

// MARK: - Gain/Loss Indicator (Dual Encoding: Color + Icon)

struct GainLossIndicator: View {
    let value: Double
    let formattedText: String
    @Environment(\.theme) var theme

    init(value: Double, format: String = "%+.2f%%") {
        self.value = value
        self.formattedText = String(format: format, value)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: value >= 0 ? theme.positiveIcon : theme.negativeIcon)
                .font(.caption2.bold())
            Text(formattedText)
                .font(.caption.bold())
        }
        .foregroundColor(value >= 0 ? theme.positiveColor : theme.negativeColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value >= 0 ? "Up \(formattedText)" : "Down \(formattedText)")
    }
}

// MARK: - Gain/Loss Text Color Helper

extension View {
    /// Applies positive/negative color from theme based on value
    func gainLossColor(_ value: Double, theme: Theme) -> some View {
        self.foregroundColor(value >= 0 ? theme.positiveColor : theme.negativeColor)
    }
}

// MARK: - Contrast Checker (DEBUG only)

#if DEBUG
struct ContrastChecker {
    /// Calculate WCAG contrast ratio between two colors (approximate)
    static func contrastRatio(foreground: (r: Double, g: Double, b: Double), background: (r: Double, g: Double, b: Double)) -> Double {
        let fgLuminance = relativeLuminance(r: foreground.r, g: foreground.g, b: foreground.b)
        let bgLuminance = relativeLuminance(r: background.r, g: background.g, b: background.b)
        let lighter = max(fgLuminance, bgLuminance)
        let darker = min(fgLuminance, bgLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Check if contrast meets WCAG AA (4.5:1 for normal text)
    static func meetsAA(foreground: (r: Double, g: Double, b: Double), background: (r: Double, g: Double, b: Double)) -> Bool {
        return contrastRatio(foreground: foreground, background: background) >= 4.5
    }

    private static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        let rLinear = linearize(r)
        let gLinear = linearize(g)
        let bLinear = linearize(b)
        return 0.2126 * rLinear + 0.7152 * gLinear + 0.0722 * bLinear
    }

    private static func linearize(_ value: Double) -> Double {
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
#endif
