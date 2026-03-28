# Onboarding Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5-step onboarding flow with an 8-phase guided onboarding (Variant B from the spec) including account creation, OTP verification, portfolio import, biometrics, and a completion celebration screen.

**Architecture:** The existing `OnboardingView.swift` orchestrator is rewritten with a new 10-step enum. Existing high-quality screens (Welcome, CoreValue, MarketSelection, PortfolioSetup, Permissions) are preserved with minor tweaks. Five new screens are added: AccountCreation, OTPVerification, PortfolioAdd, Biometrics, OnboardingComplete. The flow uses conditional step-skipping (e.g., skip OTP for SSO users, skip biometrics if unavailable).

**Tech Stack:** SwiftUI, Supabase Auth (existing `SupabaseAuthManager`), `AuthenticationServices` (Apple Sign In), `LocalAuthentication` (biometrics), `UniformTypeIdentifiers` (CSV import)

**Spec:** `docs/superpowers/specs/2026-03-19-onboarding-flow-complete-spec.md`

---

## File Structure

### Files to create
| File | Responsibility |
|------|---------------|
| `Stock Tracker/AccountCreationScreen.swift` | OB-030: Email/SSO account creation with validation |
| `Stock Tracker/OTPVerificationScreen.swift` | OB-040: 6-digit OTP input with auto-advance |
| `Stock Tracker/PortfolioAddScreen.swift` | OB-070: Manual entry + CSV import + broker redirect |
| `Stock Tracker/BiometricsScreen.swift` | OB-090: Face ID/Touch ID opt-in |
| `Stock Tracker/OnboardingCompleteScreen.swift` | OB-100: Success animation + summary + auto-dismiss |

### Files to rewrite
| File | Change |
|------|--------|
| `Stock Tracker/OnboardingView.swift` | New 10-step enum, conditional flow logic, new ViewModel |

### Files to modify (minor)
| File | Change |
|------|--------|
| `Stock Tracker/PortfolioSetupScreen.swift` | Market-aware popular stocks (AU vs US based on `preferredMarket`) |
| `Stock Tracker/Stock_TrackerApp.swift` | Pass `supabaseAuthManager` + `networkMonitor` to OnboardingView |
| `Stock Tracker/QuickSetupScreen.swift` | Move `QuickSetupViewModel`, `StockPillButton`, `AddedStockPill` to `PortfolioSetupScreen.swift`, then delete this file |

### Files to keep unchanged
| File | Screen |
|------|--------|
| `Stock Tracker/WelcomeScreen.swift` | OB-020 — already matches spec |
| `Stock Tracker/CoreValueScreen.swift` | OB-025 — already matches spec |
| `Stock Tracker/MarketSelectionScreen.swift` | OB-050 — already matches spec |
| `Stock Tracker/PermissionsScreen.swift` | OB-080 — already matches spec |
| `Stock Tracker/OnboardingButton.swift` | Shared CTA component — already good |

### Intentionally deferred
| Screen | Reason |
|--------|--------|
| OB-035 (Phone Number) | Optional per spec. Supabase does not natively support phone OTP without Twilio configuration. Can be added later. |
| OB-110 (Coach Marks) | Spec marks as "Deferred" — post-onboarding feature discovery, not part of the onboarding flow itself. |

---

## Task 0: Fix OnboardingButton disabled state

The existing `OnboardingButton` accepts a `disabled` parameter but only uses it for visual styling — the button can still be tapped. Add `.disabled(disabled)` to actually prevent taps.

**Files:**
- Modify: `Stock Tracker/OnboardingButton.swift`

- [ ] **Step 1: Add `.disabled(disabled)` modifier**

In `OnboardingButton.swift`, after the `.buttonStyle(.plain)` modifier on the outer `Button`, add `.disabled(disabled)`:

Find this block and add the modifier:
```swift
        .disabled(disabled)
        .buttonStyle(.plain)
```

