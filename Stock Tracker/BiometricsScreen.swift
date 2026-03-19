//
//  BiometricsScreen.swift
//  Stock Tracker
//
//  OB-090: Face ID/Touch ID opt-in with privacy note.
//

import SwiftUI
import LocalAuthentication

struct BiometricsScreen: View {
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var biometryType: LABiometryType = .none

    private var biometryIcon: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Biometric icon with green glow
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.green.opacity(0.32), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                Circle()
                    .fill(Color.green.opacity(0.10))
                    .frame(width: 96, height: 96)

                Image(systemName: biometryIcon)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.green, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .green.opacity(0.5), radius: 16)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.7)

            Spacer().frame(height: 36)

            // Headline
            VStack(spacing: 12) {
                Text("Protect your portfolio")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("Lock the app so only you can\nsee your investments.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 28)

            // Privacy note card
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.body)
                    .foregroundColor(.green)
                Text("Your biometric data stays on your device. Stock Tracker never stores or transmits it.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.60))
            }
            .padding(16)
            .background(Color.white.opacity(0.07))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)

            Spacer()

            // CTAs
            VStack(spacing: 14) {
                OnboardingButton(title: "Enable \(biometryName)") {
                    enableBiometrics()
                }

                Button("Not now") {
                    UserDefaults.standard.set(false, forKey: "useBiometrics")
                    onComplete()
                }
                .font(.body)
                .foregroundColor(.white.opacity(0.42))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            checkBiometryType()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.10)) {
                appeared = true
            }
        }
    }

    private func checkBiometryType() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometryType = context.biometryType
        }
        // No auto-skip here — the orchestrator's advanceFrom(.notifications)
        // already skips this screen if biometrics are unavailable.
        // Auto-skipping in onAppear would fire prematurely due to
        // TabView pre-rendering adjacent pages.
    }

    private func enableBiometrics() {
        UserDefaults.standard.set(true, forKey: "useBiometrics")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Verify to enable app lock") { success, _ in
            DispatchQueue.main.async {
                onComplete()
            }
        }
    }
}
