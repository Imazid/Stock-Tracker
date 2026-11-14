//
//  OnboardingSetupSteps.swift
//  Stock Tracker
//
//  Portfolio → Alerts → Security → Account → Done, plus the returning-user sign-in sheet.
//

import SwiftUI
import UserNotifications
import LocalAuthentication
import Supabase

// MARK: - Portfolio

struct OnboardingPortfolioStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager

    @State private var sheet: Source?
    @State private var openBrokerAfterSignIn = false

    /// CSV import is a Black-plan feature everywhere else in the app.
    private var offersCSV: Bool { subscriptionManager.currentTier == .black }

    enum Source: String, Identifiable {
        case broker, csv, manual, account, demo
        var id: String { rawValue }
    }

    private var holdings: [PortfolioHolding] { marketData.portfolio }

    var body: some View {
        OnboardingPage(
            title: "Add what you already own",
            subtitle: "Explore with sample holdings or bring your investments together. Brokerage connections here are read-only."
        ) {
            VStack(spacing: DS.Space.m) {
                OnboardingChoiceRow(
                    title: "Explore a demo portfolio",
                    subtitle: "Sample holdings with market prices",
                    showsCheck: false,
                    trailingChevron: true
                ) {
                    Image(systemName: "graduationcap").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                } action: {
                    Haptics.tap()
                    sheet = .demo
                }
                .accessibilityIdentifier("onboarding.portfolio.demo")

                OnboardingChoiceRow(
                    title: "Connect a broker",
                    subtitle: "Review holdings and balances from a linked account",
                    showsCheck: false,
                    trailingChevron: true
                ) {
                    Image(systemName: "link").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                } action: {
                    Haptics.tap()
                    sheet = needsBrokerSignIn ? .account : .broker
                }
                .accessibilityIdentifier("onboarding.portfolio.broker")

                if offersCSV {
                OnboardingChoiceRow(
                    title: "Import a spreadsheet",
                    subtitle: "Upload a CSV export from any broker",
                    showsCheck: false,
                    trailingChevron: true
                ) {
                    Image(systemName: "tablecells").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                } action: {
                    Haptics.tap(); sheet = .csv
                }
                .accessibilityIdentifier("onboarding.portfolio.csv")
                }

                OnboardingChoiceRow(
                    title: "Enter holdings yourself",
                    subtitle: "A ticker, how many you own and what you paid",
                    showsCheck: false,
                    trailingChevron: true
                ) {
                    Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                } action: {
                    Haptics.tap(); sheet = .manual
                }
                .accessibilityIdentifier("onboarding.portfolio.manual")
            }

            if !holdings.isEmpty {
                AddedHoldingsCard(holdings: holdings)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        } footer: {
            if holdings.isEmpty {
                Button("Skip for now") { Haptics.tap(); viewModel.next() }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
            } else {
                Button("Continue") { Haptics.tap(); viewModel.next() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .motionSafeAnimation(DS.spring, value: holdings.count)
        .sheet(item: $sheet, onDismiss: {
            if openBrokerAfterSignIn {
                openBrokerAfterSignIn = false
                if supabaseAuth.isSignedIn { sheet = .broker }
            }
        }) { source in
            Group {
                switch source {
                case .broker: SnapTradeConnectionView()
                case .csv:    CSVImportSheet()
                case .manual: ManualPositionSheet()
                case .demo: OnboardingDemoPortfolio()
                case .account:
                    OnboardingSignInSheet(defaultMode: .signUp, forBroker: true) {
                        openBrokerAfterSignIn = true
                        sheet = nil
                    }
                    .presentationDetents([.large])
                }
            }
            .environmentObject(marketData)
        }
    }

    private var needsBrokerSignIn: Bool {
        #if DEBUG
        if SnapTradeViewModel.usesFixture { return false }
        #endif
        return SecureBackend.shouldUseServer && !supabaseAuth.isSignedIn
    }
}

private struct AddedHoldingsCard: View {
    let holdings: [PortfolioHolding]

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(holdings.count == 1 ? "1 holding added" : "\(holdings.count) holdings added")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(holdings.prefix(4).map(\.asset.symbol).joined(separator: ", ") + (holdings.count > 4 ? "…" : ""))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(DS.Space.l)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.accent.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Alerts (notification pre-prompt)

struct OnboardingAlertsStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @State private var isRequesting = false
    @State private var alreadyDecided: UNAuthorizationStatus?

    private var exampleSymbol: PickedAsset {
        viewModel.picks.first ?? OnboardingCatalog.us[1]
    }

    var body: some View {
        OnboardingPage(
            title: "Know when it moves",
            subtitle: "A nudge for big moves and the price targets you set — nothing else. Fine-tune it any time in Settings."
        ) {
            VStack(spacing: -18) {
                NotificationPreview(
                    logo: exampleSymbol,
                    title: "\(exampleSymbol.symbol) is up 4.2% today",
                    detail: "Your biggest mover so far this session."
                )
                .zIndex(2)
                NotificationPreview(
                    logo: nil,
                    title: "Price alert hit",
                    detail: "\(viewModel.picks.dropFirst().first?.symbol ?? "AAPL") crossed the target you set."
                )
                .scaleEffect(0.94)
                .opacity(0.7)
                .zIndex(1)
            }
            .padding(.top, DS.Space.l)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example notifications")

            Text("Examples")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
        } footer: {
            if alreadyDecided == .authorized || viewModel.notificationsEnabled == true {
                Label("Notifications are on", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 32)
                Button("Continue") { Haptics.tap(); viewModel.next() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
            } else {
                Button {
                    Haptics.tap()
                    isRequesting = true
                    Task {
                        await viewModel.requestNotifications()
                        isRequesting = false
                        viewModel.next()
                    }
                } label: {
                    if isRequesting { ProgressView().tint(.black) } else { Text("Turn on notifications") }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(isRequesting)
                .accessibilityIdentifier("onboarding.notifications.allow")

                Button("Not now") {
                    viewModel.notificationsEnabled = false
                    viewModel.next()
                }
                .buttonStyle(QuietTextButtonStyle(onDark: true))
                .accessibilityIdentifier("onboarding.notifications.notNow")
            }
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            alreadyDecided = settings.authorizationStatus
            if settings.authorizationStatus == .authorized { viewModel.notificationsEnabled = true }
        }
    }
}

/// An iOS-style notification banner used as an honest preview of what we'll send.
private struct NotificationPreview: View {
    let logo: PickedAsset?
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.black)
                    )
                if let logo {
                    TickerLogo(symbol: logo.symbol, kind: logo.kind, exchange: logo.exchange, size: 18)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5))
                        .offset(x: 5, y: 5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Stock Tracker").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("now").font(.footnote).foregroundStyle(.white.opacity(0.5))
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
        .padding(DS.Space.m + 2)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Security (Face ID / Touch ID)

struct OnboardingSecurityStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @State private var failed = false

    private var symbol: String { viewModel.biometryType == .touchID ? "touchid" : "faceid" }

    var body: some View {
        OnboardingPage(
            title: "Keep your portfolio private",
            subtitle: "Require \(viewModel.biometryName) when you open Stock Tracker, so only you see your balances."
        ) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 132, height: 132)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(DS.accent.opacity(0.5), lineWidth: 1))
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Space.xl)
                .accessibilityHidden(true)

            if failed {
                InlineNote(icon: "exclamationmark.circle", text: "That didn't go through. You can turn it on later in Settings → Security.")
            }
        } footer: {
            Button("Use \(viewModel.biometryName)") {
                Haptics.tap()
                Task {
                    if await viewModel.enableBiometrics() {
                        viewModel.next()
                    } else {
                        Haptics.warning()
                        failed = true
                    }
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityIdentifier("onboarding.biometrics.enable")

            Button("Not now") {
                viewModel.biometricsEnabled = false
                viewModel.next()
            }
            .buttonStyle(QuietTextButtonStyle(onDark: true))
        }
    }
}

// MARK: - Account (last, optional)

struct OnboardingAccountStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager
    @ObservedObject private var accountService = AccountService.shared

    @State private var showEmail = false
    @State private var referral = ReferralField.State()

    var body: some View {
        OnboardingPage(
            title: "Save your setup",
            subtitle: "A free account backs up your watchlist and portfolio and keeps them in sync on all your devices."
        ) {
            if accountService.isUnavailable {
                AccountUnavailableNote()
            } else {
                signInOptions
                ReferralField(state: $referral)
            }

            Label("We never sell your data, and nothing here can trade or move money.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        } footer: {
            Button(accountService.isUnavailable ? "Continue without an account" : "Not now — keep it on this iPhone") {
                referral.saveIfNeeded()
                viewModel.next()
            }
            .buttonStyle(QuietTextButtonStyle(onDark: true))
            .accessibilityIdentifier("onboarding.account.skip")
        }
        .task { await accountService.check() }
    }

    private var signInOptions: some View {
        VStack(spacing: DS.Space.m) {
            AppleSignInButton {
                referral.saveIfNeeded()
                await supabaseAuth.signInWithApple()
                if supabaseAuth.authState == .signedIn {
                    viewModel.accountLabel = supabaseAuth.cloudUser?.email ?? "Apple ID"
                    viewModel.next()
                }
            }

            if showEmail {
                EmailAuthForm(defaultMode: .signUp) { email in
                    referral.saveIfNeeded()
                    viewModel.accountLabel = email
                    viewModel.next()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button("Continue with email") {
                    Haptics.tap()
                    dsAnimate { showEmail = true }
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityIdentifier("onboarding.account.email")
            }

            if case .error(let message) = supabaseAuth.authState, !showEmail {
                InlineNote(icon: "exclamationmark.circle", text: LocalizedStringKey(friendlyAuthError(message)))
            }
        }
    }
}

/// "Accounts are unavailable right now" for the dark onboarding screens, with Retry.
struct AccountUnavailableNote: View {
    @ObservedObject private var accountService = AccountService.shared

    var body: some View {
        let offline = accountService.status == .offline
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: offline ? "wifi.slash" : "icloud.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(offline ? "You're offline" : "Accounts are unavailable right now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(offline
                         ? "Connect to the internet to create an account. You can carry on without one."
                         : "We can't reach Stock Tracker's account service. Carry on without an account — everything stays on this iPhone, and you can sign in later from Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Haptics.tap()
                Task { await accountService.check(force: true) }
            } label: {
                HStack(spacing: 6) {
                    if accountService.status == .checking {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Try again")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(accountService.status == .checking)
            .accessibilityIdentifier("account.retry")
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.unavailable")
    }
}

/// White pill "Continue with Apple" that matches the rest of the flow.
struct AppleSignInButton: View {
    let action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            Haptics.tap()
            busy = true
            Task {
                await action()
                busy = false
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                if busy {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "apple.logo").font(.system(size: 18, weight: .semibold))
                    Text("Continue with Apple")
                }
            }
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .disabled(busy)
        .accessibilityIdentifier("onboarding.account.apple")
    }
}

// MARK: - Email auth (sign up / sign in, with code confirmation)

struct EmailAuthForm: View {
    enum Mode { case signUp, signIn }

    let defaultMode: Mode
    let onDone: (String) -> Void

    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager
    @State private var mode: Mode = .signUp
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var awaitingCode = false
    @State private var resetSent = false
    @FocusState private var focus: Field?

    enum Field { case email, password }

    init(defaultMode: Mode, onDone: @escaping (String) -> Void) {
        self.defaultMode = defaultMode
        self.onDone = onDone
        _mode = State(initialValue: defaultMode)
    }

    private var emailValid: Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
    private var canSubmit: Bool { emailValid && password.count >= 8 && !busy }

    private var passwordContentType: UITextContentType {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestTypeOwnPassword") { return .password }
        #endif
        return mode == .signUp ? .newPassword : .password
    }

    var body: some View {
        if awaitingCode {
            CodeEntryView(email: email) { onDone(email) }
        } else {
            VStack(spacing: DS.Space.m) {
                DarkField(icon: "envelope", placeholder: "Email address", isEmpty: email.isEmpty) {
                    TextField("", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("auth.email")
                }
                DarkField(icon: "lock", placeholder: mode == .signUp ? "Password (8+ characters)" : "Password", isEmpty: password.isEmpty) {
                    SecureField("", text: $password)
                        .textContentType(passwordContentType)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit { if canSubmit { submit() } }
                        .accessibilityIdentifier("auth.password")
                }

                if let error {
                    InlineNote(icon: "exclamationmark.circle", text: LocalizedStringKey(error))
                }
                if resetSent {
                    InlineNote(icon: "envelope.badge", text: "Check your inbox for a link to reset your password.")
                }

                Button {
                    submit()
                } label: {
                    if busy { ProgressView().tint(.black) } else { Text(mode == .signUp ? "Create account" : "Sign in") }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(!canSubmit)
                .accessibilityIdentifier("auth.submit")

                HStack {
                    Button(mode == .signUp ? "I already have an account" : "New here? Create an account") {
                        dsAnimate(DS.quick) {
                            mode = mode == .signUp ? .signIn : .signUp
                            error = nil
                        }
                    }
                    Spacer()
                    if mode == .signIn {
                        Button("Forgot password?") { sendReset() }
                            .disabled(!emailValid)
                    }
                }
                .buttonStyle(QuietTextButtonStyle(onDark: true))
                .font(.footnote)
            }
            .onAppear { focus = .email }
        }
    }

    private func submit() {
        guard canSubmit else { Haptics.warning(); return }
        focus = nil
        busy = true
        error = nil
        Task {
            switch mode {
            case .signUp: await supabaseAuth.signUp(email: email, password: password)
            case .signIn: await supabaseAuth.signIn(email: email, password: password)
            }
            busy = false
            switch supabaseAuth.authState {
            case .signedIn:
                Haptics.success()
                onDone(email)
            case .error(let message):
                // Sign-up succeeded but the project requires email confirmation.
                if mode == .signUp, supabaseAuth.cloudUser != nil {
                    dsAnimate { awaitingCode = true }
                } else {
                    Haptics.warning()
                    error = friendly(message)
                }
            default:
                Haptics.warning()
                error = "Something went wrong. Please try again."
            }
        }
    }

    private func sendReset() {
        Task {
            do {
                try await supabaseAuth.sendPasswordReset(email: email)
                resetSent = true
            } catch {
                self.error = "We couldn't send a reset link. Check the email address and try again."
            }
        }
    }

    private func friendly(_ message: String) -> String { friendlyAuthError(message) }
}

/// Turns Supabase / URLSession errors into something a person can act on.
func friendlyAuthError(_ message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("invalid login") { return "That email and password don't match. Try again or reset your password." }
    if lower.contains("already registered") { return "That email already has an account — sign in instead." }
    if lower.contains("not configured") { return "Accounts aren't available in this build. You can continue without one." }
    if lower.contains("offline") || lower.contains("not connected to the internet") {
        return "You're offline. Connect to the internet and try again."
    }
    if lower.contains("hostname") || lower.contains("could not be found") || lower.contains("cannot find host")
        || lower.contains("timed out") || lower.contains("server") {
        return "Accounts are temporarily unavailable. Continue without one — you can sign in later from Settings."
    }
    if lower.contains("cancel") { return "Sign-in was cancelled." }
    return message
}

/// 6-digit email code entry (Supabase email OTP), with paste/autofill support.
private struct CodeEntryView: View {
    let email: String
    let onVerified: () -> Void

    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resendIn = 30
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Enter the 6-digit code we sent to \(email)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))

            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
                    .accessibilityLabel("Verification code")
                    .accessibilityIdentifier("auth.code")
                    .onChange(of: code) { _, new in
                        code = String(new.filter(\.isNumber).prefix(6))
                        if code.count == 6 { verify() }
                    }
                HStack(spacing: DS.Space.s) {
                    ForEach(0..<6, id: \.self) { i in
                        let digit = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                        Text(digit)
                            .font(DS.money(24))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(i == code.count && focused ? DS.accent : Color.clear, lineWidth: 1.5)
                            )
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onTapGesture { focused = true }

            if let error { InlineNote(icon: "exclamationmark.circle", text: LocalizedStringKey(error)) }

            HStack {
                if busy { ProgressView().tint(.white) }
                Spacer()
                Button(resendIn > 0 ? "Resend code in \(resendIn)s" : "Resend code") { resend() }
                    .buttonStyle(QuietTextButtonStyle(onDark: true))
                    .disabled(resendIn > 0)
            }
        }
        .onAppear { focused = true }
        .task(id: resendIn) {
            guard resendIn > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            resendIn -= 1
        }
    }

    private func verify() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await SupabaseManager.auth.verifyOTP(email: email, token: code, type: .email)
                Haptics.success()
                onVerified()
            } catch {
                Haptics.warning()
                self.error = "That code doesn't match. Check your email and try again."
                code = ""
            }
            busy = false
        }
    }

    private func resend() {
        resendIn = 30
        Task { try? await SupabaseManager.auth.resend(email: email, type: .signup) }
    }
}

