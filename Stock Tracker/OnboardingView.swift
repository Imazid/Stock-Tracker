//
//  OnboardingView.swift
//  Stock Tracker
//
//  Container for the redesigned onboarding (see OnboardingModel.swift for the
//  flow). Patterns follow Mobbin references for finance apps: Public's dark
//  welcome with serif headline and icon-tile bullets, Stake's ASX + Wall St
//  logo field, Cash App's "Select stocks" picker, Quicken/Monarch's
//  "add accounts" options, Atoms/Tempo notification pre-prompts, and
//  Finimize's "finish your setup" account step placed last.
//

import SwiftUI

struct OnboardingView: View {
    var onComplete: (() -> Void)? = nil

    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager
    @EnvironmentObject private var subscriptionManager: SubscriptionManager

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                if viewModel.step != .welcome && viewModel.step != .done {
                    OnboardingTopBar()
                        .transition(.opacity)
                }

                ZStack {
                    stepView
                        .id(viewModel.step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(viewModel)
        .environment(\.onboardingFinish, finish)
        .preferredColorScheme(.dark)
        .onAppear {
            let auth = supabaseAuth
            viewModel.isSignedIn = { [weak auth] in auth?.isSignedIn ?? false }
            viewModel.watchlistLimit = subscriptionManager.currentTier.maxWatchlistAssets
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch viewModel.step {
        case .welcome:   OnboardingWelcomeStep()
        case .markets:   OnboardingMarketsStep()
        case .follow:    OnboardingFollowStep()
        case .portfolio: OnboardingPortfolioStep()
        case .alerts:    OnboardingAlertsStep()
        case .security:  OnboardingSecurityStep()
        case .account:   OnboardingAccountStep()
        case .done:      OnboardingDoneStep()
        }
    }

    private var stepTransition: AnyTransition {
        let forward = AnyTransition.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
        let backward = AnyTransition.asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
        return viewModel.movingBack ? backward : forward
    }

    private func finish() {
        viewModel.commit(marketData: marketData)
        Haptics.success()
        onComplete?()
    }
}

// MARK: - Finish action

private struct OnboardingFinishKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Commits every onboarding choice and hands over to the app.
    var onboardingFinish: () -> Void {
        get { self[OnboardingFinishKey.self] }
        set { self[OnboardingFinishKey.self] = newValue }
    }
}

// MARK: - Background

struct OnboardingBackground: View {
    static let base = Color(red: 0.035, green: 0.035, blue: 0.045)

    var body: some View {
        ZStack {
            Self.base
            RadialGradient(
                colors: [DS.accent.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top bar

struct OnboardingTopBar: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel

    var body: some View {
        HStack(spacing: DS.Space.l) {
            Button {
                Haptics.tap()
                viewModel.back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Back")

            SegmentedProgress(count: viewModel.progressSteps.count, index: viewModel.progressIndex)
                .padding(.trailing, 44 + DS.Space.l) // optically centre against the back button
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, DS.Space.s)
    }
}

struct SegmentedProgress: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                Capsule()
                    .fill(i <= index ? Color.white : Color.white.opacity(0.16))
                    .frame(height: 4)
            }
        }
        .animation(DS.spring, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

// MARK: - Page scaffold

/// Title + subtitle header, scrolling body, and a footer pinned above the home indicator.
struct OnboardingPage<Content: View, Footer: View>: View {
    var eyebrow: LocalizedStringKey? = nil
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    /// The footer rides up with the keyboard; on the account step it covered the
    /// password field and "Create account", so a tap there hit "Not now" and skipped
    /// sign-up. While typing, the form's own button is the action.
    @State private var keyboardUp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DS.accent)
                            .textCase(.uppercase)
                            .tracking(0.6)
                    }
                    Text(title)
                        .font(DS.display(.largeTitle))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardUp {
                pinnedFooter
            }
        }
    }

    private var pinnedFooter: some View {
        VStack(spacing: DS.Space.s) { footer }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .background {
                // Solid behind the footer, with a short fade above it so
                // scrolling content never sits under text.
                VStack(spacing: 0) {
                    LinearGradient(colors: [OnboardingBackground.base.opacity(0), OnboardingBackground.base],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                    OnboardingBackground.base
                }
                .padding(.top, -28)
                .ignoresSafeArea()
            }
    }
}

// MARK: - Choice row

/// Tappable option row used for markets and portfolio sources.
struct OnboardingChoiceRow<Leading: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var badge: LocalizedStringKey? = nil
    var isSelected: Bool = false
    var showsCheck: Bool = true
    var trailingChevron: Bool = false
    @ViewBuilder var leading: Leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.l) {
                leading
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.Space.s) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(DS.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DS.accent.opacity(0.16)))
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)

                if showsCheck {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? DS.accent : Color.white.opacity(0.28))
                        .contentTransition(.symbolEffect(.replace))
                } else if trailingChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(DS.Space.l)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(isSelected ? DS.accent.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? DS.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
