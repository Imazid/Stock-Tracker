//
//  Motion.swift
//  Stock Tracker
//
//  The app's motion kit, after Robinhood / Coinbase (charts that draw in, prices
//  that flash as they tick), QUITTR / Givingli (confetti and a check when something
//  is done) and Acorns (a staged reveal) on Mobbin:
//    • `staggeredAppear(_:)` — short lists rise in one after another
//    • `priceFlash(value:)`  — a green / red pulse when a live price moves
//    • `ConfettiBurst`       — a finite burst for real milestones
//    • `CelebrationCheck`    — a check badge that pops with a ring
//    • `scrollCardMotion()`  — cards ease in/out at the scroll edges
//  All of it is decorative: off with Reduce Motion, and off under UI tests (taps and
//  screenshots need the settled screen) unless `-UITestKeepMotion` is passed.
//

import SwiftUI
import UIKit

enum Motion {
    static let feedback = Animation.easeOut(duration: 0.16)
    static let reveal = Animation.easeOut(duration: 0.26)

    /// Decorative motion is allowed (checked live, so Reduce Motion applies at once).
    static var isEnabled: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestFreshInstall") && !args.contains("-UITestKeepMotion") { return false }
        #endif
        return !UIAccessibility.isReduceMotionEnabled
    }
}

// MARK: - Staggered appear

private struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion || !Motion.isEnabled || index >= 6
        return content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .onAppear {
                guard !visible else { shown = true; return }
                withAnimation(Motion.reveal.delay(Double(index) * 0.022)) { shown = true }
            }
    }
}

extension View {
    /// Rises into place, `index` steps after the first item.
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

// MARK: - Price flash

private struct PriceFlash: ViewModifier {
    let value: Double
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tint: Color = .clear
    @State private var pulse = 0

    func body(content: Content) -> some View {
        content
            .background {
                if !reduceMotion && Motion.isEnabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .keyframeAnimator(initialValue: 0.0, trigger: pulse) { highlight, strength in
                            highlight.opacity(strength)
                        } keyframes: { _ in
                            MoveKeyframe(1.0)
                            LinearKeyframe(1.0, duration: 0.08)
                            CubicKeyframe(0.0, duration: 0.65)
                        }
                        .padding(.horizontal, -4)
                        .padding(.vertical, -2)
                }
            }
            .onChange(of: value) { old, new in
                guard !reduceMotion, Motion.isEnabled, old > 0, new > 0,
                      old.isFinite, new.isFinite, abs(new - old) > old * 1e-7 else { return }
                tint = new > old ? theme.positiveColor : theme.negativeColor
                pulse += 1
            }
    }
}

extension View {
    /// Pulses green when `value` rises and red when it falls (a live quote ticking).
    func priceFlash(value: Double) -> some View { modifier(PriceFlash(value: value)) }
}

// MARK: - Scroll card motion

extension View {
    /// Adds a slight scale change at the scroll edges.
    func scrollCardMotion() -> some View { modifier(ScrollCardMotion()) }
}

private struct ScrollCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let enabled = !reduceMotion && Motion.isEnabled
        content.scrollTransition(.interactive, axis: .vertical) { view, phase in
            view.scaleEffect(enabled && !phase.isIdentity ? 0.99 : 1)
        }
    }
}

private struct ChartPlotReveal<Key: Equatable>: ViewModifier {
    let key: Key
    let isScrubbing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var replay = 0

    func body(content: Content) -> some View {
        let enabled = !reduceMotion && Motion.isEnabled
        return content
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .keyframeAnimator(initialValue: 1.0, trigger: replay) { mask, progress in
                            mask.frame(width: geometry.size.width * (enabled && !isScrubbing ? progress : 1))
                        } keyframes: { _ in
                            MoveKeyframe(0.0)
                            CubicKeyframe(1.0, duration: 0.42)
                        }
                }
            }
            .onChange(of: key, initial: true) {
                if enabled { replay += 1 }
            }
    }
}

extension View {
    /// Reveals the plot while its axes stay in place.
    func chartPlotReveal<Key: Equatable>(_ key: Key, isScrubbing: Bool) -> some View {
        modifier(ChartPlotReveal(key: key, isScrubbing: isScrubbing))
    }
}

// MARK: - Celebration check

/// A check badge that pops in with an expanding ring. `trigger` changing replays it.
struct CelebrationCheck: View {
    var trigger: Bool
    var size: CGFloat = 64
    var foreground: Color = .black
    var background: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var ring = false