/// Dark input row with a leading icon and a visible placeholder.
private struct DarkField<Field: View>: View {
    let icon: String
    let placeholder: LocalizedStringKey
    let isEmpty: Bool
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 20)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.white.opacity(0.35))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                field
                    .foregroundStyle(.white)
                    .tint(DS.accent)
                    .accessibilityLabel(placeholder)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Referral code (ported from the account screen WIP)

struct ReferralField: View {
    struct State {
        var isOpen = false
        var code = ""
        var status: String?
        var valid: Bool?

        /// Stored as it's typed and consumed by ReferralManager right after sign-in.
        /// (Saving only after email sign-up raced the consume that sign-in triggers.)
        func saveIfNeeded() {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                DataPersistenceManager.shared.clearPendingReferralCode()
            } else {
                DataPersistenceManager.shared.savePendingReferralCode(trimmed)
            }
        }
    }

    @Binding var state: State

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if state.isOpen {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "gift").foregroundStyle(.white.opacity(0.45))
                    TextField("", text: $state.code, prompt: Text("Referral code").foregroundStyle(.white.opacity(0.35)))
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(validate)
                        .onChange(of: state.code) { _, _ in
                            state.status = nil
                            state.valid = nil
                            state.saveIfNeeded()
                        }
                        .accessibilityIdentifier("onboarding.referral.code")
                    if let valid = state.valid {
                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(valid ? DS.accent : Color.orange)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))

                if let status = state.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(state.valid == true ? DS.accent
                                         : state.valid == false ? Color.orange : Color.white.opacity(0.64))
                        .accessibilityIdentifier("onboarding.referral.status")
                }
            } else {
                Button("Have a referral code?") {
                    dsAnimate { state.isOpen = true }
                }
                .buttonStyle(QuietTextButtonStyle(onDark: true))
                .accessibilityIdentifier("onboarding.referral.open")
                .padding(.leading, -DS.Space.m)
            }
        }
        .onAppear {
            if let pending = DataPersistenceManager.shared.loadPendingReferralCode(), !pending.isEmpty {
                state.code = pending
                state.isOpen = true
            }
        }
    }

    private func validate() {
        let code = state.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        state.saveIfNeeded()
        // Codes are checked on the server as the new account, so before sign-up there's
        // nothing to check yet — say what will happen instead of a red "Sign in" error.
        guard SupabaseManager.auth.currentUser != nil else {
            state.valid = nil
            state.status = "We'll apply this code when you create your account."
            return
        }
        Task {
            switch await ReferralManager.shared.validate(code) {
            case .valid:
                state.valid = true
                state.status = "Code applied — your reward unlocks after sign-up."
            case .invalid(let reason):
                state.valid = false
                state.status = reason
            }
        }
    }
}

