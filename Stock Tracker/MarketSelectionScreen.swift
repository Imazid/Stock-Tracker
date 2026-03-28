//
//  MarketSelectionScreen.swift
//  Stock Tracker
//
//  Onboarding step: lets the user pick which market(s) they follow.
//  Saves to preferredMarket (@AppStorage key) so the home screen,
//  market status badge, and ASX/NYSE session times are already correct
//  on first launch.
//

import SwiftUI

struct MarketSelectionScreen: View {
    let onContinue: () -> Void

    @AppStorage("preferredMarket") private var preferredMarket = "US"
    @State private var selected: MarketChoice = .us
    @State private var appeared = false

    enum MarketChoice: String, CaseIterable {
        case us   = "US"
        case au   = "AU"
        case both = "BOTH"

        var flag: String {
            switch self {
            case .us:   return "🇺🇸"
            case .au:   return "🇦🇺"
            case .both: return "🌐"
            }
        }

        var title: String {
            switch self {
            case .us:   return "US Markets"
            case .au:   return "Australian Markets"
            case .both: return "Both"
            }
        }

        var subtitle: String {
            switch self {
            case .us:   return "NYSE · NASDAQ · Crypto"
            case .au:   return "ASX · Chi-X"
            case .both: return "All markets, all sessions"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            // ── Globe icon with cyan glow ────────────────────────────────────
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.32), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 64
                        )
                    )
                    .frame(width: 128, height: 128)

                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .cyan.opacity(0.5), radius: 16)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.7)

            Spacer().frame(height: 32)

            // ── Header ───────────────────────────────────────────────────────
            VStack(spacing: 12) {
                Text("Which markets do\nyou follow?")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text("We'll show relevant market hours\nand session data for you.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .padding(.horizontal, 32)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            Spacer().frame(height: 36)

            // ── Market option cards ───────────────────────────────────────────
            VStack(spacing: 12) {
                ForEach(MarketChoice.allCases, id: \.rawValue) { choice in
                    MarketOptionCard(
                        choice: choice,
                        isSelected: selected == choice
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            selected = choice
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 24)
                    .animation(
                        .spring(response: 0.5, dampingFraction: 0.8)
                            .delay(0.18 + Double(choice.hashValue % 3) * 0.08),
                        value: appeared
                    )
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            // ── CTA ───────────────────────────────────────────────────────────
            OnboardingButton(title: "Continue") {
                switch selected {
                case .us:   preferredMarket = "US"
                case .au:   preferredMarket = "AU"
                case .both: preferredMarket = "US" // home screen defaults to US clock; "BOTH" handled in UI
                }
                onContinue()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            // Sync initial selection from stored preference
            switch preferredMarket {
            case "AU":   selected = .au
            case "BOTH": selected = .both
            default:     selected = .us
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78).delay(0.10)) {
                appeared = true
            }
        }
    }
}

// MARK: - Option Card

struct MarketOptionCard: View {
    let choice: MarketSelectionScreen.MarketChoice
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 18) {
                // Flag emoji
                Text(choice.flag)
                    .font(.system(size: 34))
                    .frame(width: 50)

                // Labels
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.body.bold())
                        .foregroundColor(.white)
                    Text(choice.subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.50))
                }

                Spacer()

                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.cyan : Color.white.opacity(0.22),
                            lineWidth: 2
                        )
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected ? Color.cyan.opacity(0.10) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                isSelected ? Color.cyan.opacity(0.50) : Color.white.opacity(0.09),
                                lineWidth: 1.5
                            )
                    )
            )
            .shadow(color: isSelected ? Color.cyan.opacity(0.18) : Color.clear, radius: 16)
        }
        .buttonStyle(.plain)
    }
}
