//
//  WidgetDesignTokens.swift
//  Stock Tracker Widget
//
//  Centralized design token system — colors, typography, glass materials,
//  spacing, and container backgrounds for the premium widget suite.
//

import SwiftUI
import WidgetKit

// MARK: - Colorblind Mode (Widget Side)

/// Reads the user's colorblind preference from App Group UserDefaults,
/// matching the main app's `ColorblindMode` enum.
enum WidgetColorblindMode: String, CaseIterable {
    case standard    = "Standard"
    case deuteranopia = "Blue-Orange"
    case protanopia  = "Blue-Yellow"

    static var current: WidgetColorblindMode {
        guard let raw = UserDefaults(suiteName: widgetAppGroup)?.string(forKey: "app_colorblind_mode"),
              let mode = WidgetColorblindMode(rawValue: raw)
        else { return .standard }
        return mode
    }
}

// MARK: - Color Tokens

enum WidgetColor {
    // ── Backgrounds ──────────────────────────────────────────────────────
    static let bg0 = Color(red: 0.039, green: 0.043, blue: 0.059)  // #0A0B0F
    static let bg1 = Color(red: 0.067, green: 0.075, blue: 0.102)  // #11131A
    static let bg2 = Color(red: 0.102, green: 0.114, blue: 0.169)  // #1A1D2B

    // ── Text ─────────────────────────────────────────────────────────────
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.7)
    static let textTertiary  = Color.white.opacity(0.45)

    // ── Semantic (standard mode) ─────────────────────────────────────────
    static let positiveStandard = Color(red: 0.18, green: 0.85, blue: 0.45)
    static let negativeStandard = Color(red: 1.0,  green: 0.27, blue: 0.27)

    // ── Semantic (deuteranopia) ──────────────────────────────────────────
    static let positiveDeuteranopia = Color(red: 0.0,  green: 0.45, blue: 0.85)
    static let negativeDeuteranopia = Color(red: 0.9,  green: 0.5,  blue: 0.0)

    // ── Semantic (protanopia) ────────────────────────────────────────────
    static let positiveProtanopia = Color(red: 0.0,  green: 0.45, blue: 0.85)
    static let negativeProtanopia = Color(red: 0.85, green: 0.75, blue: 0.0)

    // ── Fixed semantic ───────────────────────────────────────────────────
    static let warning  = Color(red: 0.95, green: 0.75, blue: 0.2)
    static let neutral  = Color(red: 0.65, green: 0.65, blue: 0.70)
    static let premium  = Color(red: 0.95, green: 0.75, blue: 0.2)

    // ── Colorblind-aware accessors ───────────────────────────────────────

    static func positive(for mode: WidgetColorblindMode = .current) -> Color {
        switch mode {
        case .standard:    return positiveStandard
        case .deuteranopia: return positiveDeuteranopia
        case .protanopia:  return positiveProtanopia
        }
    }

    static func negative(for mode: WidgetColorblindMode = .current) -> Color {
        switch mode {
        case .standard:    return negativeStandard
        case .deuteranopia: return negativeDeuteranopia
        case .protanopia:  return negativeProtanopia
        }
    }

    static func semantic(isPositive: Bool, mode: WidgetColorblindMode = .current) -> Color {
        isPositive ? positive(for: mode) : negative(for: mode)
    }
}

// MARK: - Glass Material Tokens

enum WidgetGlass {
    static let fillColor      = Color.black.opacity(0.45)
    static let strokeColor    = Color.white.opacity(0.10)
    static let highlightStart = Color.white.opacity(0.12)
    static let highlightEnd   = Color.white.opacity(0.02)

    static var highlightGradient: LinearGradient {
        LinearGradient(
            colors: [highlightStart, highlightEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Typography Tokens

enum WidgetFont {
    // Display
    static func displayLarge(_ weight: Font.Weight = .bold) -> Font {
        .system(size: 40, weight: weight, design: .rounded)
    }
    static func displayMedium(_ weight: Font.Weight = .bold) -> Font {
        .system(size: 32, weight: weight, design: .rounded)
    }
    static func displaySmall(_ weight: Font.Weight = .bold) -> Font {
        .system(size: 26, weight: weight, design: .rounded)
    }

    // Primary
    static func primaryLarge(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 22, weight: weight, design: .rounded)
    }
    static func primaryMedium(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 20, weight: weight, design: .rounded)
    }
    static func primarySmall(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 18, weight: weight, design: .rounded)
    }

    // Secondary
    static func secondaryLarge(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 16, weight: weight, design: .rounded)
    }
    static func secondaryMedium(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 14, weight: weight, design: .rounded)
    }

    // Micro
    static func microLarge(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 12, weight: weight, design: .rounded)
    }
    static func microSmall(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 11, weight: weight, design: .rounded)
    }
    static func microTiny(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 9, weight: weight, design: .rounded)
    }
}

// MARK: - Spacing Tokens

enum WidgetSpacing {
    static let grid: CGFloat = 4

    // Outer padding per widget family
    static let paddingSmall:  CGFloat = 12
    static let paddingMedium: CGFloat = 16
    static let paddingLarge:  CGFloat = 20

    // Row gaps
    static let rowGapCompact: CGFloat = 8
    static let rowGapStandard: CGFloat = 12

    // Section gap
    static let sectionGap: CGFloat = 16
}

// MARK: - Radii Tokens

enum WidgetRadius {
    static let card: CGFloat = 16
    static let pill: CGFloat = 20
    static let container: CGFloat = 24
}

// MARK: - Container Background

/// Unified container background replacing scattered LinearGradient calls.
struct WidgetContainerBackground: View {
    var accentColor: Color? = nil
    var accentAlignment: Alignment = .leading

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WidgetColor.bg1, WidgetColor.bg0],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let accent = accentColor {
                accent.opacity(0.06)
                    .frame(width: 120, height: 120)
                    .blur(radius: 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: accentAlignment)
            }
        }
    }
}

// MARK: - Helpers

extension View {
    /// Standard widget container background.
    func widgetContainerBG(accent: Color? = nil, accentAlignment: Alignment = .leading) -> some View {
        self.containerBackground(for: .widget) {
            WidgetContainerBackground(accentColor: accent, accentAlignment: accentAlignment)
        }
    }

    /// Outer padding matching widget family.
    func widgetPadding(for family: WidgetFamily) -> some View {
        switch family {
        case .systemSmall:
            return self.padding(WidgetSpacing.paddingSmall)
        case .systemLarge:
            return self.padding(WidgetSpacing.paddingLarge)
        default:
            return self.padding(WidgetSpacing.paddingMedium)
        }
    }
}
