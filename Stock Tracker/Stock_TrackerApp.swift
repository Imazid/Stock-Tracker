//
//  Stock_TrackerApp.swift
//  Stock Tracker
//

import OSLog
import SwiftUI
import LocalAuthentication
import Combine
import AppTrackingTransparency
import UserNotifications
import Security
import AppIntents

@main
@MainActor
struct StockCryptoTrackerApp: App {
    @StateObject private var marketData = MarketData()
    @StateObject private var alertManager = PriceAlertManager()
    @StateObject private var subscriptionManager: SubscriptionManager
    @StateObject private var authManager = AuthManager()
    @StateObject private var supabaseAuthManager = SupabaseAuthManager()
    @StateObject private var syncManager = SyncManager.shared
    @StateObject private var mfaManager = MFAManager.shared
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var securityManager = SecurityManager.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var aiInsightService = AIInsightService.shared
    @StateObject private var notificationScheduler = NotificationScheduler.shared
    @StateObject private var referralManager = ReferralManager.shared
    @StateObject private var tradingStore = TradingStore.shared
    @StateObject private var tradingRouter = TradingRouter.shared

    // Widget deep link routing state
    @State private var widgetSelectedTab: MainTab = .home
    @State private var widgetShowPaywall: Bool = false
    /// A stock opened from a widget, quick action or Siri (stocktracker://asset/SYM).
    /// Before, the symbol was stored but nothing presented it — taps only switched tabs.
    @State private var deepLinkAsset: Asset?
    @State private var deepLinkAlerts = false
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var quickActionDelegate

    @State private var isLaunching = true
    @State private var showOnboarding = false

    private let notificationDelegate = NotificationDelegate()

    #if DEBUG
    static let isUITestFreshInstall = ProcessInfo.processInfo.arguments.contains("-UITestFreshInstall")
    #endif

