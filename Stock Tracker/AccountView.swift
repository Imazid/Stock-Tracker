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

    // Palette (matches SettingsSheetView)
    private var pageBg: Color {
        colorScheme == .dark ? Color(red: 0.06, green: 0.06, blue: 0.07)
                             : Color(red: 0.980, green: 0.973, blue: 0.961)
    }
    private var cardBg: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12)
                             : Color(red: 0.953, green: 0.937, blue: 0.910)
    }
    private var iconTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : .secondary
    }
    private var chevronTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.secondary.opacity(0.4)
    }
    private var valueTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : .secondary
    }
    private var sepColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color(UIColor.separator).opacity(0.3)
    }
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
            .navigationTitle(supabaseAuthManager.isSignedIn ? "Account" : "Sign In")
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

                    Text("Sync Your Data")
                        .font(.title2.bold())

                    Text("Sign in to sync your watchlist, portfolio, alerts, and history across all your devices.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                // Error banner
                if case .error(let msg) = supabaseAuthManager.authState {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(msg)
                            .font(.footnote)
                    }
                    .foregroundColor(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                }

                // Features card
                syncFeaturesCard

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
            .padding(.bottom, 40)
        }
    }

    // MARK: - Features Card

    private var syncFeaturesCard: some View {
        VStack(spacing: 0) {
            featureRow(icon: "list.bullet", text: "Sync watchlist across devices")
            divider()
            featureRow(icon: "chart.pie", text: "Sync portfolio and holdings")
            divider()
            featureRow(icon: "bell", text: "Sync price alerts")
            divider()
            featureRow(icon: "clock.arrow.circlepath", text: "Sync portfolio history")
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
                .foregroundColor(.green)
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
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { _ in }
            .frame(height: 50)
            .cornerRadius(12)
            .padding(.horizontal, 24)
            .disabled(supabaseAuthManager.authState == .signingIn)
            .onTapGesture {
                Task { await supabaseAuthManager.signInWithApple() }
            }

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
            VStack(spacing: 24) {
                // Profile header
                profileCard
                    .padding(.top, 8)

                // Cloud sync
                section("Cloud Sync") {
                    syncStatusRow
                    divider()
                    dataSyncRow
                    divider()
                    syncNowRow
                }

                // Security
                section("Security") {
                    mfaRow
                    divider()
                    aalRow
                }

                // Account actions
                section("Account") {
                    Button {
                        showSignOutConfirm = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.body)
                                .foregroundColor(.red)
                                .frame(width: 22)
                            Text("Sign Out")
                                .font(.body)
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .frame(minHeight: 46)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
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
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: [.blue.opacity(0.3), .cyan.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 56, height: 56)
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2
                    )
                    .frame(width: 56, height: 56)
                Text(initials)
                    .font(.title3.bold())
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(supabaseAuthManager.userEmail ?? "Signed In")
                    .font(.headline)
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
        }
        .padding(16)
        .background(cardBg)
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    // MARK: - Sync Section Rows

    private var syncStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: syncIcon)
                .font(.body)
                .foregroundColor(syncIconColor)
                .frame(width: 22)
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
        .frame(minHeight: 46)
        .padding(.horizontal, 16)
    }

    private var dataSyncRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 22)
            Text("Data Synced")
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Text("All data")
                .font(.subheadline)
                .foregroundColor(valueTint)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 16)
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
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body)
                    .foregroundColor(.blue)
                    .frame(width: 22)
                Text("Sync Now")
                    .font(.body)
                    .foregroundColor(.blue)
                Spacer()
            }
            .frame(minHeight: 46)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .disabled(syncManager.syncState == .syncing)
    }

    // MARK: - Security Section Rows

    private var mfaRow: some View {
        Button { showMFASheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: mfaManager.isMFAEnabled ? "lock.shield.fill" : "lock.shield")
                    .font(.body)
                    .foregroundColor(mfaManager.isMFAEnabled ? .green : iconTint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-Factor Authentication")
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(mfaManager.isMFAEnabled ? "Enabled" : "Not enabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if mfaManager.isMFAEnabled {
                    Text("On")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(chevronTint)
            }
            .frame(minHeight: 46)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var aalRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 22)
            Text("Session Security")
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Text(mfaManager.isMFAEnabled ? "Enhanced" : "Standard")
                .font(.subheadline)
                .foregroundColor(valueTint)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 16)
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

    // MARK: - Section / Divider (matches SettingsSheetView)

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundColor(chevronTint)
                .kerning(0.5)
                .padding(.leading, 4)

            VStack(spacing: 0) { content() }
                .background(cardBg)
                .cornerRadius(12)
        }
        .padding(.horizontal, 24)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(sepColor)
            .frame(height: 0.5)
            .padding(.leading, 50)
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
        case .error(let m): return m
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
