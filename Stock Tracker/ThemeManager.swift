//
//  ThemeManager.swift
//  Stock Tracker
//

import SwiftUI
import Combine
import UIKit

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"
}

// MARK: - Colorblind Mode

enum ColorblindMode: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case deuteranopia = "Blue-Orange"
    case protanopia = "Blue-Yellow"

    var id: String { rawValue }

    var positiveColor: Color {
        switch self {
        // Coinbase-like greens: deep enough for 4.5:1 on the light page, brighter on black.
        case .standard: return Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.80, blue: 0.53, alpha: 1)     // #33CC87
            : UIColor(red: 0.02, green: 0.52, blue: 0.32, alpha: 1) })  // #058552
        case .deuteranopia: return Color(red: 0.0, green: 0.45, blue: 0.85) // Blue
        case .protanopia: return Color(red: 0.0, green: 0.45, blue: 0.85) // Blue
        }
    }

    var negativeColor: Color {
        switch self {
        case .standard: return Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.42, blue: 0.45, alpha: 1)     // #FF6B73
            : UIColor(red: 0.80, green: 0.13, blue: 0.20, alpha: 1) })  // #CC2133
        case .deuteranopia: return Color(red: 0.9, green: 0.5, blue: 0.0) // Orange
        case .protanopia: return Color(red: 0.85, green: 0.75, blue: 0.0) // Yellow
        }
    }

    var positiveIcon: String { "arrow.up.right" }
    var negativeIcon: String { "arrow.down.right" }
}

// MARK: - Theme Manager

