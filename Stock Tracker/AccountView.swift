//
//  AccountView.swift
//  Stock Tracker
//
//  Cloud account management sheet — sign in with Apple or email/password,
//  view sync status, manage MFA, and sign out.
//

import SwiftUI
import AuthenticationServices

struct AccountView: View {
    @EnvironmentObject var supabaseAuthManager: SupabaseAuthManager
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var mfaManager: MFAManager
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @ObservedObject private var accountService = AccountService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var theme

    // Sign-in state
    @State private var selectedTab = 0          // 0 = Apple, 1 = Email
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var showResetConfirm = false

    // Signed-in state
    @State private var showSignOutConfirm = false
    @State private var showMFASheet = false
    @State private var showDisableMFAConfirm = false

    // Palette (matches SettingsSheetView exactly)
    private var pageBg: Color {
        colorScheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.05)
                             : Color(red: 0.980, green: 0.973, blue: 0.961)
    }
    private var cardBg: Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.11)
                             : Color(red: 0.953, green: 0.937, blue: 0.910)
    }
    // System label colours: white at 30–40% on the dark card measured 2.7–3.6:1,
    // under WCAG AA (4.5:1) for the row values and section headers that use them.
    private var iconTint: Color { Color(UIColor.secondaryLabel) }
    private var chevronTint: Color { Color(UIColor.tertiaryLabel) }
    private var valueTint: Color { Color(UIColor.secondaryLabel) }
    private var sepColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color(UIColor.separator).opacity(0.3)
    }
    private var sectionTint: Color { Color(UIColor.secondaryLabel) }
    private var inputBg: Color {
        colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(red: 0.953, green: 0.937, blue: 0.910)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                pageBg.ignoresSafeArea()

                if supabaseAuthManager.isSignedIn {
                    signedInContent
                } else {
                    signedOutContent
                }
            }
            .navigationTitle(supabaseAuthManager.isSignedIn || accountService.isUnavailable ? "Account" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showMFASheet) {
            mfaSheetContent
        }
    }

    // MARK: - Signed Out Content

    private var signedOutContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                // Hero
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.2), Color.cyan.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 88, height: 88)
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }
                    .padding(.top, 20)

                    Text("Sync your data")
                        .font(.title2.bold())

                    Text("Sign in to back up your lists and use them on your other devices. Watchlists sync on every plan; holdings, alerts and history sync on Pro and Black.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                if accountService.isUnavailable {
                    // The news first; what an account would give underneath.
                    unavailableCard
                    syncFeaturesCard
                } else if accountService.status == .checking || accountService.status == .unknown {
                    syncFeaturesCard
                    ProgressView("Checking your connection…")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("account.checking")
                } else {
                    syncFeaturesCard

                    // Error banner (wrong password, cancelled, …) in plain words.
                    if case .error(let msg) = supabaseAuthManager.authState {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(theme.warningColor)
                            Text(friendlyAuthError(msg))
                                .font(.footnote)
                                .foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.subtleFill))
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("account.error")
                    }

                    // Auth method picker
                    Picker("Sign-in method", selection: $selectedTab) {
                        Text("Apple").tag(0)
                        Text("Email").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)

                    if selectedTab == 0 {
                        appleSignInSection
                    } else {
                        emailSignInSection
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .task { await accountService.check() }
    }

    // MARK: - Account service down

    /// Shown instead of the sign-in forms when the account service can't be
    /// reached — after the "network error" states in Glow and Opera on Mobbin.
    private var unavailableCard: some View {
        let offline = accountService.status == .offline
        return VStack(spacing: 12) {
            EmptyStateCard(
                systemImage: offline ? "wifi.slash" : "icloud.slash",
                title: offline ? "You're offline" : "Accounts are unavailable right now",
                message: offline
                    ? "Connect to the internet to sign in. Everything you've set up stays on this iPhone."
                    : "We can't reach Stock Tracker's account service, so you can't sign in or create an account at the moment. Your watchlist, holdings and alerts stay on this iPhone and keep working.",
                primaryTitle: "Try again",
                primaryAction: { Task { await accountService.check(force: true) } },
                secondaryTitle: "Continue without an account",
                secondaryAction: { dismiss() }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("account.unavailable")
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Features Card

    private var syncFeaturesCard: some View {
        VStack(spacing: 0) {
            featureRow(icon: "list.bullet", text: "Watchlists — every plan")
            divider()
            featureRow(icon: "chart.pie", text: "Holdings and history — Pro and Black")
            divider()
            featureRow(icon: "bell", text: "Price alerts — Pro and Black")
            divider()
            featureRow(icon: "lock.shield", text: "Two-factor authentication")
        }
        .background(cardBg)
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundColor(DS.accent)
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
    }

    // MARK: - Apple Sign In

    private var appleSignInSection: some View {
        VStack(spacing: 14) {
            // The button presents Apple's sheet itself; we only fill in the request and
            // take the result. (It used to also start a second sign-in from a tap
            // gesture, so one tap ran two Apple flows.)
            SignInWithAppleButton(.signIn) { request in
                supabaseAuthManager.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await supabaseAuthManager.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            .disabled(supabaseAuthManager.authState == .signingIn)
            .accessibilityIdentifier("account.apple")

            Text("Your Apple ID email is kept private.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Email Sign In / Sign Up

    private var emailSignInSection: some View {
        VStack(spacing: 14) {
            Picker("Mode", selection: $isSignUp) {
                Text("Sign In").tag(false)
                Text("Create Account").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope")
                        .foregroundColor(iconTint)
                        .frame(width: 20)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                }
                .padding(14)
                .background(inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .foregroundColor(iconTint)
                        .frame(width: 20)
                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                }
                .padding(14)
                .background(inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 24)

            Button {
                Task { await submitEmail() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(colors: [.blue, .cyan.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(height: 50)
                    if supabaseAuthManager.authState == .signingIn {
                        ProgressView().tint(.white)
                    } else {
                        Text(isSignUp ? "Create Account" : "Sign In")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
            }
            .disabled(email.isEmpty || password.isEmpty || supabaseAuthManager.authState == .signingIn)
            .padding(.horizontal, 24)

            if !isSignUp {
                Button("Forgot Password?") {
                    showResetConfirm = true
                }
                .font(.footnote)
                .foregroundColor(.blue)
                .alert("Reset Password", isPresented: $showResetConfirm) {
                    Button("Send Reset Email") {
                        Task {
                            try? await supabaseAuthManager.sendPasswordReset(email: email)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("We'll send a password reset link to \(email.isEmpty ? "your email address" : email).")
                }
            }
        }
    }

    // MARK: - Signed In Content

    private var signedInContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                // Profile header
                profileCard
                    .padding(.top, 8)

                // Cloud sync
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Cloud Sync")
                    VStack(spacing: 0) {
                        syncStatusRow
                        divider()
                        dataSyncRow
                        divider()
                        syncNowRow
                    }
                    .background(cardBg)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(sepColor, lineWidth: 1))
                }
                .padding(.horizontal, 20)

                // Security
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Security")
                    VStack(spacing: 0) {
                        mfaRow
                        divider()
                        aalRow
                    }
                    .background(cardBg)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(sepColor, lineWidth: 1))
                }
                .padding(.horizontal, 20)

                // Account actions
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Account")
                    VStack(spacing: 0) {
                        Button {
                            showSignOutConfirm = true
                        } label: {
                            flatRow("rectangle.portrait.and.arrow.right", "Sign Out", tintOverride: .red)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(cardBg)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(sepColor, lineWidth: 1))
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 40)
        }
        .confirmationDialog("Sign out of your cloud account?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await supabaseAuthManager.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            Task { await mfaManager.checkMFAStatus() }
        }
        .task { await accountService.check() }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 64, height: 64)
                Text(initials)
                    .font(.title2.bold())
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(supabaseAuthManager.userEmail ?? "Signed In")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text("Cloud account active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(chevronTint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(sepColor, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    // MARK: - Sync Section Rows

    private var syncStatusRow: some View {
        HStack(spacing: 14) {
            Image(systemName: syncIcon)
                .font(.body)
                .foregroundColor(syncIconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Status")
                    .font(.body)
                    .foregroundColor(.primary)
                Text(syncDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if case .syncing = syncManager.syncState {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    private var dataSyncRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text("Data Sync")
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Text("All Data")
                .font(.subheadline)
                .foregroundColor(valueTint)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    private var syncNowRow: some View {
        Button {
            Task {
                await syncManager.pullAndRefresh(
                    marketData: marketData,
                    alertManager: alertManager
                )
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                Text("Sync Now")
                    .font(.body)
                    .foregroundColor(.blue)
                Spacer()
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .disabled(syncManager.syncState == .syncing)
    }

    // MARK: - Security Section Rows

    private var mfaRow: some View {
        Button { showMFASheet = true } label: {
            HStack(spacing: 14) {
                Image(systemName: mfaManager.isMFAEnabled ? "lock.shield.fill" : "lock.shield")
                    .font(.body)
                    .foregroundColor(mfaManager.isMFAEnabled ? .green : iconTint)
                    .frame(width: 24)
                Text("Two-Factor Auth")
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
                if mfaManager.isMFAEnabled {
                    Text("On")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                } else {
                    Text("Off")
                        .font(.subheadline)
                        .foregroundColor(valueTint)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(chevronTint)
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private var aalRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.checkered")
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text("Session Security")
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Text(mfaManager.isMFAEnabled ? "Enhanced" : "Standard")
                .font(.subheadline)
                .foregroundColor(valueTint)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    // MARK: - MFA Sheet

    private var mfaSheetContent: some View {
        NavigationStack {
            ZStack {
                pageBg.ignoresSafeArea()
                mfaSheetBody
            }
            .navigationTitle("Two-Factor Auth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showMFASheet = false }
                }
            }
        }
        .environmentObject(mfaManager)
    }

    @ViewBuilder
    private var mfaSheetBody: some View {
        if mfaManager.isMFAEnabled {
            mfaEnabledView
        } else {
            mfaEnrollView
        }
    }

    private var mfaEnabledView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Two-Factor Auth is On")
                .font(.title3.bold())

            Text("Your account is protected with an authenticator app.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Factor info
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "key.viewfinder")
                        .font(.body)
                        .foregroundColor(iconTint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Authenticator App")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("TOTP")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                .frame(minHeight: 46)
                .padding(.horizontal, 16)
            }
            .background(cardBg)
            .cornerRadius(12)
            .padding(.horizontal, 24)

            Spacer()

            Button(role: .destructive) {
                showDisableMFAConfirm = true
            } label: {
                Text("Disable Two-Factor Auth")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .confirmationDialog("Disable two-factor authentication?", isPresented: $showDisableMFAConfirm, titleVisibility: .visible) {
                Button("Disable", role: .destructive) {
                    Task { await mfaManager.unenrollTOTP() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account will be less secure without two-factor authentication.")
            }
        }
    }

    private var mfaEnrollView: some View {
        MFAEnrollmentView(onComplete: { showMFASheet = false })
            .environmentObject(mfaManager)
    }

    // MARK: - Settings-Style Helpers

    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(sectionTint)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func flatRow(_ sf: String, _ title: String, trailing: String? = nil, tintOverride: Color? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sf)
                .font(.body)
                .foregroundColor(tintOverride ?? iconTint)
                .frame(width: 24)
            Text(title)
                .font(.body)
                .foregroundColor(tintOverride ?? .primary)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.subheadline)
                    .foregroundColor(valueTint)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(chevronTint)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(sepColor)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }

    // MARK: - Helpers

    private var initials: String {
        guard let e = supabaseAuthManager.userEmail, let f = e.first else { return "?" }
        return String(f).uppercased()
    }

    private var syncIcon: String {
        switch syncManager.syncState {
        case .idle: return "icloud"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .lastSyncedAt: return "checkmark.icloud.fill"
        case .error: return "exclamationmark.icloud.fill"
        }
    }

    private var syncIconColor: Color {
        switch syncManager.syncState {
        case .idle: return iconTint
        case .syncing: return .blue
        case .lastSyncedAt: return .green
        case .error: return .orange
        }
    }

    private var syncDescription: String {
        switch syncManager.syncState {
        case .idle: return "Connected"
        case .syncing: return "Syncing..."
        case .lastSyncedAt(let d): return "Synced \(d.formatted(.relative(presentation: .named)))"
        // Never the raw system error ("A server with the specified hostname could not be
        // found."); your data is safe on this iPhone either way.
        case .error:
            switch accountService.status {
            case .offline: return "Sync paused — you're offline"
            case .unavailable: return "Sync paused — accounts are unavailable right now"
            default: return "Couldn't sync — your data is safe on this iPhone"
            }
        }
    }

    private func submitEmail() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        if isSignUp {
            await supabaseAuthManager.signUp(email: email, password: password)
        } else {
            await supabaseAuthManager.signIn(email: email, password: password)
        }
    }
}

// MARK: - MFA Enrollment View

struct MFAEnrollmentView: View {
    @EnvironmentObject var mfaManager: MFAManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var theme

    let onComplete: () -> Void

    @State private var verificationCode = ""

    private var cardBg: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12)
                             : Color(red: 0.953, green: 0.937, blue: 0.910)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                switch mfaManager.mfaState {
                case .idle:
                    idleView
                case .enrolling:
                    enrollingView
                case .verifying:
                    ProgressView("Verifying...")
                        .padding(.top, 80)
                case .verified:
                    verifiedView
                case .error(let msg):
                    errorView(msg)
                case .challenging:
                    EmptyView()
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Add Two-Factor Auth")
                .font(.title3.bold())

            Text("Use an authenticator app like Google Authenticator, Authy, or 1Password for extra security.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await mfaManager.enrollTOTP() }
            } label: {
                HStack {
                    Image(systemName: "qrcode")
                    Text("Set Up Authenticator")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    LinearGradient(colors: [.blue, .cyan.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
        }
    }

    private var enrollingView: some View {
        VStack(spacing: 20) {
            Text("Scan QR Code")
                .font(.title3.bold())

            Text("Scan with your authenticator app, then enter the 6-digit code.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // QR Code
            if let qr = mfaManager.qrCodeImage {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            }

            // Manual secret
            if let secret = mfaManager.enrollSecret {
                VStack(spacing: 6) {
                    Text("Or enter this key manually:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(secret)
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .background(cardBg)
                        .cornerRadius(8)
                        .textSelection(.enabled)
                }
            }

            // Code entry
            VStack(spacing: 8) {
                TextField("000000", text: $verificationCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(.title2, design: .monospaced))
                    .tracking(8)
                    .padding(14)
                    .background(cardBg)
                    .cornerRadius(10)
                    .frame(width: 200)
                    .onChange(of: verificationCode) { _, newValue in
                        // Limit to 6 digits
                        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                        if filtered != newValue { verificationCode = filtered }
                    }
            }

            Button {
                Task { await mfaManager.verifyEnrollment(code: verificationCode) }
            } label: {
                Text("Verify & Enable")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(
                        verificationCode.count == 6
                            ? LinearGradient(colors: [.blue, .cyan.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.gray.opacity(0.4), .gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(12)
            }
            .disabled(verificationCode.count != 6)

            Button("Cancel") {
                mfaManager.resetEnrollment()
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }

    private var verifiedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("You're All Set!")
                .font(.title3.bold())

            Text("Two-factor authentication is now enabled on your account.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                onComplete()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(
                        LinearGradient(colors: [.green, .mint.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(12)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Setup Failed")
                .font(.title3.bold())

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await mfaManager.enrollTOTP() }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(12)
            }

            Button("Cancel") {
                mfaManager.resetEnrollment()
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(SupabaseAuthManager())
        .environmentObject(SyncManager.shared)
        .environmentObject(MFAManager.shared)
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .preferredColorScheme(.dark)
}