// MARK: - Returning-user sign in

struct OnboardingSignInSheet: View {
    var defaultMode: EmailAuthForm.Mode = .signIn
    var forBroker = false
    let onSignedIn: () -> Void
    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager
    @ObservedObject private var accountService = AccountService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var referral = ReferralField.State()

    var body: some View {
        ZStack {
            OnboardingBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .accessibilityLabel("Close")
                    }

                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text(defaultMode == .signUp ? "Create your Stock Tracker account" : "Welcome back")
                            .font(DS.display(.largeTitle))
                            .foregroundStyle(.white)
                        Text(forBroker
                             ? "Create an account or sign in to connect a brokerage and sync your holdings."
                             : defaultMode == .signUp
                             ? "Save your watchlist, portfolio and alerts across devices."
                             : "Sign in and your watchlist, portfolio and alerts come with you.")
                            .foregroundStyle(.white.opacity(0.64))
                    }

                    if accountService.isUnavailable {
                        AccountUnavailableNote()
                        Button("Continue without an account") { dismiss() }
                            .buttonStyle(SecondaryPillButtonStyle())
                            .accessibilityIdentifier("account.continueWithout")
                    } else {
                        AppleSignInButton {
                            if defaultMode == .signUp { referral.saveIfNeeded() }
                            await supabaseAuth.signInWithApple()
                            if supabaseAuth.authState == .signedIn { onSignedIn() }
                        }

                        HStack {
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                            Text("or").font(.footnote).foregroundStyle(.white.opacity(0.45))
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        }

                        EmailAuthForm(defaultMode: defaultMode) { _ in onSignedIn() }
                        if defaultMode == .signUp { ReferralField(state: $referral) }
                    }
                }
                .padding(DS.Space.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .task { await accountService.check() }
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var supabaseAuth: SupabaseAuthManager
    @Environment(\.onboardingFinish) private var finish
    @State private var appeared = false

    /// Already signed in (e.g. a saved session after reinstalling) skips the account
    /// step, so there's no label from it — it still backs up, so don't say "This iPhone only".
    private var backupLabel: String {
        if let label = viewModel.accountLabel { return label }
        if supabaseAuth.isSignedIn { return supabaseAuth.cloudUser?.email ?? "Signed in" }
        return "This iPhone only"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Spacer(minLength: DS.Space.xl)

            CelebrationCheck(trigger: appeared, size: 64, foreground: .black, background: .white)

            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("You're all set")
                    .font(DS.display(.largeTitle))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Here's what we set up. Everything can be changed later.")
                    .foregroundStyle(.white.opacity(0.64))
            }

            VStack(spacing: 0) {
                OnboardingSummaryRow(icon: "star", title: "Watchlist",
                           value: viewModel.picks.isEmpty ? "Add from Search any time" : "\(viewModel.picks.count) to follow") {
                    if !viewModel.picks.isEmpty {
                        HStack(spacing: -8) {
                            ForEach(viewModel.picks.prefix(4)) { pick in
                                TickerLogo(symbol: pick.symbol, kind: pick.kind, exchange: pick.exchange, size: 24)
                                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                            }
                        }
                    }
                }
                .staggeredAppear(1)
                OnboardingSummaryRow(icon: "briefcase", title: "Portfolio",
                           value: marketData.portfolio.isEmpty ? "Not added yet" : "\(marketData.portfolio.count) holdings") { EmptyView() }
                    .staggeredAppear(2)
                OnboardingSummaryRow(icon: "bell", title: "Alerts",
                           value: viewModel.notificationsEnabled == true ? "On" : "Off") { EmptyView() }
                    .staggeredAppear(3)
                if viewModel.biometricsAvailable {
                    OnboardingSummaryRow(icon: viewModel.biometryType == .touchID ? "touchid" : "faceid", title: LocalizedStringKey(viewModel.biometryName),
                               value: viewModel.biometricsEnabled == true ? "On" : "Off") { EmptyView() }
                        .staggeredAppear(4)
                }
                OnboardingSummaryRow(icon: "icloud", title: "Backup & sync",
                           value: backupLabel, showsDivider: false) { EmptyView() }
                    .staggeredAppear(5)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.white.opacity(0.05)))

            Spacer()

            Button("Go to my dashboard") { finish() }
                .buttonStyle(PrimaryPillButtonStyle())
                .accessibilityIdentifier("onboarding.finish")
                .padding(.bottom, DS.Space.s)
        }
        .padding(.horizontal, DS.Space.gutter)
        // Bursts from the check badge.
        .overlay { ConfettiBurst(trigger: appeared ? 1 : 0, origin: UnitPoint(x: 0.14, y: 0.3)).ignoresSafeArea() }
        .onAppear {
            Haptics.success()
            appeared = true
        }
    }
}

private struct OnboardingSummaryRow<Accessory: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28)
                Text(title).font(.body).foregroundStyle(.white)
                Spacer()
                accessory
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(minHeight: 52)
            if showsDivider {
                Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 56)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
