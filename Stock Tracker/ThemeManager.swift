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
        case .standard: return .green
        case .deuteranopia: return Color(red: 0.0, green: 0.45, blue: 0.85) // Blue
        case .protanopia: return Color(red: 0.0, green: 0.45, blue: 0.85) // Blue
        }
    }

    var negativeColor: Color {
        switch self {
        case .standard: return .red
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

    private var isDark: Bool { colorScheme == .dark }

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

    // Warm antique-white palette for light mode; standard system colours for dark mode.
    // Light values approximate Dulux "Antique White" / Manus AI warm-cream aesthetic.

    /// #FAF8F5 — warm white main background (light) / systemBackground (dark)
    var background: Color {
        isDark ? Color(UIColor.systemBackground)
               : Color(red: 0.980, green: 0.973, blue: 0.961)
    }

    /// #F3EFE8 — warm cream secondary background (light) / secondarySystemBackground (dark)
    var secondaryBackground: Color {
        isDark ? Color(UIColor.secondarySystemBackground)
               : Color(red: 0.953, green: 0.937, blue: 0.910)
    }

    /// #EDE8E0 — warm cream card surface (light)
    var cardBackground: Color {
        isDark ? Color(UIColor.secondarySystemGroupedBackground)
               : Color(red: 0.929, green: 0.910, blue: 0.878)
    }

    var cardBorder: Color {
        isDark ? Color(UIColor.separator)
               : Color(red: 0.78, green: 0.74, blue: 0.69).opacity(0.5)
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
