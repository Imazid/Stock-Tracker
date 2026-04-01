//
//  Stock_TrackerApp.swift
//  Stock Tracker
//

import OSLog
import SwiftUI
import LocalAuthentication
import Combine
import AppTrackingTransparency

@main
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

    // Widget deep link routing state
    @State private var widgetSelectedTab: MainTab = .home
    @State private var widgetShowPaywall: Bool = false
    @State private var widgetAssetSymbol: String? = nil

    @State private var isLaunching = true
    @State private var showOnboarding = false
    @Environment(\.colorScheme) private var systemColorScheme

    private var resolvedTheme: Theme {
        let scheme = themeManager.resolvedColorScheme ?? systemColorScheme
        return Theme(
            colorScheme: scheme,
            colorblindMode: themeManager.colorblindMode,
            highContrast: themeManager.highContrastEnabled
        )
    }

    init() {
        let manager = SubscriptionManager.shared
        _subscriptionManager = StateObject(wrappedValue: manager)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)

        // Must be called once before any ad is loaded (see AdMobInitializer).
        AdMobInitializer.start()
    }
    

    
    var body: some Scene {
        WindowGroup {
            ZStack {
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
            .environment(\.theme, resolvedTheme)
            .onAppear {
                // Restore Supabase session so user stays signed in across launches
                supabaseAuthManager.restoreSessionIfNeeded()

                // Check downgrade limits after data loads
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    subscriptionManager.checkDowngradeLimits(
                        watchlistCount: marketData.watchlist.count,
                        portfolioCount: marketData.portfolio.count
                    )
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    motionSafeWithAnimation(.easeOut(duration: 0.6)) {
                        isLaunching = false
                    }
                }
                // Request ATT consent for personalized ads (must happen before first ad load on iOS 14.5+)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    ATTrackingManager.requestTrackingAuthorization { _ in }
                }
                // Load onboarding stocks and portfolio if any
                loadOnboardingStocks()
                loadOnboardingPortfolio()
            }
            // SECURITY: Screenshot protection - blur when entering background
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
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
                    Task {
                        await syncManager.syncOnSignIn(
                            marketData: marketData,
                            alertManager: alertManager
                        )
                        await mfaManager.checkMFAStatus()
                    }
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
            .preferredColorScheme(themeManager.resolvedColorScheme)
            // MARK: - Widget Deep Link Handler
            // Handles stocktracker:// URLs tapped from any widget.
            // Scheme registered in Info.plist as a URL Type with identifier "stocktracker".
            .onOpenURL { url in
                handleWidgetDeepLink(url)
            }
            .sheet(isPresented: $widgetShowPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Premium Widgets")
            }
        }
    }

    /// Routes widget tap URLs to the appropriate tab or sheet.
    private func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "stocktracker" else { return }
        switch url.host {
        case "portfolio":
            widgetSelectedTab = .portfolio
        case "watchlist":
            widgetSelectedTab = .watchlist
        case "home":
            widgetSelectedTab = .home
        case "paywall":
            widgetShowPaywall = true
        case "asset":
            // stocktracker://asset/{SYMBOL} — navigate to watchlist and surface the detail.
            let symbol = url.pathComponents.dropFirst().first ?? ""
            if !symbol.isEmpty {
                widgetAssetSymbol = symbol
                widgetSelectedTab = .watchlist
            }
        case "news":
            widgetSelectedTab = .news
        case "calendar":
            // Calendar events surface through the news tab (no dedicated calendar tab).
            widgetSelectedTab = .news
        case "trade":
            // stocktracker://trade/{SYMBOL} — open watchlist with the symbol selected.
            let symbol = url.pathComponents.dropFirst().first ?? ""
            if !symbol.isEmpty {
                widgetAssetSymbol = symbol
                widgetSelectedTab = .watchlist
            }
        default:
            break
        }
    }
    
    
    
    
    private func loadOnboardingStocks() {
        guard let stocks = UserDefaults.standard.array(forKey: "onboarding_stocks") as? [String],
              !stocks.isEmpty else { return }

        // Clear immediately so stocks aren't re-added on every launch
        UserDefaults.standard.removeObject(forKey: "onboarding_stocks")

        for symbol in stocks {
            Task {
                do {
                    let asset = try await APIService.shared.fetchAssetDetails(
                        identifier: symbol,
                        kind: .stock,
                        name: symbol
                    )
                    await MainActor.run {
                        marketData.addToWatchlist(asset)
                    }
                } catch {
                    AppLogger.api.error("Failed to load onboarding stock \(symbol): \(error)")
                }
            }
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
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var theme

    var body: some View {
        let localTheme = Theme(colorScheme: colorScheme)
        ZStack {
            localTheme.background.ignoresSafeArea()

            VStack(spacing: 40) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 100))
                    .foregroundColor(theme.accentColor)
                    .accessibilityHidden(true)

                Text("Stock Tracker")
                    .font(.largeTitle.bold())
                    .foregroundColor(localTheme.primaryText)

                Text("Use Face ID to securely access your portfolio")
                    .font(.title3)
                    .foregroundColor(localTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button("Unlock with Face ID") {
                    authManager.authenticate()
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
                .background(theme.accentColor)
                .cornerRadius(20)
                .shadow(color: theme.accentColor.opacity(0.6), radius: 20, y: 10)
                .accessibilityHint("Authenticates using biometrics to unlock the app")

                if let error = authManager.errorMessage {
                    Text(error)
                        .foregroundColor(theme.negativeColor)
                        .font(.subheadline)
                        .padding()
                        .accessibilityLabel("Authentication error: \(error)")
                }
            }
        }
        .onAppear {
            if authManager.useBiometrics {
                authManager.authenticate()
            } else {
                authManager.isAuthenticated = true
            }
        }
    }
}

#Preview {
    LockedView()
        .environmentObject(AuthManager())
        .preferredColorScheme(.dark)
}