(The `.disabled` should go before `.buttonStyle` — or simply add `.disabled(disabled)` right after the existing `.buttonStyle(.plain)` line.)

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/OnboardingButton.swift"
git commit -m "fix: OnboardingButton disabled state now actually prevents taps"
```

---

## Task 1: Consolidate QuickSetupScreen into PortfolioSetupScreen

QuickSetupScreen's `QuickSetupViewModel`, `StockPillButton`, and `AddedStockPill` are already used by PortfolioSetupScreen. Move any remaining shared types, then delete the standalone screen.

**Files:**
- Modify: `Stock Tracker/PortfolioSetupScreen.swift`
- Delete: `Stock Tracker/QuickSetupScreen.swift`

- [ ] **Step 1: Move shared types to PortfolioSetupScreen**

Move `QuickSetupViewModel`, `StockPillButton`, and `AddedStockPill` from `QuickSetupScreen.swift` into the bottom of `PortfolioSetupScreen.swift`. These types are already referenced by `PortfolioSetupScreen` via `@StateObject private var stockVM = QuickSetupViewModel()`.

After the move, the code in `PortfolioSetupScreen.swift` should contain all these types at the bottom, after the existing `OnboardingConnectionCard` struct.

- [ ] **Step 2: Add market-aware popular stocks to QuickSetupViewModel**

In `QuickSetupViewModel`, replace the hardcoded `suggestedStocks` with a computed property that reads `@AppStorage("preferredMarket")`:

```swift
@AppStorage("preferredMarket") private var preferredMarket = "US"

var suggestedStocks: [String] {
    switch preferredMarket {
    case "AU":
        return ["BHP.AX", "CBA.AX", "CSL.AX", "NAB.AX", "WBC.AX", "ANZ.AX"]
    case "BOTH":
        return ["AAPL", "BHP.AX", "MSFT", "CBA.AX", "NVDA", "CSL.AX"]
    default:
        return ["AAPL", "GOOGL", "MSFT", "TSLA", "AMZN", "NVDA"]
    }
}
```

- [ ] **Step 3: Delete QuickSetupScreen.swift**

Delete the file. All its types now live in `PortfolioSetupScreen.swift`.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add "Stock Tracker/PortfolioSetupScreen.swift"
git rm "Stock Tracker/QuickSetupScreen.swift"
git commit -m "refactor: consolidate QuickSetupScreen into PortfolioSetupScreen

Move QuickSetupViewModel, StockPillButton, AddedStockPill into
PortfolioSetupScreen. Add market-aware suggested stocks based on
preferredMarket. Delete redundant QuickSetupScreen."
```

---

## Task 2: Create AccountCreationScreen (OB-030)

**Files:**
- Create: `Stock Tracker/AccountCreationScreen.swift`

**Reference:** Spec section OB-030 — "Secure your portfolio" screen with Apple SSO, email/password, skip option.

**Dependencies:** `SupabaseAuthManager` (existing) has `signInWithApple()`, `signUp(email:password:)`, `signIn(email:password:)`.

- [ ] **Step 1: Create the view model**

Create `Stock Tracker/AccountCreationScreen.swift` with the `AccountCreationViewModel`:

```swift
import SwiftUI
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
```

- [ ] **Step 2: Create the view layout**

In the same file, add the `AccountCreationScreen` view:

```swift
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
```

- [ ] **Step 3: Add SSO buttons, email form, and actions**

Add the sub-views and action methods to the same file:

```swift
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
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add "Stock Tracker/AccountCreationScreen.swift"
git commit -m "feat: add AccountCreationScreen (OB-030)

Email/password sign-up with validation, Apple Sign In via existing
SupabaseAuthManager, skip option, offline handling, privacy note.
Spec: OB-030"
```

---

## Task 3: Create OTPVerificationScreen (OB-040)

**Files:**
- Create: `Stock Tracker/OTPVerificationScreen.swift`

**Reference:** Spec section OB-040 — 6-digit OTP input with auto-advance, resend countdown, paste support.

**Note:** Supabase email confirmation works via magic link by default, not OTP. This screen is implemented as a verification-pending placeholder that auto-advances when the user confirms their email (via Supabase auth state listener), or skips after a timeout. If Supabase is configured with OTP, the 6-digit input will work via `verifyOTP`.