    init() {
        #if DEBUG
        // UI tests start from a true first launch: no saved data, no onboarding flag.
        if Self.isUITestFreshInstall {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            DataPersistenceManager.shared.clearAllData()
            // Including the Supabase SDK's saved session (its own keychain item), or a
            // previous test's account is silently restored and onboarding skips sign-up.
            for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword] {
                SecItemDelete([kSecClass as String: itemClass] as CFDictionary)
            }
            // XCUITest calls the app idle only when its count of UIKit block animations
            // (UIViewAnimationState didStart/didStop) returns to 0. On iOS 27 UIKit sometimes
            // never sends didStop for the springs run as a sheet + keyboard come up, the count
            // sticks above 0, and every later step of that launch waits 60 s (a 4-minute test
            // took 63). With UIKit block animations off, ~98% fewer enter that count (median
            // 1,544 → 19 per launch) and the sheet/keyboard springs that lost their didStop are gone.
            UIView.setAnimationsEnabled(false)
        }
        #endif
        let manager = SubscriptionManager.shared
        _subscriptionManager = StateObject(wrappedValue: manager)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)

        // Must be called once before any ad is loaded (see AdMobInitializer).
        AdMobInitializer.start()

        // Handle foreground notifications and notification tap routing
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }
    

    
    var body: some Scene {
        WindowGroup {
            ZStack {
                if showOnboarding {
                    OnboardingView(onComplete: {
                        // Apply choices now — not on the next cold launch.
                        // They just set up (and proved) the lock on this device — don't lock them out
                        // the moment they finish; it applies from the next open.
                        authManager.useBiometrics = UserDefaults.standard.bool(forKey: "useBiometrics")
                        authManager.isAuthenticated = true
                        OnboardingHandoff.applyPending(to: marketData)
                        withAnimation(.easeInOut(duration: 0.5)) {
                            showOnboarding = false
                        }
                        requestTrackingConsentLater()
                    })
                    .environmentObject(themeManager)
                    .environmentObject(supabaseAuthManager)
                    .environmentObject(networkMonitor)
                    .environmentObject(marketData)
                    .environmentObject(subscriptionManager)
                    .environmentObject(referralManager)
                    .transition(.opacity)

                } else if authManager.isAuthenticated {
                    ContentView(selectedTab: $widgetSelectedTab)
                        .environmentObject(marketData)
                        .environmentObject(alertManager)
                        .environmentObject(subscriptionManager)
                        .environmentObject(authManager)
                        .environmentObject(supabaseAuthManager)
                        .environmentObject(syncManager)
                        .environmentObject(themeManager)
                        .environmentObject(networkMonitor)
                        .environmentObject(mfaManager)
                        .environmentObject(aiInsightService)
                        .environmentObject(notificationScheduler)
                        .environmentObject(referralManager)
                        .environmentObject(tradingStore)
                        .environmentObject(tradingRouter)
                        .fullScreenCover(isPresented: $subscriptionManager.needsKeeperSelection) {
                            TierKeeperSheet()
                                .environmentObject(marketData)
                                .environmentObject(subscriptionManager)
                        }
                } else {
                    LockedView()
                        .environmentObject(authManager)
                        .environmentObject(themeManager)
                }

                // Offline banner — sits above all content
                if !networkMonitor.isConnected {
                    VStack {
                        OfflineBanner()
                        Spacer()
                    }
                    .zIndex(10)
                    .animation(.easeInOut, value: networkMonitor.isConnected)
                }

                if isLaunching {
                    SplashView()
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            .modifier(ThemeEnvironment(themeManager: themeManager))
            .onAppear {
                // Wire external managers into MarketData for price alerts & notifications
                marketData.alertManager = alertManager
                marketData.notificationScheduler = notificationScheduler
                BackgroundRefresh.shared.marketData = marketData
                // Agents and waiting paper orders keep moving while the app is on screen.
                tradingStore.start()
                // Broker syncs import straight into the portfolio.
                SnapTradeViewModel.shared.marketData = marketData
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-SnapTradeBrokerageProbe") {
                    Task { await SnapTradeViewModel.shared.loadDirectory() }   // prints BROKERAGE lines
                }
                #endif
                // Siri/Shortcuts phrases list the stocks you follow ("What's Apple at…").
                StockTrackerShortcuts.updateAppShortcutParameters()
                #if DEBUG
                // `-IntentProbe AAPL`: runs the Siri price intent's code path and prints its answer.
                if let probe = UserDefaults.standard.string(forKey: "IntentProbe") {
                    Task {
                        let suggested = (try? await StockEntityQuery().suggestedEntities().map(\.id)) ?? []
                        let matched = (try? await StockEntityQuery().entities(matching: probe).prefix(3).map(\.id)) ?? []
                        let entity = try? await StockEntityQuery().entities(matching: probe).first
                        var answer: PriceAnswer?
                        if let entity { answer = await PriceAnswer.make(for: entity.asset) }
                        print("INTENTPROBE suggested=\(suggested) matched=\(matched) dialog=\(answer?.dialog ?? "nil")")
                    }
                }
                // `-UITestBackgroundOnly`: run the background-refresh handler once, as iOS would.
                if MarketData.backgroundChecksOnly {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        await BackgroundRefresh.shared.run()
                    }
                }
                #endif

                // Restore Supabase session so user stays signed in across launches
                supabaseAuthManager.restoreSessionIfNeeded()
                #if DEBUG
                // `-UITestSignIn email:password`: signs in at launch (UI tests against a local stack).
                if let pair = UserDefaults.standard.string(forKey: "UITestSignIn"), let split = pair.firstIndex(of: ":") {
                    let email = String(pair[..<split]), password = String(pair[pair.index(after: split)...])
                    Task { await supabaseAuthManager.signIn(email: email, password: password) }
                }
                #endif

                // Check downgrade limits after data loads
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    subscriptionManager.checkDowngradeLimits(
                        watchlistCount: marketData.watchlist.count,
                        portfolioCount: marketData.portfolio.count
                    )
                }

                // Brief brand fade only — content is already loading underneath.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    motionSafeWithAnimation(.easeOut(duration: 0.35)) {
                        isLaunching = false
                    }
                }
                // ATT is asked once the person is in the app — never over the welcome screen.
                if !showOnboarding { requestTrackingConsentLater() }
                // Finish adding any onboarding picks that couldn't load last time (e.g. offline).
                OnboardingHandoff.applyPending(to: marketData)
                loadOnboardingPortfolio()
            }
            // SECURITY: Screenshot protection - blur when entering background
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                BackgroundRefresh.shared.schedule()
                StockTrackerShortcuts.updateAppShortcutParameters()
                securityManager.enableScreenshotProtection()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                securityManager.disableScreenshotProtection()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                authManager.reset()
                // Pull latest cloud data when app comes to foreground (throttled internally)
                if supabaseAuthManager.isSignedIn && networkMonitor.isConnected {
                    Task {
                        await syncManager.pullAndRefresh(
                            marketData: marketData,
                            alertManager: alertManager
                        )
                    }
                }
            }
            // When the user signs in to Supabase, run the first-sync merge
            .onReceive(supabaseAuthManager.$authState) { state in
                if case .signedIn = state {
                    // Practice money and agents move to the account, where agents keep
                    // running while the app is closed (if its trading server answers).
                    Task { await tradingStore.useAccount() }
                    Task {
                        await syncManager.syncOnSignIn(
                            marketData: marketData,
                            alertManager: alertManager
                        )
                        await mfaManager.checkMFAStatus()
                        await referralManager.consumePendingReferralCode()
                        await referralManager.loadCode()
                    }
                } else if case .signedOut = state {
                    tradingStore.useDevice()
                    marketData.reloadFromDisk()
                    syncManager.resetInitialSyncFlag()
                }
            }
            // SECURITY: Jailbreak warning
            .alert("Security Warning", isPresented: $securityManager.showJailbreakWarning) {
                Button("I Understand the Risks", role: .destructive) {
                    securityManager.showJailbreakWarning = false
                }
            } message: {
                Text("This device appears to be jailbroken. Your financial data may be at risk. We recommend using a non-jailbroken device for financial applications.")
            }
            .onAppear {
                if securityManager.isDeviceCompromised {
                    securityManager.showJailbreakWarning = true
                }
            }
            // Onboarding is dark by design; otherwise the person's choice (nil = follow the device).
            .preferredColorScheme(showOnboarding ? .dark : themeManager.resolvedColorScheme)
            // MARK: - Widget Deep Link Handler
            // Handles stocktracker:// URLs tapped from any widget.
            // Scheme registered in Info.plist as a URL Type with identifier "stocktracker".
            .onOpenURL { url in
                handleWidgetDeepLink(url)
            }
            // MARK: - Universal Link Handler (Referral URLs)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                handleUniversalLink(activity)
            }
            .sheet(isPresented: $widgetShowPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Premium Widgets")
            }
            .sheet(item: $deepLinkAsset) { asset in
                AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
                    .environmentObject(marketData)
                    .environmentObject(alertManager)
                    .environmentObject(subscriptionManager)
                    .environmentObject(aiInsightService)
                    .environmentObject(tradingStore)
                    .environmentObject(tradingRouter)
                    .modifier(ThemeEnvironment(themeManager: themeManager))
            }
            .sheet(isPresented: $deepLinkAlerts) {
                PriceAlertsView()
                    .environmentObject(marketData)
                    .environmentObject(alertManager)
                    .environmentObject(subscriptionManager)
                    .modifier(ThemeEnvironment(themeManager: themeManager))
            }
            .onReceive(QuickActionRouter.shared.$pending.compactMap { $0 }) { url in
                QuickActionRouter.shared.pending = nil
                handleWidgetDeepLink(url)
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.shared.run()
        }
    }

    /// Routes widget tap URLs to the appropriate tab or sheet.
    private func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "stocktracker" else { return }
        switch url.host {
        case "portfolio":
            widgetSelectedTab = .portfolio
        case "watchlist":
            tradingRouter.marketsSection = .watchlist
            widgetSelectedTab = .markets
        case "agents":
            widgetSelectedTab = .agents
        case "activity":
            widgetSelectedTab = .activity
        case "home":
            widgetSelectedTab = .home
        case "paywall":
            widgetShowPaywall = true
        case "asset":
            // stocktracker://asset/{SYMBOL} — open that stock's page.
            openStock(url.pathComponents.dropFirst().first ?? "")
        case "search":
            tradingRouter.marketsSection = .search
            widgetSelectedTab = .markets
        case "alerts":
            if canPresentFromDeepLink { deepLinkAlerts = true }
        case "news":
            tradingRouter.marketsSection = .news
            widgetSelectedTab = .markets
        case "calendar":
            // Calendar events surface through the news section (no dedicated calendar tab).
            tradingRouter.marketsSection = .news
            widgetSelectedTab = .markets
        case "trade":
            // stocktracker://trade/{SYMBOL} — the app doesn't trade; open the stock's page.
            openStock(url.pathComponents.dropFirst().first ?? "")
        case "referral":
            // stocktracker://referral/{CODE} — capture referral code.
            let code = url.pathComponents.dropFirst().first ?? ""
            if !code.isEmpty {
                DataPersistenceManager.shared.savePendingReferralCode(code)
                if supabaseAuthManager.isSignedIn {
                    Task { await referralManager.consumePendingReferralCode() }
                }
            }
        default:
            break
        }
    }

    /// Sheets from deep links only once the person is in the app (not over onboarding or the lock).
    private var canPresentFromDeepLink: Bool { !showOnboarding && authManager.isAuthenticated }

    private func openStock(_ rawSymbol: String) {
        let symbol = (rawSymbol.removingPercentEncoding ?? rawSymbol).uppercased()
        guard !symbol.isEmpty, canPresentFromDeepLink else { return }
        let known = marketData.watchlist + marketData.portfolio.map(\.asset) + marketData.alertOnlyAssets
        if let asset = known.first(where: { $0.symbol.uppercased() == symbol }) {
            deepLinkAsset = asset
            return
        }
        // Not tracked: a coin the app can price is crypto, "XXX.AX" is ASX, else a US stock.
        let isCoin = SymbolSearchModel.supportedCoins.contains { $0.symbol == symbol }
        let isASX = symbol.hasSuffix(".AX")
        deepLinkAsset = Asset(symbol: isASX ? String(symbol.dropLast(3)) : symbol, name: symbol,
                              price: 0, change: 0, changePercent: 0, volume: 0,
                              kind: isCoin ? .crypto : .stock, exchange: isASX ? "ASX" : "")
    }

    /// Handles Universal Links for referral URLs (e.g. https://join.yourdomain.com/r/CODE).
    private func handleUniversalLink(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL,
              let host = url.host,
              host.contains("join."),
              url.pathComponents.count >= 3,
              url.pathComponents[1] == "r"
        else { return }

        let code = url.pathComponents[2]
        AppLogger.referral.info("Universal link received with referral code: \(code)")
        DataPersistenceManager.shared.savePendingReferralCode(code)

        if supabaseAuthManager.isSignedIn {
            Task { await referralManager.consumePendingReferralCode() }
        }
    }

    /// Ads personalisation consent (iOS 14.5+). The system shows it at most once.
    private func requestTrackingConsentLater() {
        #if DEBUG
        if Self.isUITestFreshInstall { return }
        #endif
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            ATTrackingManager.requestTrackingAuthorization { _ in }
        }
    }

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

}