    var body: some View {
        let enabled = !reduceMotion && Motion.isEnabled
        let visible = popped || !enabled
        return ZStack {
            Circle()
                .strokeBorder(background.opacity(0.6), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(ring ? 1.9 : 1)
                .opacity(enabled && popped && !ring ? 0.6 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(background))
                .scaleEffect(visible ? 1 : 0.82)
                .opacity(visible ? 1 : 0)
        }
        .accessibilityHidden(true)
        .onAppear { if trigger { play() } }
        .onChange(of: trigger) { _, on in if on { play() } }
    }

    private func play() {
        guard !reduceMotion, Motion.isEnabled else { popped = true; return }
        popped = false
        ring = false
        withAnimation(DS.spring) { popped = true }
        withAnimation(.easeOut(duration: 0.55).delay(0.08)) { ring = true }
    }
}

// MARK: - Confetti

/// A one-off confetti burst for real milestones (onboarding done, a broker connected):
/// pieces fire up and out from `origin`, slow in the air, then tumble down. Draws with
/// Canvas on a timeline that only runs during the burst, so it costs nothing afterwards.
/// Changing `trigger` fires it again.
struct ConfettiBurst: View {
    var trigger: Int
    /// Where it bursts from, in this view's unit space (e.g. over a check badge).
    var origin: UnitPoint = UnitPoint(x: 0.5, y: 0.3)

    private struct Piece {
        let angle: Double, speed: Double, delay: Double, spin: Double, wobble: Double
        let width: Double, height: Double, colorIndex: Int
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [Piece] = []
    @State private var start: Date?
    private static let duration = 3.0
    private static let gravity = 1_100.0   // pt/s²
    private static let drag = 1.7          // per second
    private static let colors: [Color] = [
        Color(red: 0.42, green: 0.66, blue: 1.0), Color(red: 0.20, green: 0.80, blue: 0.55),
        Color(red: 1.0, green: 0.78, blue: 0.25), Color(red: 1.0, green: 0.45, blue: 0.45),
        Color(red: 0.72, green: 0.52, blue: 1.0), .white
    ]

    var body: some View {
        TimelineView(.animation(paused: start == nil || reduceMotion)) { context in
            Canvas { canvas, size in
                guard !reduceMotion, let start else { return }
                let t = context.date.timeIntervalSince(start)
                let ox = origin.x * size.width, oy = origin.y * size.height
                for piece in pieces {
                    let local = t - piece.delay
                    guard local > 0 else { continue }
                    let progress = local / Self.duration
                    guard progress < 1 else { continue }
                    // Launch velocity decays with air drag; gravity pulls towards a terminal speed.
                    let travelled = (1 - exp(-Self.drag * local)) / Self.drag
                    let x = ox + cos(piece.angle) * piece.speed * travelled + sin(local * 3 + piece.wobble) * 10
                    let y = oy + sin(piece.angle) * piece.speed * travelled + Self.gravity / Self.drag * (local - travelled)
                    guard y < size.height + 30, x > -30, x < size.width + 30 else { continue }
                    var copy = canvas
                    copy.opacity = progress > 0.7 ? (1 - progress) / 0.3 : 1
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .degrees(piece.spin * local * 360))
                    // Flip on one axis for a tumbling paper look.
                    copy.scaleBy(x: 1, y: abs(cos(local * piece.spin * 4)) * 0.8 + 0.2)
                    let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                    copy.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                              with: .color(Self.colors[piece.colorIndex % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if trigger > 0 { fire() } }
        .onChange(of: trigger) { _, _ in fire() }
        .onChange(of: reduceMotion) { _, reduced in if reduced { start = nil } }
    }

    private func fire() {
        guard !reduceMotion, Motion.isEnabled else { return }
        pieces = (0..<72).map { _ in
            // A fan pointing up (−90°), spread ±70°, so pieces arc out to both sides.
            Piece(angle: -.pi / 2 + .random(in: -1.22...1.22), speed: .random(in: 520...1_150),
                  delay: .random(in: 0...0.12), spin: .random(in: -1.4...1.4), wobble: .random(in: 0...6),
                  width: .random(in: 6...10), height: .random(in: 9...15), colorIndex: .random(in: 0..<6))
        }
        let begin = Date()
        start = begin
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.5) {
            if start == begin { start = nil }
        }
    }
}