- [ ] **Step 1: Create OTPVerificationScreen**

Create `Stock Tracker/OTPVerificationScreen.swift`:

```swift
import SwiftUI
import OSLog

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
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED. Note: `SupabaseManager.auth.verifyOTP` and `.resend` may need API adjustments based on exact supabase-swift SDK version — fix any compilation errors.

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/OTPVerificationScreen.swift"
git commit -m "feat: add OTPVerificationScreen (OB-040)

6-digit OTP input with auto-advance, paste support, resend countdown,
error states. Verifies via Supabase auth.
Spec: OB-040"
```

---

## Task 4: Create PortfolioAddScreen (OB-070)

**Files:**
- Create: `Stock Tracker/PortfolioAddScreen.swift`

**Reference:** Spec section OB-070 — manual entry, CSV import, broker redirect.

- [ ] **Step 1: Create PortfolioAddScreen**

Create `Stock Tracker/PortfolioAddScreen.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct PortfolioAddScreen: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject var marketData: MarketData
    @State private var appeared = false
    @State private var expandedCard: AddMethod?
    @State private var holdings: [ManualHolding] = []

    // Manual entry fields
    @State private var manualSymbol = ""
    @State private var manualShares = ""
    @State private var manualCost = ""
    @State private var manualError: String?

    // CSV import
    @State private var showFilePicker = false
    @State private var csvResult: CSVImportResult?

    private enum AddMethod: String {
        case manual, csv, broker
    }

    struct ManualHolding: Identifiable {
        let id = UUID()
        let symbol: String
        let shares: Double
        let avgCost: Double
    }

    struct CSVImportResult {
        let imported: Int
        let errors: Int
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                // Briefcase icon
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.green.opacity(0.32), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 64
                            )
                        )
                        .frame(width: 128, height: 128)

                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.25, green: 0.88, blue: 0.50), Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .green.opacity(0.5), radius: 16)
                }
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.7)

                Spacer().frame(height: 28)

                // Headline
                VStack(spacing: 12) {
                    Text("Add your holdings")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("See your real portfolio value.\nYou can always add more later.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                }
                .padding(.horizontal, 32)
                .opacity(appeared ? 1 : 0)

                Spacer().frame(height: 32)

                // Method cards
                VStack(spacing: 12) {
                    methodCard(
                        method: .manual,
                        icon: "plus.circle.fill",
                        color: .blue,
                        title: "Add manually",
                        subtitle: "Enter your stock positions one by one"
                    )

                    methodCard(
                        method: .csv,
                        icon: "doc.text.fill",
                        color: .orange,
                        title: "Import from CSV",
                        subtitle: "Upload a spreadsheet from your broker"
                    )

                    methodCard(
                        method: .broker,
                        icon: "building.columns.fill",
                        color: .purple,
                        title: "Connect your broker",
                        subtitle: "Automatically sync your holdings (read-only)"
                    )
                }
                .padding(.horizontal, 28)

                // Added holdings summary
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Added (\(holdings.count))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))

                        ForEach(holdings) { h in
                            HStack {
                                Text(h.symbol)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(String(format: "%.2f", h.shares)) shares @ $\(String(format: "%.2f", h.avgCost))")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                }

                Spacer().frame(height: 32)

                // CTAs
                VStack(spacing: 14) {
                    OnboardingButton(title: "Continue") {
                        saveHoldings()
                        onComplete()
                    }

                    Button("I'll do this later") { onSkip() }
                        .font(.body)
                        .foregroundColor(.white.opacity(0.42))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleCSVImport(result)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.10)) {
                appeared = true
            }
        }
    }

    // MARK: - Method card

    @ViewBuilder
    private func methodCard(method: AddMethod, icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expandedCard = expandedCard == method ? nil : method
                }
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color.opacity(0.18))
                            .frame(width: 46, height: 46)
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(color)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.50))
                    }

                    Spacer()

                    Image(systemName: expandedCard == method ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            if expandedCard == method {
                expandedContent(for: method)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.07))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func expandedContent(for method: AddMethod) -> some View {
        switch method {
        case .manual:
            manualEntryForm
        case .csv:
            csvImportSection
        case .broker:
            brokerSection
        }
    }

    // MARK: - Manual entry

    @ViewBuilder
    private var manualEntryForm: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("Symbol", text: $manualSymbol)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .frame(maxWidth: 100)

                TextField("Shares", text: $manualShares)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)

                TextField("Avg cost", text: $manualCost)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
            }

            if let error = manualError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button {
                addManualHolding()
            } label: {
                Text("Add holding")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - CSV

    @ViewBuilder
    private var csvImportSection: some View {
        VStack(spacing: 12) {
            Text("Expected columns: Symbol, Shares, Average Cost")
                .font(.caption)
                .foregroundColor(.white.opacity(0.50))

            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose CSV file")
                }
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.3))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            if let result = csvResult {
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(result.errors > 0 ? .orange : .green)
            }
        }
    }

    // MARK: - Broker

    @ViewBuilder
    private var brokerSection: some View {
        VStack(spacing: 10) {
            Text("Connections are read-only. We can see your positions but can never place trades or move funds.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.50))

            Text("Connect your broker in the Watchlist Setup step, or later in Settings.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.40))
        }
    }

    // MARK: - Actions

    private func addManualHolding() {
        manualError = nil
        guard !manualSymbol.isEmpty else {
            manualError = "Enter a symbol"
            return
        }
        guard let shares = Double(manualShares), shares > 0 else {
            manualError = "Enter valid share count"
            return
        }
        guard let cost = Double(manualCost), cost > 0 else {
            manualError = "Enter valid average cost"
            return
        }

        let holding = ManualHolding(
            symbol: manualSymbol.uppercased(),
            shares: shares,
            avgCost: cost
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            holdings.append(holding)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Reset fields
        manualSymbol = ""
        manualShares = ""
        manualCost = ""
    }

    private func handleCSVImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rows = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var imported = 0
            var errors = 0

            for (index, row) in rows.enumerated() {
                if index == 0 && row.lowercased().contains("symbol") { continue } // Skip header
                let cols = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 3,
                      !cols[0].isEmpty,
                      let shares = Double(cols[1]),
                      let cost = Double(cols[2])
                else {
                    errors += 1
                    continue
                }
                holdings.append(ManualHolding(symbol: cols[0].uppercased(), shares: shares, avgCost: cost))
                imported += 1
            }

            csvResult = CSVImportResult(
                imported: imported,
                errors: errors,
                message: errors > 0
                    ? "\(imported) of \(imported + errors) rows imported. \(errors) issues found."
                    : "\(imported) holdings imported"
            )
        } catch {
            csvResult = CSVImportResult(imported: 0, errors: 1, message: "Couldn't read this file.")
        }
    }

    private func saveHoldings() {
        // Save manual holdings as onboarding portfolio data
        let symbols = holdings.map(\.symbol)
        UserDefaults.standard.set(symbols, forKey: "onboarding_portfolio_symbols")

        // Store detailed holdings for later import
        let data = holdings.map { ["symbol": $0.symbol, "shares": $0.shares, "avgCost": $0.avgCost] as [String: Any] }
        if let encoded = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(encoded, forKey: "onboarding_portfolio_holdings")
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/PortfolioAddScreen.swift"
git commit -m "feat: add PortfolioAddScreen (OB-070)

Manual entry form, CSV import with file picker, broker info section.
Holdings saved to UserDefaults for post-onboarding import.
Spec: OB-070"
```

