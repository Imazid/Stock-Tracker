//
//  OnboardingView.swift
//  Stock Tracker
//
//  8-phase guided onboarding flow (Variant B).
//  Steps are conditionally skipped based on user actions:
//    - OTP skipped if user used Apple Sign In or skipped account
//    - Biometrics skipped if device has no Face ID / Touch ID
//    - Portfolio Add skipped only if user explicitly skips
//

import SwiftUI
import Combine
import LocalAuthentication

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome        = 0   // OB-020
    case features       = 1   // OB-025
    case account        = 2   // OB-030
    case otp            = 3   // OB-040
    case market         = 4   // OB-050
    case watchlist      = 5   // OB-060
    case portfolio      = 6   // OB-070
    case notifications  = 7   // OB-080
    case biometrics     = 8   // OB-090
    case complete       = 9   // OB-100
}

// MARK: - ViewModel

@MainActor
class OnboardingViewModel: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var accountMethod: String? = nil   // "apple", "email", or nil (skipped)
    @Published var accountEmail: String = ""

    var skippedAccount: Bool { accountMethod == nil }

    func goTo(_ step: OnboardingStep) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
            currentStep = step
        }
    }

    func advanceFrom(_ step: OnboardingStep) {
        switch step {
        case .welcome:
            goTo(.features)

        case .features:
            goTo(.account)

        case .account:
            if accountMethod == "apple" {
                // SSO — skip OTP
                goTo(.market)
            } else if accountMethod == "email" {
                goTo(.otp)
            } else {
                // Skipped account — skip OTP
                goTo(.market)
            }

        case .otp:
            goTo(.market)

        case .market:
            goTo(.watchlist)

        case .watchlist:
            goTo(.portfolio)

        case .portfolio:
            goTo(.notifications)

        case .notifications:
            // Check if biometrics available
            let context = LAContext()
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                goTo(.biometrics)
            } else {
                goTo(.complete)
            }

        case .biometrics:
            goTo(.complete)

        case .complete:
            break // Handled by onComplete callback
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
}

// MARK: - Container View

struct OnboardingView: View {
    var onComplete: (() -> Void)? = nil
    @StateObject private var viewModel = OnboardingViewModel()
    @Environment(\.dismiss) var dismiss

    // Accent color shifts per step
    private var stepAccent: Color {
        switch viewModel.currentStep {
        case .welcome:       return .blue
        case .features:      return Color(red: 0.25, green: 0.88, blue: 0.50)
        case .account:       return .blue
        case .otp:           return .purple
        case .market:        return .cyan
        case .watchlist:     return .blue
        case .portfolio:     return Color(red: 0.25, green: 0.88, blue: 0.50)
        case .notifications: return .purple
        case .biometrics:    return .green
        case .complete:      return .green
        }
    }

    var body: some View {
        ZStack {
            // Pure black base
            Color.black.ignoresSafeArea()

            // Per-step accent radial glow
            RadialGradient(
                colors: [stepAccent.opacity(0.12), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.20),
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: viewModel.currentStep)

            // Screen content
            TabView(selection: $viewModel.currentStep) {

                // 1 — Welcome Hero (OB-020)
                WelcomeScreen(onContinue: { viewModel.advanceFrom(.welcome) })
                    .tag(OnboardingStep.welcome)

                // 2 — Feature Value Tour (OB-025)
                CoreValueScreen(
                    onContinue: { viewModel.advanceFrom(.features) },
                    onSkip:     { viewModel.advanceFrom(.features) }
                )
                .tag(OnboardingStep.features)

                // 3 — Account Creation (OB-030)
                AccountCreationScreen(
                    onAccountCreated: { method, email in
                        viewModel.accountMethod = method
                        viewModel.accountEmail = email
                        viewModel.advanceFrom(.account)
                    },
                    onSkip: {
                        viewModel.accountMethod = nil
                        viewModel.advanceFrom(.account)
                    }
                )
                .tag(OnboardingStep.account)

                // 4 — OTP Verification (OB-040)
                OTPVerificationScreen(
                    email: viewModel.accountEmail,
                    onVerified: { viewModel.advanceFrom(.otp) },
                    onBack: { viewModel.goTo(.account) }
                )
                .tag(OnboardingStep.otp)

                // 5 — Market Selection (OB-050)
                MarketSelectionScreen(onContinue: { viewModel.advanceFrom(.market) })
                    .tag(OnboardingStep.market)

                // 6 — Watchlist Builder (OB-060)
                PortfolioSetupScreen(
                    onComplete: {
                        viewModel.advanceFrom(.watchlist)
                    },
                    onSkip: {
                        viewModel.advanceFrom(.watchlist)
                    }
                )
                .tag(OnboardingStep.watchlist)

                // 7 — Portfolio Add (OB-070)
                PortfolioAddScreen(
                    onComplete: { viewModel.advanceFrom(.portfolio) },
                    onSkip:     { viewModel.advanceFrom(.portfolio) }
                )
                .tag(OnboardingStep.portfolio)

                // 8 — Notifications (OB-080)
                PermissionsScreen(onComplete: { viewModel.advanceFrom(.notifications) })
                    .tag(OnboardingStep.notifications)

                // 9 — Biometrics (OB-090)
                BiometricsScreen(onComplete: { viewModel.advanceFrom(.biometrics) })
                    .tag(OnboardingStep.biometrics)

                // 10 — Complete (OB-100)
                OnboardingCompleteScreen(
                    onFinish: {
                        viewModel.completeOnboarding()
                        onComplete?()
                    }
                )
                .tag(OnboardingStep.complete)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Swipe disabled — buttons drive the flow
            .gesture(DragGesture())

            // Page dots — anchored just above the home indicator
            VStack {
                Spacer()
                OnboardingPageIndicator(
                    currentPage: viewModel.currentStep.rawValue,
                    pageCount: OnboardingStep.allCases.count,
                    accentColor: stepAccent
                )
                .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page Dots

struct OnboardingPageIndicator: View {
    let currentPage: Int
    let pageCount:   Int
    let accentColor: Color

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? accentColor : Color.white.opacity(0.22))
                    .frame(width: index == currentPage ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
            }
        }
    }
}
