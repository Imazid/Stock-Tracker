//
//  DesignSystem.swift
//  Stock Tracker
//
//  Shared tokens and building blocks for the redesigned onboarding and home.
//  Graphite surfaces, cyan navigation, and violet for intelligence.
//  System typography with tabular financial values and short transitions.
//
//  Gain/loss colour always comes from `Theme.positiveColor/negativeColor`
//  so colour-blind modes keep working; this file never hardcodes red/green.
//

import SwiftUI
import UIKit

// MARK: - Tokens

enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Horizontal page gutter.
        static let gutter: CGFloat = 20
    }

    enum Radius {
        static let chip: CGFloat = 12
        static let card: CGFloat = 20
        static let sheet: CGFloat = 28
    }

    /// The single brand accent: selection states, links, focus, the primary button.
    /// Coinbase-like blue: #0052FF on the light page (6.2:1), #5B8CFF on black (6.6:1).
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1)
            : UIColor(red: 0.0, green: 0.32, blue: 1.0, alpha: 1)
    })

    /// Fill for the primary button: a deeper blue in dark mode so white text keeps 4.5:1
    /// (the lighter `accent` is for text and links on black).
    static let accentFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.36, blue: 1.0, alpha: 1)
            : UIColor(red: 0.0, green: 0.32, blue: 1.0, alpha: 1)
    })

    /// The primary button: Revolut's pale lavender pill with navy text on black, the brand
    /// blue with white text on the light page.
    static let primaryFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.84, green: 0.87, blue: 1.0, alpha: 1)    // #D6DEFF
            : UIColor(red: 0.0, green: 0.32, blue: 1.0, alpha: 1)
    })
    static let primaryLabel = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.09, blue: 0.30, alpha: 1)   // #0A174D
            : UIColor.white
    })

    /// Short, un-bouncy spring for state changes.
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.88)
    static let quick = Motion.feedback

    /// Large money/number style: SF Pro with tabular digits (Coinbase / Fey numbers).
    static func money(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }

    /// Display type for headlines: bold SF Pro (was New York serif). Callers that asked for
    /// `.regular` get `.bold`, so a headline still reads as one.
    static func display(_ style: Font.TextStyle = .largeTitle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight == .regular ? .bold : weight)
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// `withAnimation` that degrades to no animation under Reduce Motion.
@MainActor
func dsAnimate(_ animation: Animation? = nil, _ body: () -> Void) {
    motionSafeWithAnimation(animation ?? DS.spring, body)
}

// MARK: - Button styles

/// Subtle press feedback for any tappable surface.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion && Motion.isEnabled ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .motionSafeAnimation(DS.quick, value: configuration.isPressed)
    }
}

