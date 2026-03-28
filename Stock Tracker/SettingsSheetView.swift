//
//  SettingsView.swift
//  Stock Tracker
//

import SwiftUI
import LocalAuthentication

// MARK: - SettingsSheetView

struct SettingsSheetView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var supabaseAuthManager: SupabaseAuthManager
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var themeManager: ThemeManager

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("preferredMarket")  private var preferredMarket: String = "US"
    @AppStorage("defaultChartType") private var defaultChartType: String = "line"

    @State private var showSubscriptionSettings = false
    @State private var showAlerts = false
    @AppStorage("blackTierRefreshInterval") private var blackTierRefreshInterval: Int = 30
    @State private var isRefreshing = false
    @State private var showAccountSheet = false
    @State private var showSignOutConfirm = false
    @State private var showPaywall = false

    // Palette
    private var pageBg: Color {
        colorScheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.05)
                             : Color(red: 0.980, green: 0.973, blue: 0.961)
    }
    private var cardBg: Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.11)
                             : Color(red: 0.953, green: 0.937, blue: 0.910)
    }
    private var iconTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.40) : .secondary
    }
    private var chevronTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.secondary.opacity(0.4)
    }
    private var valueTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.30) : .secondary
    }
    private var sepColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color(UIColor.separator).opacity(0.3)
    }
    private var sectionTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.30) : .secondary
    }

    @ViewBuilder
    private var syncStatusText: some View {
        switch syncManager.syncState {
        case .idle:                Text("Sync enabled")
        case .syncing:             Text("Syncing…")
        case .lastSyncedAt(let d): Text("Synced \(d.formatted(.relative(presentation: .named)))")
        case .error(let m):        Text("Sync error: \(m)").foregroundColor(.red)
        }
    }

    private var isFaceIDAvailable: Bool {
        let c = LAContext(); var e: NSError?
        return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {

                        // Close button
                        HStack {
                            Spacer()
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.trailing, 4)
                        .padding(.top, 12)

                        // Profile header
                        profileHeader
                            .padding(.top, 16)

                        // Subscription card
                        subscriptionCard
                            .padding(.top, 20)

                        // Stock Tracker section
                        sectionLabel("Stock Tracker")
                            .padding(.top, 28)

                        NavigationLink { SubscriptionSettingsView() } label: {
                            flatRow("crown", "Subscription", trailing: subscriptionManager.currentTier.displayName)
                        }
                        flatPickerRow("paintbrush", "Appearance") {
                            Picker("", selection: $themeManager.themeMode) {
                                ForEach(ThemeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(valueTint)
                        }
                        flatPickerRow("dollarsign.circle", "Currency") {
                            Picker("", selection: $marketData.preferredCurrency) {
                                ForEach(MarketData.supportedCurrencies, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(valueTint)
                        }
                        flatPickerRow("clock", "Market") {
                            Picker("", selection: $preferredMarket) {
                                Text("US").tag("US"); Text("AU").tag("AU")
                            }
                            .pickerStyle(.menu)
                            .tint(valueTint)
                        }
                        refreshIntervalRow
                        refreshButton
                        NavigationLink { DataSourceView() } label: {
                            flatRow("server.rack", "Data Sources")
                        }

                        // General section
                        sectionLabel("General")
                            .padding(.top, 24)

                        Button { showAccountSheet = true } label: {
                            flatRow("person", "Account")
                        }
                        .buttonStyle(.plain)
                        flatPickerRow("eye", "Color Vision") {
                            Picker("", selection: $themeManager.colorblindMode) {
                                ForEach(ColorblindMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(valueTint)
                        }
                        flatToggleRow("circle.lefthalf.filled", "High Contrast", isOn: $themeManager.highContrastEnabled)
                        if isFaceIDAvailable {
                            flatToggleRow("faceid", "App Lock", isOn: $authManager.useBiometrics)
                        }
                        Button {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        } label: {
                            flatRow("globe", "Language", trailing: "System")
                        }
                        .buttonStyle(.plain)
                        NavigationLink { PrivacyView() } label: {
                            flatRow("hand.raised", "Privacy")
                        }

                        #if DEBUG
                        sectionLabel("Developer")
                            .padding(.top, 24)
                        NavigationLink { DebugView() } label: {
                            flatRow("wrench.and.screwdriver", "Debug Tools")
                        }
                        #endif

                        // About section
                        sectionLabel("About")
                            .padding(.top, 24)

                        NavigationLink { BuiltInTermsView() } label: {
                            flatRow("doc.text", "Terms of Service")
                        }
                        NavigationLink { BuiltInPrivacyPolicyView() } label: {
                            flatRow("lock.doc", "Privacy Policy")
                        }
                        Button { } label: {
                            flatRow("star", "Rate App")
                        }
                        .buttonStyle(.plain)

                        // Sign out
                        if supabaseAuthManager.isSignedIn {
                            Button(role: .destructive) { showSignOutConfirm = true } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.body)
                                        .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.3))
                                        .frame(width: 24)
                                    Text("Sign Out")
                                        .font(.body)
                                        .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.3))
                                    Spacer()
                                }
                                .frame(minHeight: 52)
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                        }

                        // Footer
                        appFooter
                            .padding(.top, 32)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountView()
                .environmentObject(supabaseAuthManager)
                .environmentObject(syncManager)
                .environmentObject(MFAManager.shared)
                .environmentObject(marketData)
                .environmentObject(alertManager)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(requiredTier: .pro, featureName: "Stock Tracker Pro")
                .environmentObject(subscriptionManager)
        }
        .confirmationDialog("Sign out of your cloud account?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await supabaseAuthManager.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your portfolio data stays on this device. You can sign back in at any time.")
        }
    }

    // MARK: - Profile Header (Manus style)

    @ViewBuilder
    private var profileHeader: some View {
        Button { showAccountSheet = true } label: {
            HStack(spacing: 16) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Text(initials)
                            .font(.title2.bold())
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(chevronTint)
                    }
                    if supabaseAuthManager.isSignedIn {
                        Text(supabaseAuthManager.userEmail ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Sign in to sync")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subscription Card (Manus style)

    private var subscriptionCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(subscriptionManager.currentTier.displayName)
                    .font(.headline.bold())
                    .foregroundColor(.primary)
                Spacer()
                if subscriptionManager.currentTier == .free {
                    Button { showPaywall = true } label: {
                        Text("Upgrade")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // Dashed divider
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundColor(sepColor)
                .frame(height: 1)
                .padding(.horizontal, 16)

            if supabaseAuthManager.isSignedIn {
                Button { showAccountSheet = true } label: {
                    HStack {
                        Text("Cloud Sync")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        syncStatusText
                            .font(.subheadline)
                            .foregroundColor(valueTint)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(chevronTint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Text("Cloud Sync")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("Not signed in")
                        .font(.subheadline)
                        .foregroundColor(valueTint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(cardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(sepColor, lineWidth: 1))
    }

    // MARK: - Section Label

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

    // MARK: - Flat Row Primitives

    private func flatRow(_ sf: String, _ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sf)
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
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

    private func flatInfoRow(_ sf: String, _ title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sf)
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(valueTint)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func flatPickerRow<C: View>(_ sf: String, _ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sf)
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            control()
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    private func flatToggleRow(_ sf: String, _ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sf)
                .font(.body)
                .foregroundColor(iconTint)
                .frame(width: 24)
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.glass)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 4)
    }

    // MARK: - Inline rows

    private var refreshIntervalRow: some View {
        let tier = subscriptionManager.currentTier
        return Group {
            if tier == .black {
                flatPickerRow("arrow.clockwise", "Auto Refresh") {
                    Picker("", selection: $blackTierRefreshInterval) {
                        ForEach(FeatureGate.blackTierRefreshOptions, id: \.self) { sec in
                            Text("\(sec)s").tag(sec)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(valueTint)
                    .onChange(of: blackTierRefreshInterval) { _, _ in
                        NotificationCenter.default.post(name: .blackTierRefreshIntervalChanged, object: nil)
                    }
                }
            } else {
                flatInfoRow("arrow.clockwise", "Auto Refresh",
                        value: tier == .pro ? "60s" : "Manual")
            }
        }
    }

    private var refreshButton: some View {
        Button { refreshData() } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body).foregroundColor(iconTint).frame(width: 24)
                Text("Refresh Now").font(.body).foregroundColor(.primary)
                Spacer()
                if isRefreshing { ProgressView().tint(valueTint) }
            }
            .frame(minHeight: 52).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
    }

    // MARK: - Helpers

    private var initials: String {
        guard let e = supabaseAuthManager.userEmail, let f = e.first else { return "?" }
        return String(f).uppercased()
    }

    private var displayName: String {
        if let email = supabaseAuthManager.userEmail {
            return email.components(separatedBy: "@").first ?? email
        }
        return "Guest"
    }

    private func refreshData() {
        isRefreshing = true
        Task {
            await marketData.refreshFromAPI()
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                isRefreshing = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    // MARK: - App Footer

    private var appFooter: some View {
        VStack(spacing: 6) {
            Text("Stock Tracker")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary.opacity(0.6))
            Text("Version \(appVersion) (\(appBuild))")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Dashed Line Shape

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

// MARK: - Built-In Terms of Service

struct BuiltInTermsView: View {
    @Environment(\.colorScheme) var colorScheme

    private var bg: Color {
        colorScheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.05)
                             : Color(red: 0.980, green: 0.973, blue: 0.961)
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Last updated: March 2026")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    termsSection("1. Acceptance of Terms",
                        "By downloading, installing, or using Stock Tracker (\"the App\"), you agree to be bound by these Terms of Service. If you do not agree, do not use the App.")

                    termsSection("2. Description of Service",
                        "Stock Tracker provides financial market data, portfolio tracking, watchlists, and related tools for informational purposes only. The App is not a financial advisor, broker, or investment service.")

                    termsSection("3. No Financial Advice",
                        "All data, charts, AI-generated insights, and information displayed in the App are for informational and educational purposes only. They do not constitute financial advice, investment recommendations, or solicitations to buy or sell securities. Always consult a qualified financial advisor before making investment decisions.")

                    termsSection("4. Data Accuracy",
                        "Market data is sourced from third-party providers and may be delayed by up to 15 minutes. We do not guarantee the accuracy, completeness, or timeliness of any data. You acknowledge that the App may contain errors or inaccuracies.")

                    termsSection("5. User Accounts",
                        "You may create an account to enable cloud sync features. You are responsible for maintaining the confidentiality of your account credentials. We reserve the right to suspend accounts that violate these terms.")

                    termsSection("6. Subscriptions",
                        "The App offers optional paid subscriptions (Pro, Black) that unlock additional features. Subscriptions are billed through Apple's App Store and are subject to Apple's subscription terms. You may cancel at any time through your Apple ID settings.")

                    termsSection("7. Brokerage Connections",
                        "The App may allow you to connect third-party brokerage accounts via SnapTrade. We do not store your brokerage credentials and have read-only access to your holdings. We are not responsible for any actions taken by third-party services.")

                    termsSection("8. Intellectual Property",
                        "All content, design, and code within the App are the property of the developer. You may not copy, modify, distribute, or reverse-engineer any part of the App.")

                    termsSection("9. Limitation of Liability",
                        "To the maximum extent permitted by law, the developer shall not be liable for any direct, indirect, incidental, or consequential damages arising from your use of the App, including but not limited to financial losses from investment decisions.")

                    termsSection("10. Changes to Terms",
                        "We reserve the right to modify these terms at any time. Continued use of the App after changes constitutes acceptance of the updated terms.")
                }
                .padding(20)
            }
        }
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func termsSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Built-In Privacy Policy

struct BuiltInPrivacyPolicyView: View {
    @Environment(\.colorScheme) var colorScheme

    private var bg: Color {
        colorScheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.05)
                             : Color(red: 0.980, green: 0.973, blue: 0.961)
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Last updated: March 2026")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    privacySection("Data Storage",
                        "Your portfolio holdings, watchlist, price alerts, and transaction history are stored securely in the iOS Keychain on your device. This data is protected by the iOS secure enclave and is not accessible when the device is locked.")

                    privacySection("Cloud Sync",
                        "If you sign in, selected data is synced to our cloud service (Supabase) to enable cross-device access. Free accounts sync watchlists only. Paid accounts sync all portfolio data. All data is encrypted in transit via TLS.")

                    privacySection("Third-Party Services",
                        "The App communicates with the following services to provide market data:\n\n• Alpaca Markets — stock quotes and price history\n• CoinGecko — cryptocurrency prices\n• Alpha Vantage — symbol search and ASX stocks\n• NewsAPI — financial news articles\n• X.AI (Grok) — AI investing assistant\n• SnapTrade — brokerage account connections\n• Supabase — cloud authentication and sync\n\nOnly the minimum data required is sent to each service (e.g., stock symbols you search). No personal information is shared with data providers.")

                    privacySection("Device Permissions",
                        "• Microphone — used only for voice search and AI voice input. Audio is processed on-device via Apple Speech Recognition and is not stored.\n• Face ID / Touch ID — optional app lock feature. Biometric data never leaves your device.\n• Notifications — optional, used only for price alerts you configure.")

                    privacySection("Analytics & Tracking",
                        "The App does not use any third-party analytics, advertising, or tracking SDKs. No personal data is sold or shared with advertisers. Crash reports, if enabled, are anonymous and contain no personal information.")

                    privacySection("Data Retention",
                        "Local data persists until you delete the app or clear data from settings. Cloud data can be deleted by signing out or contacting support. We do not retain data after account deletion.")

                    privacySection("Children's Privacy",
                        "The App is not intended for children under 13. We do not knowingly collect personal information from children.")

                    privacySection("Your Rights",
                        "You have the right to access, correct, or delete your personal data at any time. You can export your portfolio data via CSV (Black tier) or delete your cloud account from the Account settings.")

                    privacySection("Contact",
                        "For privacy-related questions or data deletion requests, contact us through the App Store listing or our support channels.")
                }
                .padding(20)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Data Source View

struct DataSourceView: View {
    var body: some View {
        List {
            Section {
                InfoRow2(title: "Stock Quotes",  value: "Alpaca Markets")
                InfoRow2(title: "Crypto Prices", value: "CoinGecko")
                InfoRow2(title: "Company Data",  value: "Alpha Vantage")
                InfoRow2(title: "News",          value: "Finnhub")
            } header: { Text("Data Providers") } footer: { Text("Market data may be delayed by up to 15 minutes.") }
            Section {
                InfoRow2(title: "Update Frequency", value: "Every 15 min")
                InfoRow2(title: "Last Updated", value: Date().formatted(date: .omitted, time: .shortened))
            } header: { Text("Refresh Schedule") }
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy View

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Your portfolio holdings, watchlist, price alerts, and transaction history are stored securely in the device Keychain — protected by the iOS secure enclave. This data never leaves your device and is not accessible when the device is locked.")
                    .font(.subheadline).foregroundColor(.secondary)
            } header: { Text("Data Storage") }

            Section {
                DataProcessorRow(name: "Alpaca Markets", purpose: "Real-time and historical stock price data", dataSent: "Stock symbols you search or track", link: "https://alpaca.markets/privacy")
                DataProcessorRow(name: "CoinGecko", purpose: "Cryptocurrency price data", dataSent: "Crypto IDs you search or track", link: "https://www.coingecko.com/en/privacy")
                DataProcessorRow(name: "Alpha Vantage", purpose: "Symbol search and company fundamentals", dataSent: "Search queries (no personal data)", link: "https://www.alphavantage.co/privacy")
                DataProcessorRow(name: "Finnhub", purpose: "Financial news and market data", dataSent: "No personal data sent (public market data only)", link: "https://finnhub.io/privacy")
                DataProcessorRow(name: "OpenAI", purpose: "AI investing assistant chat", dataSent: "Your chat messages and portfolio summary (when using AI)", link: "https://openai.com/policies/privacy-policy")
                DataProcessorRow(name: "SnapTrade", purpose: "Brokerage account connection", dataSent: "Brokerage credentials (if connected)", link: "https://snaptrade.com/privacy")
                DataProcessorRow(name: "Supabase", purpose: "Cloud account and cross-device sync", dataSent: "Watchlist (all); portfolio, alerts, history (paid only). Encrypted in transit.", link: "https://supabase.com/privacy")
            } header: { Text("Third-Party Data Processors") } footer: { Text("Tap a processor to view their privacy policy.") }

            Section {
                InfoRow2(title: "Microphone",         value: "AI voice input only")
                InfoRow2(title: "Speech Recognition",  value: "AI voice input only")
                InfoRow2(title: "Face ID / Touch ID",  value: "App lock — optional")
                InfoRow2(title: "Notifications",       value: "Price alerts — optional")
            } header: { Text("Device Permissions") } footer: { Text("No permission is required to use core features.") }

            Section {
                InfoRow2(title: "Analytics",     value: "Disabled")
                InfoRow2(title: "Crash Reports", value: "Anonymous (optional)")
                InfoRow2(title: "Ad Tracking",   value: "None")
            } header: { Text("Privacy Controls") }

            Section {
                Link(destination: URL(string: Constants.URLs.privacyPolicy)!) {
                    Label("Read Full Privacy Policy", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DataProcessorRow: View {
    let name, purpose, dataSent, link: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: URL(string: link)!) {
                HStack {
                    Text(name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.caption).foregroundColor(.accentColor)
                }
            }
            Text(purpose).font(.caption).foregroundColor(.secondary)
            Text("Sends: \(dataSent)").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct InfoRow2: View {
    let title, value: String
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

#Preview {
    SettingsSheetView()
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .environmentObject(AuthManager())
        .environmentObject(ThemeManager())
}