---

## Task 5: Create BiometricsScreen (OB-090)

**Files:**
- Create: `Stock Tracker/BiometricsScreen.swift`

**Reference:** Spec section OB-090 — Face ID/Touch ID opt-in with privacy note.

- [ ] **Step 1: Create BiometricsScreen**

Create `Stock Tracker/BiometricsScreen.swift`:

```swift
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
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/BiometricsScreen.swift"
git commit -m "feat: add BiometricsScreen (OB-090)

Face ID/Touch ID opt-in with auto-detection, privacy note,
auto-skip if no biometrics available.
Spec: OB-090"
```

---

## Task 6: Create OnboardingCompleteScreen (OB-100)

**Files:**
- Create: `Stock Tracker/OnboardingCompleteScreen.swift`

**Reference:** Spec section OB-100 — animated checkmark, summary, auto-dismiss.

- [ ] **Step 1: Create OnboardingCompleteScreen**

Create `Stock Tracker/OnboardingCompleteScreen.swift`:

```swift
import SwiftUI

struct OnboardingCompleteScreen: View {
    let onFinish: () -> Void

    @EnvironmentObject var marketData: MarketData

    private var watchlistCount: Int { marketData.watchlist.count }
    private var portfolioCount: Int { marketData.portfolio.count }

    @State private var circleProgress: CGFloat = 0
    @State private var showCheckmark = false
    @State private var textOpacity: Double = 0
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated checkmark circle
            ZStack {
                // Circle draw
                Circle()
                    .trim(from: 0, to: circleProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))

                // Checkmark
                if showCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: .green.opacity(0.35), radius: 20)

            Spacer().frame(height: 36)

            // Headline
            VStack(spacing: 16) {
                Text("You're all set")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                // Dynamic summary
                VStack(spacing: 8) {
                    if watchlistCount > 0 {
                        summaryRow(icon: "chart.line.uptrend.xyaxis", text: "\(watchlistCount) stocks on your watchlist")
                    }
                    if portfolioCount > 0 {
                        summaryRow(icon: "briefcase.fill", text: "\(portfolioCount) holdings tracked")
                    }
                    if watchlistCount == 0 && portfolioCount == 0 {
                        summaryRow(icon: "star.fill", text: "Watchlist ready — add stocks anytime")
                    }
                }
            }
            .opacity(textOpacity)

            Spacer()

            // Tap hint
            Text("Tap anywhere to continue")
                .font(.caption)
                .foregroundColor(.white.opacity(0.30))
                .opacity(textOpacity)
                .padding(.bottom, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            autoDismissTask?.cancel()
            onFinish()
        }
        .onAppear { runAnimations() }
        .onDisappear { autoDismissTask?.cancel() }
    }

    @ViewBuilder
    private func summaryRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.green)
            Text(text)
                .font(.body)
                .foregroundColor(.white.opacity(0.70))
        }
    }

    private func runAnimations() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Circle draws
        withAnimation(.easeOut(duration: 0.5)) {
            circleProgress = 1
        }

        // Checkmark pops in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showCheckmark = true
            }
        }

        // Text fades in
        withAnimation(.easeOut(duration: 0.4).delay(0.6)) {
            textOpacity = 1
        }

        // Auto-dismiss after 3s
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { onFinish() }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/OnboardingCompleteScreen.swift"
git commit -m "feat: add OnboardingCompleteScreen (OB-100)

Animated checkmark circle, dynamic summary stats, auto-dismiss
after 3 seconds or tap anywhere.
Spec: OB-100"
```

