//
//  PermissionsScreen.swift
//  Stock Tracker
//
//  Final onboarding step: price-alert notification permission.
//

import OSLog
import SwiftUI
import UserNotifications

struct PermissionsScreen: View {
    let onComplete: () -> Void

    @State private var bellRotation = 0.0
    @State private var bellScale: Double = 0.6
    @State private var bellOpacity: Double = 0
    @State private var notificationOffset: CGFloat = 60
    @State private var notificationOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // ── Bell icon with glow ──────────────────────────────────────────
            ZStack {
                // Outer soft glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.purple.opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)

                // Inner accent circle
                Circle()
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 96, height: 96)

                Image(systemName: "bell.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.75, green: 0.40, blue: 1.0), Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .purple.opacity(0.55), radius: 16)
                    .rotationEffect(.degrees(bellRotation))
            }
            .scaleEffect(bellScale)
            .opacity(bellOpacity)

            Spacer().frame(height: 36)

            // ── Notification preview card ────────────────────────────────────
            AlertNotificationCard()
                .padding(.horizontal, 36)
                .offset(y: notificationOffset)
                .opacity(notificationOpacity)

            Spacer().frame(height: 44)

            // ── Headline + subtitle ──────────────────────────────────────────
            VStack(spacing: 12) {
                Text("Stay informed,\nnot overwhelmed")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text("Get alerts only when prices hit your targets.\nNo spam, no noise.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .padding(.horizontal, 36)
            .opacity(contentOpacity)

            Spacer()

            // Fine print
            Text("Prices refresh every 15 min while markets are open.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.36))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(contentOpacity)

            Spacer().frame(height: 28)

            // ── CTAs ──────────────────────────────────────────────────────────
            VStack(spacing: 14) {
                OnboardingButton(title: "Enable Price Alerts") {
                    requestNotificationPermission()
                    onComplete()
                }

                Button("Not now") { onComplete() }
                    .font(.body)
                    .foregroundColor(.white.opacity(0.42))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
            .opacity(contentOpacity)
        }
        .onAppear { runEntranceAnimations() }
    }

    private func runEntranceAnimations() {
        // Bell springs in
        withAnimation(.spring(response: 0.65, dampingFraction: 0.70).delay(0.10)) {
            bellScale   = 1.0
            bellOpacity = 1.0
        }

        // Bell ring — three rocks back and forth
        let ringDelay = 0.65
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45).delay(ringDelay)) {
            bellRotation = 18
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45).delay(ringDelay + 0.22)) {
            bellRotation = -18
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45).delay(ringDelay + 0.44)) {
            bellRotation = 10
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45).delay(ringDelay + 0.66)) {
            bellRotation = -10
        }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.60).delay(ringDelay + 0.88)) {
            bellRotation = 0
        }

        // Notification card slides up
        withAnimation(.spring(response: 0.60, dampingFraction: 0.80).delay(1.30)) {
            notificationOffset  = 0
            notificationOpacity = 1
        }

        // Static content fades in
        withAnimation(.easeOut(duration: 0.55).delay(1.00)) {
            contentOpacity = 1
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                AppLogger.general.info("Notification permission granted during onboarding")
            } else {
                AppLogger.general.info("Notification permission denied during onboarding")
            }
        }
    }
}

// MARK: - Notification Preview Card

struct AlertNotificationCard: View {
    var body: some View {
        HStack(spacing: 14) {
            // App icon mock
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    LinearGradient(
                        colors: [Color.blue, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Stock Tracker")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Text("now")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.40))
                }

                Text("AAPL reached $180 — your target price")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}