// MARK: - Auth Manager (with working toggle support)
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var errorMessage: String?
    @Published var useBiometrics: Bool = UserDefaults.standard.bool(forKey: "useBiometrics") {
        didSet {
            UserDefaults.standard.set(useBiometrics, forKey: "useBiometrics")
        }
    }
    
    init() {
        // Default to true if no saved value
        if UserDefaults.standard.object(forKey: "useBiometrics") == nil {
            self.useBiometrics = true
        }
    }
    
    func authenticate() {
        // Skip biometrics if user turned it off
        guard useBiometrics else {
            DispatchQueue.main.async {
                self.isAuthenticated = true
                self.errorMessage = nil
            }
            return
        }
        
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let reason = "Unlock Stock Tracker to view your portfolio"
            
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    self.isAuthenticated = success
                    if !success {
                        self.errorMessage = authError?.localizedDescription ?? "Authentication failed"
                    }
                }
            }
        } else {
            // No biometrics available → auto unlock
            DispatchQueue.main.async {
                self.isAuthenticated = true
            }
        }
    }
    
    func reset() {
        // Only lock the app if biometrics are enabled
        if useBiometrics {
            isAuthenticated = false
        }
        // If disabled, stay unlocked when returning from background
    }
}

// MARK: - Locked Screen
struct LockedView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.theme) var theme

    private var biometry: (name: String, symbol: String) {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return ("Touch ID", "touchid")
        case .opticID: return ("Optic ID", "opticid")
        case .faceID:  return ("Face ID", "faceid")
        default:       return ("your passcode", "lock")
        }
    }

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            Spacer()
            Image(systemName: biometry.symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.primaryText)
                .frame(width: 96, height: 96)
                .background(Circle().fill(theme.subtleFill))
                .overlay(Circle().strokeBorder(DS.accent.opacity(0.5), lineWidth: 1))
                .accessibilityHidden(true)

            VStack(spacing: DS.Space.s) {
                Text("Stock Tracker is locked")
                    .font(DS.display(.title))
                    .foregroundStyle(theme.primaryText)
                Text("Unlock with \(biometry.name) to see your portfolio.")
                    .font(.body)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let error = authManager.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Couldn't unlock: \(error)")
            }
            Spacer()

            Button("Unlock") {
                Haptics.tap()
                authManager.authenticate()
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityHint("Unlocks with \(biometry.name)")
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.bottom, DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            if authManager.useBiometrics {
                authManager.authenticate()
            } else {
                authManager.isAuthenticated = true
            }
        }
    }
}

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        // Trading notices open the proposal that needs a decision, or the Activity tab.
        if let route = info["tradingRoute"] as? String {
            let proposalID = (info["proposalID"] as? String).flatMap(UUID.init)
            let orderID = (info["orderID"] as? String).flatMap(UUID.init)
            Task { @MainActor in TradingRouter.shared.open(route: route, proposalID: proposalID, orderID: orderID) }
            handler()
            return
        }
        // Price alerts, big moves and earnings reminders carry their symbol: open its page.
        if let symbol = response.notification.request.content.userInfo["symbol"] as? String,
           let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "stocktracker://asset/\(encoded)") {
            Task { @MainActor in QuickActionRouter.shared.pending = url }
        }
        handler()
    }
}

#Preview {
    LockedView()
        .environmentObject(AuthManager())
        .preferredColorScheme(.dark)
}