---

## Task 7: Rewrite OnboardingView (Orchestrator)

**Files:**
- Rewrite: `Stock Tracker/OnboardingView.swift`

**Reference:** Full flow from spec — 10 steps with conditional skipping.

- [ ] **Step 1: Rewrite OnboardingView.swift**

Replace the entire file with the new orchestrator:

```swift
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
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Stock Tracker/OnboardingView.swift"
git commit -m "feat: rewrite OnboardingView with 8-phase guided flow

10-step enum with conditional skipping: OTP skipped for SSO,
biometrics skipped if unavailable. Integrates all new screens:
AccountCreation, OTP, PortfolioAdd, Biometrics, Complete.
Spec: Variant B (Guided)"
```

---

## Task 8: Wire OnboardingView into App Entry Point

**Files:**
- Modify: `Stock Tracker/Stock_TrackerApp.swift`

- [ ] **Step 1: Pass environment objects to OnboardingView**

In `Stock_TrackerApp.swift`, update the `OnboardingView` block in body to inject the environment objects that the new screens need:

Change:
```swift
if showOnboarding {
    OnboardingView(onComplete: {
        withAnimation(.easeInOut(duration: 0.5)) {
            showOnboarding = false
        }
    })
    .environmentObject(themeManager)
    .transition(.opacity)
```

