//
//  OTPVerificationScreen.swift
//  Stock Tracker
//
//  OB-040: 6-digit OTP input with auto-advance, paste support, resend countdown.
//  Note: Supabase email confirmation works via magic link by default.
//  If Supabase is configured with OTP, the 6-digit input verifies via verifyOTP.
//

import SwiftUI
import OSLog
import Auth

struct OTPVerificationScreen: View {
    let email: String
    let onVerified: () -> Void
    let onBack: () -> Void

    @EnvironmentObject var supabaseAuth: SupabaseAuthManager
    @State private var digits: [String] = Array(repeating: "", count: 6)
    @State private var focusedIndex: Int = 0
    @State private var errorMessage: String?
    @State private var isVerifying = false
    @State private var resendCountdown: Int = 30
    @State private var appeared = false
    @State private var showSuccess = false
    @FocusState private var fieldFocus: Int?

    private var code: String { digits.joined() }
    private var isCodeComplete: Bool { code.count == 6 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 80)

            // Mail icon
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.purple.opacity(0.32), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 64
                        )
                    )
                    .frame(width: 128, height: 128)

                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .purple.opacity(0.5), radius: 16)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.7)

            Spacer().frame(height: 28)

            // Headline
            VStack(spacing: 12) {
                Text("Check your email")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("We sent a 6-digit code to\n**\(email)**")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            }
            .padding(.horizontal, 32)
            .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 40)

            // OTP cells
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    OTPCell(
                        text: $digits[index],
                        isFocused: fieldFocus == index,
                        isError: errorMessage != nil,
                        isSuccess: showSuccess
                    )
                    .focused($fieldFocus, equals: index)
                    .onChange(of: digits[index]) { _, newValue in
                        handleDigitChange(at: index, newValue: newValue)
                    }
                }
            }
            .padding(.horizontal, 40)

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 12)
            }

            Spacer().frame(height: 28)

            // Resend
            if resendCountdown > 0 {
                Text("Resend code in 0:\(String(format: "%02d", resendCountdown))")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.40))
            } else {
                Button("Didn't get it? Resend code") {
                    resendCode()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            Spacer().frame(height: 16)

            // Back link
            Button("Wrong email? Go back") {
                onBack()
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.42))

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.10)) {
                appeared = true
            }
            fieldFocus = 0
            startCountdown()
        }
    }

    // MARK: - Logic

    private func handleDigitChange(at index: Int, newValue: String) {
        // Handle paste of full code
        if newValue.count > 1 {
            let cleaned = String(newValue.filter(\.isNumber).prefix(6))
            for (i, char) in cleaned.enumerated() where i < 6 {
                digits[i] = String(char)
            }
            fieldFocus = min(cleaned.count, 5)
            if cleaned.count == 6 { verifyCode() }
            return
        }

        // Single digit: advance focus
        if !newValue.isEmpty && index < 5 {
            fieldFocus = index + 1
        }

        // Auto-verify when complete
        if isCodeComplete {
            verifyCode()
        }
    }

    private func verifyCode() {
        guard !isVerifying else { return }
        isVerifying = true
        errorMessage = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                try await SupabaseManager.auth.verifyOTP(
                    email: email,
                    token: code,
                    type: .email
                )
                showSuccess = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(for: .milliseconds(800))
                onVerified()
            } catch {
                errorMessage = "That code doesn't match. Check your email and try again."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isVerifying = false
            }
        }
    }

    private func resendCode() {
        resendCountdown = 30
        startCountdown()
        Task {
            try? await SupabaseManager.auth.resend(email: email, type: .signup)
        }
    }

    private func startCountdown() {
        Task {
            while resendCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendCountdown -= 1
            }
        }
    }
}

// MARK: - OTP Cell

struct OTPCell: View {
    @Binding var text: String
    let isFocused: Bool
    let isError: Bool
    let isSuccess: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .multilineTextAlignment(.center)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 48, height: 56)
            .background(Color.white.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSuccess ? Color.green :
                        isError ? Color.red.opacity(0.6) :
                        isFocused ? Color.blue : Color.white.opacity(0.15),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .onChange(of: text) { _, newValue in
                // Limit to single digit
                if newValue.count > 1 && !newValue.allSatisfy(\.isNumber) {
                    text = String(newValue.filter(\.isNumber).prefix(1))
                }
            }
    }
}