/// Full-width primary action: accent-tinted Liquid Glass with white text.
struct PrimaryPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(DS.primaryLabel)
            .glassEffect(.regular.tint(DS.primaryFill).interactive(isEnabled), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion && Motion.isEnabled ? 0.985 : 1)
            .motionSafeAnimation(DS.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Full-width secondary action: clear Liquid Glass.
struct SecondaryPillButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(theme.primaryText)
            .glassEffect(.regular.interactive(isEnabled), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion && Motion.isEnabled ? 0.985 : 1)
            .motionSafeAnimation(DS.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Text-only action ("Not now", "Skip for now"). Keeps a 44pt target.
struct QuietTextButtonStyle: ButtonStyle {
    /// Onboarding paints its own dark background; `.secondary` follows the app's
    /// light/dark setting, so in Light mode it went dark-grey-on-navy and read as disabled.
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(onDark ? AnyShapeStyle(Color.white.opacity(0.72)) : AnyShapeStyle(.secondary))
            .frame(minHeight: 44)
            .padding(.horizontal, DS.Space.m)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Ticker logo

/// Company / coin logo on a white disc, with a monogram fallback.
/// Logos come from FMP's public image CDN (no key needed); it covers US
/// tickers, ASX (`BHP.AX`), ETFs and crypto pairs (`BTCUSD`).
struct TickerLogo: View {
    let symbol: String
    var kind: AssetKind = .stock
    var exchange: String = ""
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var colorScheme

    /// The logo's address for a listing (also used to tint a stock page with its brand colour).
    static func logoURL(symbol: String, kind: AssetKind, exchange: String) -> URL? {
        TickerLogo(symbol: symbol, kind: kind, exchange: exchange).url
    }

    private var logoSymbol: String {
        let upper = symbol.uppercased()
        switch kind {
        case .crypto:
            return upper.hasSuffix("USD") ? upper : upper + "USD"
        case .stock:
            if exchange == "ASX", !upper.hasSuffix(".AX") { return upper + ".AX" }
            return upper
        }
    }

    private var url: URL? {
        URL(string: "https://financialmodelingprep.com/image-stock/\(logoSymbol).png")
    }

    /// Set when the logo arrives from the network; a logo already in memory is drawn
    /// straight away (AsyncImage re-fetched on every appearance and flashed the monogram).
    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let uiImage = loaded ?? url.flatMap({ LogoImageCache.shared.cached($0) }) {
                let image = Image(uiImage: uiImage)
                ZStack {
                    // White marks (Visa, XRP…) get a dark disc; white is toned down in dark.
                    Circle().fill(LogoDisc.fill(for: image, key: logoSymbol, dark: colorScheme == .dark))
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.18)
                }
            } else {
                monogram
            }
        }
        .task(id: url) {
            guard let url, LogoImageCache.shared.cached(url) == nil else { return }
            let image = await LogoImageCache.shared.load(url)
            dsAnimate(DS.quick) { loaded = image }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let letters = String(symbol.replacingOccurrences(of: ".AX", with: "").prefix(symbol.count > 3 ? 2 : 1))
        return ZStack {
            Circle().fill(Self.tint(for: symbol).gradient)
            Text(letters)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
    }

    /// Stable colour per symbol so a ticker always looks the same.
    static func tint(for symbol: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.35, green: 0.45, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.90),
            Color(red: 0.13, green: 0.62, blue: 0.60), Color(red: 0.90, green: 0.45, blue: 0.25),
            Color(red: 0.22, green: 0.55, blue: 0.85), Color(red: 0.75, green: 0.30, blue: 0.50)
        ]
        let hash = symbol.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

// MARK: - Change pill

/// "▲ 1.58%" style pill. Arrow + sign keep it readable without colour.
struct ChangePill: View {
    let percent: Double
    var amount: String? = nil
    var compact = false
    @Environment(\.theme) private var theme

    private var isFlat: Bool { abs(percent) < 0.005 }
    private var isUp: Bool { percent >= 0 }
    private var tint: Color { isFlat ? theme.secondaryText : (isUp ? theme.positiveColor : theme.negativeColor) }

    var body: some View {
        HStack(spacing: 4) {
            if !isFlat {
                Image(systemName: isUp ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: compact ? 7 : 8, weight: .bold))
            }
            if let amount {
                Text(amount)
            }
            Text(String(format: "%.2f%%", abs(percent)))
        }
        // A number must never break across lines ("3.50" / "%" at large text sizes).
        .lineLimit(1)
        .fixedSize()
        .font((compact ? Font.caption : Font.subheadline).weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlat ? "Unchanged" : "\(isUp ? "Up" : "Down") \(String(format: "%.2f", abs(percent))) percent")
    }
}

// MARK: - Quote row layout

/// Logo + name on the left, price + change on the right. At accessibility text sizes
/// the numbers move under the name: side by side they broke mid-word and mid-number
/// ("BH/P", "A$60./03", "3.50/%"). After Apple Stocks, which stacks the same way.
struct AdaptiveQuoteRow<Identity: View, Numbers: View>: View {
    var spacing: CGFloat = DS.Space.m
    @ViewBuilder var identity: () -> Identity
    /// `stacked` = laid out under the name, so lay the numbers out in a row.
    @ViewBuilder var numbers: (_ stacked: Bool) -> Numbers
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                identity()
                numbers(true)
            }
        } else {
            HStack(spacing: spacing) {
                identity()
                Spacer(minLength: DS.Space.xs)
                numbers(false)
            }
        }
    }
}

/// Price over change (side by side when stacked under the name).
struct QuoteNumbers: View {
    let price: String
    let percent: Double
    let stacked: Bool
    var priceFont: Font = .body.weight(.semibold).monospacedDigit()
    @Environment(\.theme) private var theme

    var body: some View {
        let priceText = Text(price)
            .font(priceFont)
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .motionSafeAnimation(DS.quick, value: price)
        if stacked {
            HStack(spacing: DS.Space.s) {
                priceText
                ChangePill(percent: percent, compact: true)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                priceText
                ChangePill(percent: percent, compact: true)
            }
        }
    }
}

/// The same price/change footprint as QuoteNumbers while a quote is pending.
struct QuoteNumbersSkeleton: View {
    let stacked: Bool

    var body: some View {
        let layout = stacked
            ? AnyLayout(HStackLayout(spacing: DS.Space.s))
            : AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
        layout {
            SkeletonBlock(width: 57, height: 14)
            SkeletonBlock(width: 46, height: 14)
            if stacked { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: LocalizedStringKey
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.tap()
                    action()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DS.accent)
                .frame(minHeight: 44)
            }
        }
    }
}

// MARK: - Empty state

/// Branded, actionable empty state. Never a blank screen.
struct EmptyStateCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var primaryTitle: LocalizedStringKey? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: LocalizedStringKey? = nil
    var secondaryAction: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(LinearGradient(colors: [DS.accentFill, theme.glowSecondary],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .background(Circle().fill(DS.accentFill.opacity(0.35)).blur(radius: 14).scaleEffect(1.3))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let primaryTitle, let primaryAction {
                Button(primaryTitle) {
                    Haptics.tap()
                    primaryAction()
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle) {
                    Haptics.tap()
                    secondaryAction()
                }
                .buttonStyle(QuietTextButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .frostedCard(padding: DS.Space.xl)
    }
}

// MARK: - Card surface

extension View {
    /// The standard card surface used across the redesigned screens.
    func dsCard(padding: CGFloat = DS.Space.l) -> some View {
        modifier(DSCardModifier(padding: padding))
    }
}

private struct DSCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(theme.colorScheme == .dark ? theme.secondaryBackground : theme.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
    }
}
