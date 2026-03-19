//
//  AccountCreationScreen.swift
//  Stock Tracker
//
//  OB-030: Account creation with Apple SSO, email/password, skip option.
//

import SwiftUI
import Combine
import OSLog

@MainActor
class AccountCreationViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var emailError: String?
    @Published var passwordError: String?
    @Published var isLoading = false
    @Published var generalError: String?

    var isFormValid: Bool {
        validateEmail(silent: true) && password.count >= 8
    }

    func validateEmail(silent: Bool = false) -> Bool {
        let pattern = "[^@]+@[^@]+\\.[^@]+"
        let isValid = email.range(of: pattern, options: .regularExpression) != nil
        if !silent && !isValid && !email.isEmpty {
            emailError = "Please enter a valid email address"
        } else if isValid {
            emailError = nil
        }
        return isValid
    }

    func validatePassword(silent: Bool = false) -> Bool {
        let isValid = password.count >= 8
        if !silent && !isValid && !password.isEmpty {
            passwordError = "Password must be at least 8 characters"
        } else if isValid {
            passwordError = nil
        }
        return isValid
    }
}

struct AccountCreationScreen: View {
    let onAccountCreated: (_ method: String, _ email: String) -> Void
    let onSkip: () -> Void

    @EnvironmentObject var supabaseAuth: SupabaseAuthManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = AccountCreationViewModel()
    @State private var showPassword = false
    @State private var appeared = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                // Shield icon with gradient
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.blue.opacity(0.32), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 64
                            )
                        )
                        .frame(width: 128, height: 128)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .blue.opacity(0.5), radius: 16)
                }
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.7)

                Spacer().frame(height: 28)

                // Headline
                VStack(spacing: 12) {
                    Text("Secure your portfolio")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("Sign in to sync your data across devices\nand keep your watchlist safe.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                }
                .padding(.horizontal, 32)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                Spacer().frame(height: 32)

                // SSO Buttons (hidden offline)
                if networkMonitor.isConnected {
                    ssoButtons
                        .padding(.horizontal, 40)

                    // OR divider
                    orDivider
                        .padding(.vertical, 20)
                        .padding(.horizontal, 40)
                }

                // Email form
                emailForm
                    .padding(.horizontal, 40)

                // General error
                if let error = viewModel.generalError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 12)
                        .padding(.horizontal, 40)
                }

                // Offline note
                if !networkMonitor.isConnected {
                    Text("Account creation requires internet.\nContinue without an account to get started.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .padding(.horizontal, 40)
                }

                Spacer().frame(height: 24)

                // Privacy note
                Text("Your data is encrypted and stored securely.\nWe never sell your information.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.36))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer().frame(height: 32)

                // CTAs
                VStack(spacing: 14) {
                    OnboardingButton(
                        title: "Create Account",
                        disabled: !viewModel.isFormValid || viewModel.isLoading
                    ) {
                        createAccount()
                    }

                    Button("Continue without an account") {
                        onSkip()
                    }
                    .font(.body)
                    .foregroundColor(.white.opacity(0.42))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.10)) {
                appeared = true
            }
        }
    }
}

// MARK: - Sub-views
extension AccountCreationScreen {
    @ViewBuilder
    private var ssoButtons: some View {
        VStack(spacing: 12) {
            // Sign in with Apple
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    await supabaseAuth.signInWithApple()
                    if supabaseAuth.isSignedIn {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onAccountCreated("apple", supabaseAuth.userEmail ?? "")
                    } else if case .error(let msg) = supabaseAuth.authState {
                        viewModel.generalError = msg
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo")
                        .font(.title3)
                    Text("Sign in with Apple")
                        .font(.body.weight(.semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.white)
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var orDivider: some View {
        HStack(spacing: 16) {
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            Text("or")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.40))
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var emailForm: some View {
        VStack(spacing: 14) {
            // Email field
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope")
                        .foregroundColor(.white.opacity(0.5))
                    TextField("Email address", text: $viewModel.email)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                }
                .padding(14)
                .background(Color.white.opacity(0.1))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(viewModel.emailError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                )

                if let error = viewModel.emailError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.leading, 4)
                }
            }

            // Password field
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .foregroundColor(.white.opacity(0.5))

                    Group {
                        if showPassword {
                            TextField("Create a password", text: $viewModel.password)
                        } else {
                            SecureField("Create a password", text: $viewModel.password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .password)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                .padding(14)
                .background(Color.white.opacity(0.1))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(viewModel.passwordError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                )

                if let error = viewModel.passwordError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.leading, 4)
                } else {
                    Text("At least 8 characters")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.36))
                        .padding(.leading, 4)
                }
            }
        }
    }
}

// MARK: - Actions
extension AccountCreationScreen {
    private func createAccount() {
        viewModel.generalError = nil
        _ = viewModel.validateEmail()
        _ = viewModel.validatePassword()
        guard viewModel.isFormValid else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        viewModel.isLoading = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        Task {
            await supabaseAuth.signUp(email: viewModel.email, password: viewModel.password)
            viewModel.isLoading = false

            if supabaseAuth.isSignedIn {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onAccountCreated("email", viewModel.email)
            } else if case .error(let msg) = supabaseAuth.authState {
                viewModel.generalError = msg
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
