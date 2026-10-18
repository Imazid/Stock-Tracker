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
    @State private var shown = !Motion.isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                guard Motion.isEnabled else { shown = true; return }
                // Only the first screenful cascades; later rows just arrive.
                let delay = index < 10 ? Double(index) * 0.045 : 0
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86).delay(delay)) { shown = true }
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
    @State private var tint: Color = .clear
    @State private var strength: Double = 0

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.22 * strength))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            )
            .onChange(of: value) { old, new in
                guard Motion.isEnabled, old > 0, new > 0, abs(new - old) > old * 1e-7 else { return }
                tint = new > old ? theme.positiveColor : theme.negativeColor
                strength = 1
                withAnimation(.easeOut(duration: 1.1).delay(0.15)) { strength = 0 }
            }
    }
}

extension View {
    /// Pulses green when `value` rises and red when it falls (a live quote ticking).
    func priceFlash(value: Double) -> some View { modifier(PriceFlash(value: value)) }
}

// MARK: - Scroll card motion

extension View {
    /// Cards settle in as they scroll onto the screen and ease back as they leave.
    @ViewBuilder
    func scrollCardMotion() -> some View {
        if Motion.isEnabled {
            scrollTransition(.interactive, axis: .vertical) { content, phase in
                content
                    .scaleEffect(phase.isIdentity ? 1 : 0.96, anchor: .center)
                    .opacity(phase.isIdentity ? 1 : 0.55)
            }
        } else {
            self
        }
    }
}

// MARK: - Celebration check

/// A check badge that pops in with an expanding ring. `trigger` changing replays it.
struct CelebrationCheck: View {
    var trigger: Bool
    var size: CGFloat = 64
    var foreground: Color = .black
    var background: Color = .white

    @State private var popped = !Motion.isEnabled
    @State private var ring = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(background.opacity(0.6), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(ring ? 1.9 : 1)
                .opacity(ring ? 0 : (popped ? 0.8 : 0))
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(foreground)
                .symbolEffect(.bounce, options: .nonRepeating, value: popped)
                .frame(width: size, height: size)
                .background(Circle().fill(background))
                .scaleEffect(popped ? 1 : 0.5)
                .opacity(popped ? 1 : 0)
        }
        .accessibilityHidden(true)
        .onAppear { if trigger { play() } }
        .onChange(of: trigger) { _, on in if on { play() } }
    }

    private func play() {
        guard Motion.isEnabled else { popped = true; return }
        popped = false
        ring = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { popped = true }
        withAnimation(.easeOut(duration: 0.9).delay(0.12)) { ring = true }
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
        TimelineView(.animation(paused: start == nil)) { context in
            Canvas { canvas, size in
                guard let start else { return }
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
    }

    private func fire() {
        guard Motion.isEnabled else { return }
        pieces = (0..<130).map { _ in
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
