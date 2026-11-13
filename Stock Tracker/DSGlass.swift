//
//  DSGlass.swift
//  Stock Tracker
//
//  The iOS 26 layer of the design system: an ambient backdrop behind every screen, frosted
//  content cards, and Liquid Glass for the things you touch (buttons, pills, pickers, the
//  floating bars). After Coinbase (clarity, one confident accent), Revolut (big balance,
//  round action buttons), Fey (deep dark, quiet glow, refined numbers) and Luma (colour-
//  derived gradients behind glass).
//
//  Rules:
//  - Glass is for controls and floating chrome. Content sits on frosted cards, never
//    glass-on-glass, so text keeps its contrast.
//  - The backdrop's glow is decoration only: hidden from VoiceOver, never carries meaning,
//    and fades to plain under Reduce Transparency.
//  - Gain/loss colours still come from `Theme`, so colour-blind modes keep working.
//

import SwiftUI

// MARK: - Backdrop

/// The page behind a screen: the base colour with two soft glows for the glass to refract.
/// `tint` lets a screen set the mood (a stock page uses its direction or brand colour).
struct ScreenBackdrop: View {
    var tint: Color? = nil
    var style: BackdropStyle = .ambient
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            theme.background
            if !reduceTransparency, let hero = style.colors {
                // Revolut's section hero: a saturated colour at the top fading into the page.
                LinearGradient(stops: [
                    .init(color: hero.top.opacity(theme.isDark ? 1 : 0.30), location: 0),
                    .init(color: hero.mid.opacity(theme.isDark ? 0.85 : 0.10), location: 0.30),
                    .init(color: theme.background.opacity(0), location: 0.62)
                ], startPoint: .top, endPoint: .bottom)
            } else if !reduceTransparency {
                let primary = tint ?? theme.glowPrimary
                RadialGradient(colors: [primary.opacity(theme.isDark ? 0.34 : 0.12), primary.opacity(0)],
                               center: UnitPoint(x: 0.12, y: -0.04), startRadius: 0, endRadius: 460)
                RadialGradient(colors: [theme.glowSecondary.opacity(theme.isDark ? 0.22 : 0.07), theme.glowSecondary.opacity(0)],
                               center: UnitPoint(x: 1.0, y: 0.12), startRadius: 0, endRadius: 380)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// `ambient`: two soft glows. The others are Revolut-style section heroes, one colour per
/// place so you know where you are: Home blue, Portfolio teal, Agents violet.
enum BackdropStyle {
    case ambient, home, portfolio, agents

    var colors: (top: Color, mid: Color)? {
        switch self {
        case .ambient: return nil
        case .home: return (Color(red: 0.13, green: 0.22, blue: 1.00), Color(red: 0.05, green: 0.08, blue: 0.42))
        case .portfolio: return (Color(red: 0.08, green: 0.55, blue: 0.62), Color(red: 0.03, green: 0.20, blue: 0.26))
        case .agents: return (Color(red: 0.42, green: 0.24, blue: 1.00), Color(red: 0.16, green: 0.07, blue: 0.42))
        }
    }
}

extension View {
    /// Puts the backdrop behind a screen (replaces a flat `theme.background`).
    func dsScreenBackground(tint: Color? = nil, style: BackdropStyle = .ambient) -> some View {
        background(ScreenBackdrop(tint: tint, style: style))
    }
}

// MARK: - Frosted card

/// A content card: translucent fill over the backdrop, a light top edge and a soft shadow.
struct FrostedCard: ViewModifier {
    var padding: CGFloat = DS.Space.l
    var radius: CGFloat = DS.Radius.card
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape.fill(theme.cardFill)
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [theme.cardHighlight, theme.cardEdge],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .shadow(color: theme.cardShadow, radius: 18, x: 0, y: 8)
    }
}

// MARK: - Glass controls

/// A round glass action with a label under it (Revolut's Add / Exchange / More row).
struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    /// A longer name for VoiceOver and UI tests when the caption is short ("Connect").
    var accessibilityName: LocalizedStringKey? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : theme.primaryText)
                    .frame(width: 54, height: 54)
                    .glassEffect(prominent ? .regular.tint(DS.accentFill).interactive() : .regular.interactive(), in: .circle)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName ?? title)
    }
}

// MARK: - Money

/// A money amount with the cents smaller and quieter: "US$354" then ".85" (Revolut / Fey).
/// VoiceOver and UI tests read the whole amount as one label.
struct MoneyText: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .bold
    var color: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        let parts = Self.split(text)
        Text("\(Text(parts.whole).font(DS.money(size, weight: weight)).foregroundStyle(color ?? theme.primaryText))\(Text(parts.fraction).font(DS.money(size * 0.6, weight: weight)).foregroundStyle(theme.secondaryText))")
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(text)
    }

    /// "US$1,234.56" → ("US$1,234", ".56"). Anything without trailing cents stays whole.
    static func split(_ text: String) -> (whole: String, fraction: String) {
        guard let dot = text.lastIndex(of: ".") else { return (text, "") }
        let digits = text[text.index(after: dot)...]
        guard (1...4).contains(digits.count), digits.allSatisfy(\.isNumber) else { return (text, "") }
        return (String(text[..<dot]), String(text[dot...]))
    }
}

/// A small round glass icon button for top bars (settings, search, copilot).
struct GlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A capsule glass chip ("Practice", filters, suggestion chips).
struct GlassChip: ViewModifier {
    var tint: Color? = nil
    var interactive = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(glass, in: .capsule)
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.35)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func frostedCard(padding: CGFloat = DS.Space.l, radius: CGFloat = DS.Radius.card) -> some View {
        modifier(FrostedCard(padding: padding, radius: radius))
    }

    func glassChip(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassChip(tint: tint, interactive: interactive))
    }
}

// MARK: - Agent avatar

/// A gradient tile with the agent's icon, the same colours every time for the same agent
/// (Luma's event tiles). Decorative: hidden from VoiceOver.
struct AgentAvatar: View {
    let seed: String
    var systemImage: String = "sparkles"
    var size: CGFloat = 42

    private static let palettes: [[Color]] = [
        [Color(red: 0.00, green: 0.32, blue: 1.00), Color(red: 0.45, green: 0.35, blue: 0.95)],
        [Color(red: 0.05, green: 0.62, blue: 0.55), Color(red: 0.10, green: 0.40, blue: 0.90)],
        [Color(red: 0.95, green: 0.45, blue: 0.20), Color(red: 0.90, green: 0.20, blue: 0.45)],
        [Color(red: 0.55, green: 0.30, blue: 0.95), Color(red: 0.95, green: 0.35, blue: 0.70)],
        [Color(red: 0.10, green: 0.55, blue: 0.95), Color(red: 0.20, green: 0.80, blue: 0.75)],
        [Color(red: 0.95, green: 0.65, blue: 0.10), Color(red: 0.95, green: 0.35, blue: 0.25)]
    ]

    var body: some View {
        // A stable hash (String.hashValue changes every launch).
        let hash = seed.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
        let colors = Self.palettes[hash % Self.palettes.count]
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75)
            )
            .accessibilityHidden(true)
    }
}