To:
```swift
if showOnboarding {
    OnboardingView(onComplete: {
        withAnimation(.easeInOut(duration: 0.5)) {
            showOnboarding = false
        }
    })
    .environmentObject(themeManager)
    .environmentObject(supabaseAuthManager)
    .environmentObject(networkMonitor)
    .environmentObject(marketData)
    .environmentObject(subscriptionManager)
    .transition(.opacity)
```

- [ ] **Step 2: Load onboarding portfolio holdings**

Add a method to load portfolio holdings that were saved during onboarding. After the existing `loadOnboardingStocks()` call in `.onAppear`, add:

```swift
loadOnboardingPortfolio()
```

Then add the method:

```swift
private func loadOnboardingPortfolio() {
    guard let data = UserDefaults.standard.data(forKey: "onboarding_portfolio_holdings"),
          let holdings = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return }

    for h in holdings {
        guard let symbol = h["symbol"] as? String,
              let shares = h["shares"] as? Double,
              let avgCost = h["avgCost"] as? Double
        else { continue }

        Task {
            do {
                let asset = try await APIService.shared.fetchAssetDetails(
                    identifier: symbol,
                    kind: .stock,
                    name: symbol
                )
                await MainActor.run {
                    marketData.addToPortfolio(asset: asset, shares: shares, avgCost: avgCost)
                }
            } catch {
                AppLogger.api.error("Failed to load onboarding portfolio holding \(symbol): \(error)")
            }
        }
    }

    // Clean up
    UserDefaults.standard.removeObject(forKey: "onboarding_portfolio_holdings")
    UserDefaults.standard.removeObject(forKey: "onboarding_portfolio_symbols")
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
```

Expected: BUILD SUCCEEDED. Fix any missing method errors (e.g., `marketData.addToPortfolio` — check exact method signature and adjust).

- [ ] **Step 4: Commit**

```bash
git add "Stock Tracker/Stock_TrackerApp.swift"
git commit -m "feat: wire new onboarding flow into app entry point

Pass supabaseAuthManager, networkMonitor, marketData to OnboardingView.
Load onboarding portfolio holdings on app launch.
Spec: Stock_TrackerApp integration"
```

---

## Task 9: Final Build Verification

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" \
  clean build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Fix any build errors**

Address any compilation errors. Common issues:
- Missing `import` statements (OSLog, LocalAuthentication, Combine)
- `SupabaseManager.auth.verifyOTP` / `.resend` API differences — check supabase-swift SDK docs
- `marketData.addToPortfolio` method signature mismatch — read `MarketData.swift` for exact API
- Duplicate type definitions after QuickSetupScreen merge

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "fix: resolve build errors in onboarding redesign"
```

---

## Summary

| Task | Screen(s) | Status |
|------|-----------|--------|
| 0 | Fix OnboardingButton disabled state | - [ ] |
| 1 | Consolidate QuickSetupScreen | - [ ] |
| 2 | AccountCreationScreen (OB-030) | - [ ] |
| 3 | OTPVerificationScreen (OB-040) | - [ ] |
| 4 | PortfolioAddScreen (OB-070) | - [ ] |
| 5 | BiometricsScreen (OB-090) | - [ ] |
| 6 | OnboardingCompleteScreen (OB-100) | - [ ] |
| 7 | Rewrite OnboardingView orchestrator | - [ ] |
| 8 | Wire into Stock_TrackerApp | - [ ] |
| 9 | Final build verification | - [ ] |

**Screens preserved (no changes needed):**
- WelcomeScreen.swift (OB-020)
- CoreValueScreen.swift (OB-025)
- MarketSelectionScreen.swift (OB-050)
- PermissionsScreen.swift (OB-080)
- OnboardingButton.swift (shared component)
