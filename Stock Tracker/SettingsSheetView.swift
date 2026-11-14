//
//  SettingsSheetView.swift
//  Stock Tracker
//
//  Settings, after Uniswap / Binance / Wise on Mobbin: grouped rows that show
//  their current value, every row does something, and the data/privacy screens
//  describe what the app really uses.
//

import SwiftUI
import StoreKit
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
    @EnvironmentObject var notificationScheduler: NotificationScheduler
    @ObservedObject private var accountService = AccountService.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.requestReview) private var requestReview

    @AppStorage("preferredMarket") private var preferredMarket: String = "auto"
    @AppStorage("blackTierRefreshInterval") private var blackTierRefreshInterval: Int = 30
    @ObservedObject private var permission = NotificationPermission.shared

    @State private var isRefreshing = false
    @State private var showAccountSheet = false
    @State private var showSignOutConfirm = false
    @State private var showPaywall = false
    @State private var showAlerts = false

    private var isFaceIDAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var body: some View {
        NavigationStack {
            List {
                Section { profileRow }
                Section { planRow }

                preferencesSection
                notificationsSection
                dataSection
                securitySection
                accessibilitySection
                supportSection

                #if DEBUG
                Section("Developer") {
                    NavigationLink { DebugView() } label: { rowLabel("Debug tools", icon: "wrench.and.screwdriver") }
                }
                #endif

                if supabaseAuthManager.isSignedIn {
                    Section {
                        Button(role: .destructive) { showSignOutConfirm = true } label: {
                            rowLabel("Sign out", icon: "rectangle.portrait.and.arrow.right", tint: theme.negativeColor)
                        }
                        .accessibilityIdentifier("settings.signOut")
                    }
                }

                Section {
                    appFooter
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("settings.done")
                }
            }
            .task {
                await permission.refresh()
                if !supabaseAuthManager.isSignedIn { await accountService.check() }
            }
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
        .sheet(isPresented: $showAlerts) {
            PriceAlertsView()
                .environmentObject(alertManager)
                .environmentObject(marketData)
                .environmentObject(subscriptionManager)
        }
        .confirmationDialog("Sign out of your account?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await supabaseAuthManager.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything stays on this iPhone. You can sign back in at any time.")
        }
    }

    // MARK: Profile & plan

    private var profileRow: some View {
        Button { showAccountSheet = true } label: {
            HStack(spacing: DS.Space.m) {
                Text(initials)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(DS.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(supabaseAuthManager.isSignedIn ? displayName : "Not signed in")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                    Text(supabaseAuthManager.isSignedIn
                         ? (supabaseAuthManager.userEmail ?? "")
                         : (accountService.status == .unavailable
                            ? "Accounts are unavailable right now"
                            : "Sign in to back up and sync your lists"))
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                chevron
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.subtleFill)
        .accessibilityIdentifier("settings.account")
    }

    private var planRow: some View {
        HStack(spacing: DS.Space.m) {
            NavigationLink { SubscriptionSettingsView() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(subscriptionManager.currentTier.displayName) plan")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(planSummary)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .accessibilityIdentifier("settings.subscription")
        }
        .listRowBackground(theme.subtleFill)
    }

    private var planSummary: String {
        let tier = subscriptionManager.currentTier
        let watch = tier.maxWatchlistAssets.map { "\($0) watchlist items" } ?? "Unlimited watchlist"
        let alerts = tier.maxPriceAlerts.map { "\($0) price alert\($0 == 1 ? "" : "s")" } ?? "unlimited alerts"
        return tier == .free ? "\(watch) · \(alerts) · ads" : "\(watch) · \(alerts)"
    }

    // MARK: Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
            Picker(selection: $themeManager.themeMode) {
                ForEach(ThemeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            } label: { rowLabel("Appearance", icon: "circle.lefthalf.filled") }
            .accessibilityIdentifier("settings.appearance")

            Picker(selection: $marketData.preferredCurrency) {
                ForEach(MarketData.supportedCurrencies, id: \.self) { Text($0).tag($0) }
            } label: { rowLabel("Currency", icon: "dollarsign.circle") }
            .accessibilityIdentifier("settings.currency")

            Picker(selection: $preferredMarket) {
                Text("Markets you follow").tag("auto")
                Text("US (NYSE)").tag("US")
                Text("Australia (ASX)").tag("AU")
                Text("Both").tag("BOTH")
            } label: { rowLabel("Market hours", icon: "clock") }
            .accessibilityIdentifier("settings.market")
        }
        .listRowBackground(theme.subtleFill)
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            if permission.isDenied {
                NotificationsOffBanner(message: "Alerts and summaries can't reach you until you turn them on.")
            }
            Button { showAlerts = true } label: {
                HStack {
                    rowLabel("Price alerts", icon: "bell")
                    Spacer()
                    let active = alertManager.alerts.filter(\.isActive).count
                    Text(active == 0 ? "None" : "\(active) active")
                        .foregroundStyle(theme.secondaryText)
                    chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.priceAlerts")

            Toggle(isOn: asksPermission($notificationScheduler.dailySummaryEnabled)) {
                rowLabel("Daily summary", icon: "text.alignleft")
            }
            .tint(DS.accent)
            .accessibilityIdentifier("settings.dailySummary")
            if notificationScheduler.dailySummaryEnabled {
                Picker(selection: $notificationScheduler.dailySummaryHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourText(hour)).tag(hour)
                    }
                } label: { rowLabel("Summary time", icon: "clock") }
            }
            Toggle(isOn: asksPermission($notificationScheduler.significantMovementEnabled)) {
                rowLabel("Big moves (over \(Int(notificationScheduler.movementThreshold))%)", icon: "waveform.path.ecg")
            }
            .tint(DS.accent)
            Toggle(isOn: asksPermission($notificationScheduler.marketOpenCloseEnabled)) {
                rowLabel("Market open & close", icon: "bell.and.waves.left.and.right")
            }
            .tint(DS.accent)
            Toggle(isOn: asksPermission($notificationScheduler.earningsAlertEnabled)) {
                rowLabel("Earnings reminders", icon: "calendar")
            }
            .tint(DS.accent)
        } header: {
            Text("Notifications")
        } footer: {
            Text(AlertCopy.howItWorks)
        }
        .listRowBackground(theme.subtleFill)
    }

    /// Turning a notification on asks for permission the first time.
    private func asksPermission(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                if newValue { Task { await permission.requestIfNeeded() } }
            }
        )
    }

    private func hourText(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            if subscriptionManager.currentTier == .black {
                Picker(selection: $blackTierRefreshInterval) {
                    ForEach(FeatureGate.blackTierRefreshOptions, id: \.self) { Text("Every \($0) s").tag($0) }
                } label: { rowLabel("Auto refresh", icon: "arrow.clockwise") }
                .onChange(of: blackTierRefreshInterval) { _, _ in
                    NotificationCenter.default.post(name: .blackTierRefreshIntervalChanged, object: nil)
                }
            } else {
                LabeledContent {
                    Text(subscriptionManager.currentTier == .pro ? "Every 60 s" : "When you open or pull to refresh")
                        .multilineTextAlignment(.trailing)
                } label: { rowLabel("Auto refresh", icon: "arrow.clockwise") }
            }

            Button { refreshData() } label: {
                HStack {
                    rowLabel("Refresh now", icon: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text(lastUpdatedText)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityIdentifier("settings.refresh")

            NavigationLink { DataSourceView() } label: { rowLabel("Data sources", icon: "server.rack") }
                .accessibilityIdentifier("settings.dataSources")
        } header: {
            Text("Market data")
        }
        .listRowBackground(theme.subtleFill)
    }

    private var lastUpdatedText: String {
        guard let date = marketData.lastQuoteRefreshDate else { return "Not yet" }
        return "Updated " + date.formatted(.relative(presentation: .named))
    }

    private func refreshData() {
        isRefreshing = true
        Task {
            await marketData.refreshFromAPI()
            isRefreshing = false
            Haptics.success()
        }
    }

    // MARK: Security, accessibility, support

    private var securitySection: some View {
        Section("Security & privacy") {
            if isFaceIDAvailable {
                Toggle(isOn: $authManager.useBiometrics) { rowLabel("Lock with Face ID", icon: "faceid") }
                    .tint(DS.accent)
            }
            NavigationLink { PrivacyView() } label: { rowLabel("Privacy & data", icon: "hand.raised") }
                .accessibilityIdentifier("settings.privacy")
            // Always listed: signed out it explains that invites need an account, and
            // while the account service is down it says so (never a dead spinner).
            NavigationLink { ReferAndEarnView() } label: { rowLabel("Refer a friend", icon: "gift") }
                .accessibilityIdentifier("settings.referrals")
        }
        .listRowBackground(theme.subtleFill)
    }

    private var accessibilitySection: some View {
        Section {
            Picker(selection: $themeManager.colorblindMode) {
                ForEach(ColorblindMode.allCases) { Text($0.rawValue).tag($0) }
            } label: { rowLabel("Gain & loss colours", icon: "eye") }
            Toggle(isOn: $themeManager.highContrastEnabled) { rowLabel("High contrast", icon: "circle.righthalf.filled") }
                .tint(DS.accent)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Gains and losses also show ▲ and ▼, so they never rely on colour alone.")
        }
        .listRowBackground(theme.subtleFill)
    }

    private var supportSection: some View {
        Section("About") {
            Button {
                Haptics.tap()
                requestReview()
            } label: {
                HStack {
                    rowLabel("Rate Stock Tracker", icon: "star")
                    Spacer()
                    chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.rate")

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                HStack {
                    rowLabel("Language", icon: "globe")
                    Spacer()
                    Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "") ?? "System")
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens iPhone Settings")

            NavigationLink { BuiltInTermsView() } label: { rowLabel("Terms of Service", icon: "doc.text") }
                .accessibilityIdentifier("settings.terms")
            NavigationLink { BuiltInPrivacyPolicyView() } label: { rowLabel("Privacy Policy", icon: "lock.doc") }
                .accessibilityIdentifier("settings.privacyPolicy")
        }
        .listRowBackground(theme.subtleFill)
    }

    // MARK: Pieces

    private func rowLabel(_ title: String, icon: String, tint: Color? = nil) -> some View {
        Label {
            Text(title).foregroundStyle(tint ?? theme.primaryText)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint ?? theme.secondaryText)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.secondaryText.opacity(0.6))
            .accessibilityHidden(true)
    }

    private var initials: String {
        guard let first = supabaseAuthManager.userEmail?.first else { return "ST" }
        return String(first).uppercased()
    }

    private var displayName: String {
        guard let email = supabaseAuthManager.userEmail else { return "Signed in" }
        return email.components(separatedBy: "@").first ?? email
    }

    private var appFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 4) {
            Text("Stock Tracker")
                .font(.footnote.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.caption2)
            Text("Not financial advice. Prices can be delayed.")
                .font(.caption2)
        }
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Data sources

struct DataSourceView: View {
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                InfoRow2(title: "US stocks & ETFs", value: "Alpaca Markets (IEX)")
                InfoRow2(title: "ASX stocks & ETFs", value: "Yahoo Finance")
                InfoRow2(title: "Crypto", value: "CoinGecko")
                InfoRow2(title: "Long crypto history", value: "Alpaca Markets")
                InfoRow2(title: "Company data & logos", value: "Financial Modeling Prep, Fiscal.ai")
                InfoRow2(title: "News, earnings & analysts", value: "Finnhub")
                InfoRow2(title: "Exchange rates", value: "Frankfurter (ECB)")
                InfoRow2(title: "AI insights", value: "Google Gemini, OpenAI")
            } header: {
                Text("Where prices and data come from")
            } footer: {
                Text("US quotes come from the IEX exchange feed and can differ slightly from the consolidated price. ASX quotes can be delayed by up to 20 minutes. Prices are converted to your currency with daily reference rates.")
            }
            Section("Refreshing") {
                InfoRow2(title: "Automatic refresh", value: refreshText)
                InfoRow2(title: "Last updated", value: lastUpdated)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .dsScreenBackground()
        .navigationTitle("Data sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var refreshText: String {
        switch subscriptionManager.currentTier {
        case .free:  return "When you open or pull to refresh"
        case .pro:   return "Every 60 seconds"
        case .black: return "Every \(UserDefaults.standard.integer(forKey: "blackTierRefreshInterval").nonZero ?? 30) seconds"
        }
    }

    private var lastUpdated: String {
        guard let date = marketData.lastQuoteRefreshDate else { return "Not yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// MARK: - Privacy & data

struct PrivacyView: View {
    @Environment(\.theme) private var theme
    @AppStorage("aiPortfolioContextEnabled") private var includePortfolioContext = false

    var body: some View {
        List {
            Section {
                Text("Stock Tracker stores your watchlists, holdings, alerts and history on this iPhone. When you sign in, eligible listed-market records can sync to your account. Manual private holdings and imported AngelList statements stay on this iPhone. Saved Private Markets research, monitoring settings and provider records use your signed-in account.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            } header: { Text("Your data") }

            Section {
                DataProcessorRow(name: "Alpaca Markets", purpose: "US stock prices and charts", dataSent: "Ticker symbols", link: "https://alpaca.markets/privacy")
                DataProcessorRow(name: "Yahoo Finance", purpose: "ASX prices and charts, symbol search", dataSent: "Ticker symbols and search text", link: "https://legal.yahoo.com/us/en/yahoo/privacy/index.html")
                DataProcessorRow(name: "CoinGecko", purpose: "Crypto prices and search", dataSent: "Coin IDs and search text", link: "https://www.coingecko.com/en/privacy")
                DataProcessorRow(name: "Financial Modeling Prep · Fiscal.ai", purpose: "Company fundamentals and logos", dataSent: "Ticker symbols", link: "https://site.financialmodelingprep.com/privacy-policy")
                DataProcessorRow(name: "Finnhub", purpose: "News, earnings and analyst ratings", dataSent: "Ticker symbols", link: "https://finnhub.io/privacy")
                DataProcessorRow(name: "Frankfurter", purpose: "Currency exchange rates", dataSent: "Currency codes", link: "https://www.frankfurter.app")
                DataProcessorRow(name: "Google Gemini · OpenAI", purpose: "AI insights, the assistant and Private Markets research", dataSent: "Your question and relevant evidence. Selected private excerpts require separate permission.", link: "https://policies.google.com/privacy")
                DataProcessorRow(name: "SnapTrade", purpose: "Connecting a brokerage account", dataSent: "Read-only holdings you choose to connect", link: "https://snaptrade.com/privacy")
                DataProcessorRow(name: "Supabase", purpose: "Account, sync and signed-in Private Markets features", dataSent: "Email, synced records and the research, alerts or provider records you use", link: "https://supabase.com/privacy")
                DataProcessorRow(name: "Google AdMob", purpose: "Ads on the Free plan when enabled", dataSent: "Device, approximate location, ad interaction and diagnostics. Tracking requires your permission.", link: "https://policies.google.com/privacy")
            } header: { Text("Services we use") } footer: { Text("Tap a service to read its privacy policy.") }

            Section {
                Toggle("Share portfolio summary with AI", isOn: $includePortfolioContext)
            } header: {
                Text("AI assistant")
            } footer: {
                Text("When enabled, the assistant and generated insights can send your tracked symbols, agent names and relevant portfolio data to Google Gemini or OpenAI. You can turn this off at any time.")
            }

            Section("Permissions") {
                InfoRow2(title: "Notifications", value: "Alerts & summaries")
                InfoRow2(title: "Microphone & speech", value: "Voice search")
                InfoRow2(title: "Face ID", value: "App lock (optional)")
                InfoRow2(title: "Tracking", value: "Personalised ads (optional)")
            }

            Section {
                InfoRow2(title: "Ads", value: "Free plan only")
                InfoRow2(title: "Ad measurement", value: "Google AdMob")
            } header: { Text("Ads & analytics") } footer: { Text("Change tracking any time in Settings → Privacy & Security → Tracking.") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .dsScreenBackground()
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DataProcessorRow: View {
    let name, purpose, dataSent, link: String
    @Environment(\.theme) private var theme

    var body: some View {
        if let url = URL(string: link) {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text(purpose).font(.caption).foregroundStyle(theme.secondaryText)
            Text("Sends: \(dataSent)").font(.caption2).foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

struct InfoRow2: View {
    let title, value: String
    var body: some View {
        LabeledContent(title) {
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Built-in Terms of Service

struct BuiltInTermsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Last updated November 2026")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                section("1. Acceptance of Terms",
                    "By downloading, installing, or using Stock Tracker (\"the App\"), you agree to be bound by these Terms of Service. If you do not agree, do not use the App.")
                section("2. Description of Service",
                    "Stock Tracker provides market data, research, portfolio tracking, alerts and practice-trading tools. Practice trades use simulated funds. Where an eligible private offer has an approved route, the licensed provider manages the application, eligibility checks, payment, withdrawal and settlement. Stock Tracker displays ownership after provider confirmation.")
                section("3. No Financial Advice",
                    "All data, charts, AI-generated insights, and information displayed in the App are for informational and educational purposes only. They do not constitute financial advice, investment recommendations, or solicitations to buy or sell securities. Always consult a qualified financial adviser before making investment decisions.")
                section("4. Data Accuracy",
                    "Market data comes from third-party providers. US quotes use the IEX exchange feed and may differ from the consolidated price; ASX quotes may be delayed by up to 20 minutes. Price alerts are checked when prices update and may arrive late or not at all. We do not guarantee the accuracy, completeness, or timeliness of any data.")
                section("5. User Accounts",
                    "You may create an account to enable cloud sync features. You are responsible for maintaining the confidentiality of your account credentials. We reserve the right to suspend accounts that violate these terms.")
                section("6. Subscriptions",
                    "The App offers optional paid subscriptions (Pro, Black) that unlock additional features. Subscriptions are billed through Apple's App Store, renew automatically unless cancelled at least 24 hours before the end of the period, and are subject to Apple's terms. You can manage or cancel them in your Apple ID settings.")
                section("7. Brokerage Connections",
                    "The App may allow you to connect third-party brokerage accounts via SnapTrade. SnapTrade supplies holdings, transactions and related account information you authorise. Your connection is governed by the provider’s terms. You can disconnect it in Stock Tracker.")
                section("8. Intellectual Property",
                    "All content, design, and code within the App are the property of the developer. You may not copy, modify, distribute, or reverse-engineer any part of the App.")
                section("9. Consumer rights",
                    "Your rights and remedies under applicable law, including the Australian Consumer Law, continue to apply.")
                section("10. Changes to Terms",
                    "We may modify these terms at any time. Continued use of the App after changes constitutes acceptance of the updated terms.")
            }
            .padding(DS.Space.gutter)
        }
        .dsScreenBackground()
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        LegalSection(title: title, text: body)
    }
}

// MARK: - Built-in Privacy Policy

struct BuiltInPrivacyPolicyView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Last updated November 2026")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                LegalSection(title: "Account and device records",
                    text: "Your account uses an email address and account identifier. Your iPhone stores settings and portfolio records. Sign-in enables selected listed-portfolio and watchlist sync. Supabase hosts account and synced records in Australia. In the web workspace, cookies keep you signed in and browser storage saves preferences.")
                LegalSection(title: "Private Markets",
                    text: "Manual holdings, valuations, cash flows and saved AngelList statements stay on this iPhone. AngelList receives the requests you authorise and the app stores its connection token in Keychain. When you use cloud features, Stock Tracker stores your selected company IDs, monitoring preferences, saved research and any excerpts you choose to save. Approved partners can report your jurisdiction, investor status, application, holding and activity records. The provider handles identity documents and payments.")
                LegalSection(title: "Research and AI",
                    text: "When you request AI research, the AI service receives your question and relevant selected evidence. A separate setting lets you share listed-portfolio context with the assistant. Stock Tracker extracts PDF or text excerpts on your device, saves the reviewed excerpt encrypted after you confirm permission, and asks for separate permission before sending selected private excerpts to an approved AI service. If you turn on daily Private Markets summaries, the AI service receives published company information selected from your tracked companies.")
                LegalSection(title: "Services and overseas processing",
                    text: "We send symbols, search text and currency codes to the services that supply market data. SnapTrade handles the broker connections you authorise. Apple handles subscriptions, optional speech recognition and push delivery. AI, advertising, brokerage and market-data services can process information outside Australia, including in the United States. See Privacy & data in Settings for service links.")
                LegalSection(title: "Advertising & Tracking",
                    text: "When ads are enabled on the Free plan, Google AdMob can use device, approximate location, interaction and diagnostic data to deliver and measure them. Tracking requires your permission. You can change it in iPhone Settings under Privacy & Security, then Tracking.")
                LegalSection(title: "Notifications and permissions",
                    text: "You choose which alerts and summaries to enable. When remote Private Markets notifications are available and enabled, Stock Tracker stores an encrypted device token for delivery. Voice search uses Apple speech recognition when you grant access. Face ID for app lock is optional and Stock Tracker receives the authentication result.")
                LegalSection(title: "Access, correction and deletion",
                    text: "Use Settings → Account to export your account data, including synced portfolio and Private Markets records. The Portfolio tab also offers separate exports for selected listed records. The app also offers Delete Account for signed-in users. Deletion removes active account records and clears this account’s app data on this iPhone. Files you exported, records held by external providers and Apple subscriptions are managed separately.")
                LegalSection(title: "Children’s privacy",
                    text: "Stock Tracker is intended for people aged 13 and older.")
                LegalSection(title: "Privacy questions and complaints",
                    text: "Use App Support on the Stock Tracker App Store listing to ask for access or correction, request a copy of this policy or raise a privacy complaint. Describe what happened and how we can respond. We may verify your identity and will respond through the contact details you provide.")
                if let policyURL {
                    Link("Read the privacy policy online", destination: policyURL)
                        .accessibilityIdentifier("settings.privacyPolicy.online")
                }
            }
            .padding(DS.Space.gutter)
        }
        .dsScreenBackground()
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var policyURL: URL? {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "StockTrackerPrivacyPolicyURL") as? String,
              let url = URL(string: address), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

private struct LegalSection: View {
    let title: String
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