@MainActor
final class ThemeManager: ObservableObject {
    @Published var themeMode: ThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "app_theme_mode")
        }
    }

    @Published var colorblindMode: ColorblindMode {
        didSet {
            UserDefaults.standard.set(colorblindMode.rawValue, forKey: "app_colorblind_mode")
            UserDefaults(suiteName: "group.com.cubeplay.stocktracker")?.set(colorblindMode.rawValue, forKey: "app_colorblind_mode")
        }
    }

    @Published var highContrastEnabled: Bool {
        didSet {
            UserDefaults.standard.set(highContrastEnabled, forKey: "app_high_contrast")
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    init() {
        // Black is the app's look (owner, 2026-11-13, after Revolut): new installs start in
        // Dark. A saved choice wins, and System / Light stay available in Settings.
        let saved = UserDefaults.standard.string(forKey: "app_theme_mode") ?? ThemeMode.dark.rawValue
        self.themeMode = ThemeMode(rawValue: saved) ?? .dark

        let savedCB = UserDefaults.standard.string(forKey: "app_colorblind_mode") ?? ColorblindMode.standard.rawValue
        self.colorblindMode = ColorblindMode(rawValue: savedCB) ?? .standard

        self.highContrastEnabled = UserDefaults.standard.bool(forKey: "app_high_contrast")

        // Sync colorblind mode to App Group for widget extension
        UserDefaults(suiteName: "group.com.cubeplay.stocktracker")?.set(self.colorblindMode.rawValue, forKey: "app_colorblind_mode")
    }
}

// MARK: - Theme

struct Theme {
    let colorScheme: ColorScheme
    let colorblindMode: ColorblindMode
    let highContrast: Bool

    init(colorScheme: ColorScheme, colorblindMode: ColorblindMode = .standard, highContrast: Bool = false) {
        self.colorScheme = colorScheme
        self.colorblindMode = colorblindMode
        self.highContrast = highContrast
    }

    var isDark: Bool { colorScheme == .dark }

    // MARK: - Glass layer (DSGlass.swift)

    /// The backdrop's main glow, top left: the brand blue.
    var glowPrimary: Color {
        isDark ? Color(red: 0.20, green: 0.38, blue: 1.00) : Color(red: 0.00, green: 0.32, blue: 1.00)
    }

    /// The second glow, top right: a violet that keeps the blue from looking flat.
    var glowSecondary: Color {
        isDark ? Color(red: 0.55, green: 0.32, blue: 0.95) : Color(red: 0.45, green: 0.35, blue: 0.95)
    }

    /// Frosted card fill, laid over an ultra-thin material.
    var cardFill: Color {
        isDark ? Color(red: 0.55, green: 0.62, blue: 1.0).opacity(0.075) : Color.white.opacity(0.62)
    }

    /// The card's lit top edge.
    var cardHighlight: Color {
        isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.95)
    }

    /// The card's lower edge.
    var cardEdge: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.06)
    }

    var cardShadow: Color {
        isDark ? Color.black.opacity(0.35) : Color(red: 0.10, green: 0.14, blue: 0.30).opacity(0.07)
    }

    // MARK: - Semantic Colors (Accessibility)

    var positiveColor: Color {
        let base = colorblindMode.positiveColor
        return highContrast ? base.opacity(1.0) : base
    }

    var negativeColor: Color {
        let base = colorblindMode.negativeColor
        return highContrast ? base.opacity(1.0) : base
    }

    var warningColor: Color {
        Color.orange
    }

    var accentColor: Color {
        Color.blue
    }

    var neutralColor: Color {
        .gray
    }

    var positiveIcon: String { colorblindMode.positiveIcon }
    var negativeIcon: String { colorblindMode.negativeIcon }

    // Cool neutrals after Coinbase / Revolut in light mode; a deep blue-black after Fey in
    // dark mode. The backdrop's glows (DSGlass.swift) sit on top of `background`.

    /// #F4F5F8 light / #030408 dark — the page (Revolut's near-black).
    var background: Color {
        isDark ? Color(red: 0.012, green: 0.016, blue: 0.031)
               : Color(red: 0.957, green: 0.961, blue: 0.973)
    }

    /// #EBEDF2 light / #0D0F17 dark.
    var secondaryBackground: Color {
        isDark ? Color(red: 0.051, green: 0.059, blue: 0.090)
               : Color(red: 0.922, green: 0.929, blue: 0.949)
    }

    /// Solid card surface where translucency would hurt (lists, inputs): white / #171A26,
    /// Revolut's navy-grey.
    var cardBackground: Color {
        isDark ? Color(red: 0.090, green: 0.102, blue: 0.149)
               : Color.white
    }

    var cardBorder: Color {
        isDark ? Color.white.opacity(0.10)
               : Color(red: 0.10, green: 0.14, blue: 0.30).opacity(0.10)
    }

    var primaryText: Color {
        Color(UIColor.label)
    }

    var secondaryText: Color {
        Color(UIColor.secondaryLabel)
    }

    var separator: Color {
        Color(UIColor.separator)
    }

    var glassBackground: Color {
        isDark ? Color.white.opacity(0.08)
               : Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.72)
    }

    var glassBorder: Color {
        isDark ? Color.white.opacity(0.18)
               : Color(red: 0.72, green: 0.66, blue: 0.60).opacity(0.25)
    }

    var backgroundGradient: LinearGradient {
        isDark
            ? LinearGradient(
                colors: [Color(UIColor.systemBackground), Color(UIColor.secondarySystemBackground)],
                startPoint: .top, endPoint: .bottom
              )
            : LinearGradient(
                colors: [
                    Color(red: 0.980, green: 0.973, blue: 0.961),
                    Color(red: 0.953, green: 0.937, blue: 0.910)
                ],
                startPoint: .top, endPoint: .bottom
              )
    }

    var glassGradient: LinearGradient {
        isDark
            ? LinearGradient(
                colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.8),
                    Color(red: 0.93, green: 0.91, blue: 0.87).opacity(0.5)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
    }

    var searchFieldGradient: LinearGradient {
        isDark
            ? LinearGradient(
                colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.93, blue: 0.90).opacity(0.9),
                    Color(red: 0.93, green: 0.91, blue: 0.88).opacity(0.6)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
    }

    var tabBarBackground: Color {
        glassBackground
    }

    var tabBarHighlightBorder: Color {
        glassBorder
    }

    var selectedTabForeground: Color {
        isDark ? .black : .white
    }

    var chartPlaceholder: Color {
        isDark ? Color.white.opacity(0.05) : Color.gray.opacity(0.08)
    }

    var detailBackground: Color {
        Color(UIColor.systemBackground)
    }

    var buttonBackground: Color {
        isDark ? Color.white.opacity(0.15) : Color.gray.opacity(0.12)
    }

    var subtleFill: Color {
        isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    var invertedPrimaryText: Color {
        isDark ? .black : .white
    }

    var progressTint: Color {
        isDark ? .white : .gray
    }
}

// MARK: - Theme injection

/// Puts `\.theme` in the environment from the view tree's *actual* colour scheme.
/// The App struct used its own `@Environment(\.colorScheme)`, which doesn't follow the
/// device, so System mode (the default) on a dark iPhone got the light cream palette
/// with white text. Apply this to every root and every sheet presented from the App.
struct ThemeEnvironment: ViewModifier {
    @ObservedObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.theme, Theme(
            colorScheme: themeManager.resolvedColorScheme ?? colorScheme,
            colorblindMode: themeManager.colorblindMode,
            highContrast: themeManager.highContrastEnabled
        ))
    }
}

// MARK: - Theme Environment Key

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = Theme(colorScheme: .dark)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
