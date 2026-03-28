//
//  SubscriptionManager.swift
//  Stock Tracker
//

import Foundation
import OSLog
import SwiftUI
import Combine
import StoreKit

// MARK: - Subscription Tier
enum SubscriptionTier: String, Codable, CaseIterable {
    case free = "Free"
    case pro = "Pro"
    case black = "Black"

    /// Numeric rank used for tier comparisons (avoids fragile string comparison).
    var rank: Int {
        switch self {
        case .free: return 0
        case .pro: return 1
        case .black: return 2
        }
    }

    var displayName: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .free: return "star"
        case .pro: return "star.fill"
        case .black: return "crown.fill"
        }
    }

    var color: Color {
        switch self {
        case .free: return .gray
        case .pro: return .blue
        case .black: return Color.black
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .free: return [.gray.opacity(0.6), .gray.opacity(0.3)]
        case .pro: return [.blue, .cyan]
        case .black: return [Color(white: 0.15), Color.black]
        }
    }

    // Feature limits — source of truth is FeatureGate; these are convenience shims.

    var maxWatchlistAssets: Int? { FeatureGate.maxWatchlistAssets(for: self) }

    var maxPriceAlerts: Int? { FeatureGate.maxAlerts(for: self) }

    var hasPortfolioBenchmark: Bool {
        switch self {
        case .free, .pro: return false
        case .black: return true
        }
    }

    var maxPortfolioHoldings: Int? { FeatureGate.maxPortfolioHoldings(for: self) }

    var hasPortfolioAccess: Bool { true }

    /// Maximum number of watchlist groups allowed. nil = unlimited.
    var watchlistLimit: Int? { FeatureGate.maxWatchlists(for: self) }

    /// Maximum number of portfolio groups allowed. nil = unlimited.
    var portfolioGroupLimit: Int? { FeatureGate.maxPortfolios(for: self) }

    /// Auto-refresh interval in seconds. nil = manual only (free tier).
    var autoRefreshInterval: TimeInterval? { FeatureGate.autoRefreshInterval(for: self) }

    var canAddWatchlist: Bool {
        switch self {
        case .free: return false
        case .pro, .black: return true
        }
    }

    var hasAdvancedStats: Bool {
        switch self {
        case .free: return false
        case .pro, .black: return true
        }
    }

    var hasTechnicalAnalysis: Bool {
        switch self {
        case .free: return false
        case .pro, .black: return true
        }
    }

    var hasAIInsights: Bool {
        switch self {
        case .free, .pro: return false
        case .black: return true
        }
    }

    var availableTimeRanges: [TimeRange] {
        switch self {
        case .free: return [.oneDay, .oneWeek, .oneMonth]
        case .pro, .black: return TimeRange.allCases
        }
    }

    var isAdFree: Bool {
        switch self {
        case .free: return false
        case .pro, .black: return true
        }
    }
}

// MARK: - Subscription Manager
@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Published State
    @Published var currentTier: SubscriptionTier = .free
    @Published var isSubscriptionActive: Bool = false
    @Published var expirationDate: Date?
    @Published var products: [Product] = []
    @Published var isPurchasing: Bool = false
    @Published var purchaseError: String?
    @Published var needsKeeperSelection: Bool = false

    private static let previousTierKey = "com.stocktracker.previousTier"
    private static let keeperDismissedKey = "com.stocktracker.keeperDismissed"

    // MARK: - Product IDs
    // Configure these in App Store Connect → your app → Subscriptions
    enum ProductID {
        static let proMonthly = "com.stocktracker.subscription.pro.monthly"
        static let proYearly  = "com.stocktracker.subscription.pro.yearly"
        static let blackMonthly = "com.stocktracker.subscription.max.monthly"
        static let blackYearly  = "com.stocktracker.subscription.max.yearly"

        static let all: Set<String> = [proMonthly, proYearly, blackMonthly, blackYearly]
    }

    // MARK: - Receipt Validation
    //
    // Settable so previews / tests can inject a mock validator without subclassing.
    // Defaults to ChainedReceiptValidator (server → local fallback).
    var receiptValidator: any ReceiptValidatorProtocol = ChainedReceiptValidator()

    private var transactionUpdateTask: Task<Void, Never>?

    private init() {
        // Start listening for StoreKit transaction updates
        transactionUpdateTask = observeTransactionUpdates()

        Task {
            await loadProducts()
            await restoreEntitlements()
        }
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: ProductID.all)
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            AppLogger.store.error("StoreKit: failed to load products — \(error)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await updateTierFromTransaction(transaction)
                await transaction.finish()

            case .userCancelled:
                break

            case .pending:
                purchaseError = "Purchase is pending approval (e.g. Ask to Buy)."

            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }

        await restoreEntitlements()
    }

    // MARK: - Entitlement Check

    /// Rebuilds subscription tier from current StoreKit entitlements.
    func restoreEntitlements() async {
        var highestTier: SubscriptionTier = .free

        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            let tier = tier(for: transaction.productID)
            if tier.rank > highestTier.rank {
                highestTier = tier
            }
        }

        setSubscription(tier: highestTier)
    }

    // MARK: - Internal Helpers

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in StoreKit.Transaction.updates {
                guard let transaction = try? checkVerified(result) else { continue }
                await updateTierFromTransaction(transaction)
                await transaction.finish()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    private func updateTierFromTransaction(_ transaction: StoreKit.Transaction) async {
        if transaction.revocationDate != nil {
            // Subscription was refunded or revoked by Apple — rebuild from all entitlements
            await restoreEntitlements()
            return
        }

        // Run through the receipt validator (server-side if configured, local fallback otherwise)
        let result = await receiptValidator.validate(
            transactionID: transaction.id,
            productID: transaction.productID
        )

        switch result {
        case .valid(let tier, let expiresAt):
            setSubscription(tier: tier)
            if let expiresAt {
                expirationDate = expiresAt
            }
        case .invalid:
            // Transaction explicitly rejected — downgrade. Log prominently.
            AppLogger.store.warning(
                "Transaction \(transaction.id) rejected by receipt validator — downgrading to free"
            )
            setSubscription(tier: .free)
        case .networkError(let reason):
            // Transient error — preserve current tier, do not downgrade.
            AppLogger.store.error(
                "Receipt validation network error for tx \(transaction.id): \(reason) — keeping current tier"
            )
        }
    }

    private func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case ProductID.blackMonthly, ProductID.blackYearly:
            return .black
        case ProductID.proMonthly, ProductID.proYearly:
            return .pro
        default:
            return .free
        }
    }

    func setSubscription(tier: SubscriptionTier) {
        let previousTierRaw = UserDefaults.standard.string(forKey: Self.previousTierKey) ?? SubscriptionTier.free.rawValue
        let previousTier = SubscriptionTier(rawValue: previousTierRaw) ?? .free

        currentTier = tier
        isSubscriptionActive = tier != .free

        if tier != .free {
            expirationDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())
        } else {
            expirationDate = nil
        }

        // Detect downgrade
        if tier.rank < previousTier.rank {
            let dismissed = UserDefaults.standard.bool(forKey: Self.keeperDismissedKey)
            if !dismissed {
                needsKeeperSelection = true
            }
        }

        UserDefaults.standard.set(tier.rawValue, forKey: Self.previousTierKey)
    }

    /// Called after user completes keeper selection or when assets are under limits.
    func clearKeeperSelection() {
        needsKeeperSelection = false
        UserDefaults.standard.set(true, forKey: Self.keeperDismissedKey)
    }

    /// Reset the keeper dismissed flag (call when a new downgrade occurs).
    func resetKeeperDismissed() {
        UserDefaults.standard.set(false, forKey: Self.keeperDismissedKey)
    }

    /// Checks whether current watchlist/portfolio counts exceed the tier limits.
    func checkDowngradeLimits(watchlistCount: Int, portfolioCount: Int) {
        let overWatchlist: Bool
        if let wLimit = FeatureGate.maxWatchlistAssets(for: currentTier) {
            overWatchlist = watchlistCount > wLimit
        } else {
            overWatchlist = false
        }

        let overPortfolio: Bool
        if let pLimit = FeatureGate.maxPortfolioHoldings(for: currentTier) {
            overPortfolio = portfolioCount > pLimit
        } else {
            overPortfolio = false
        }

        if overWatchlist || overPortfolio {
            resetKeeperDismissed()
            needsKeeperSelection = true
        } else {
            clearKeeperSelection()
        }
    }
    
    func canAddToWatchlist(currentCount: Int) -> Bool {
        FeatureGate.canAddWatchlistAsset(currentCount: currentCount, tier: currentTier)
    }

    func canAddPriceAlert(currentCount: Int) -> Bool {
        FeatureGate.canAddAlert(currentCount: currentCount, tier: currentTier)
    }

    func canAddPortfolioHolding(currentCount: Int) -> Bool {
        FeatureGate.canAddPortfolioHolding(currentCount: currentCount, tier: currentTier)
    }

    func canAddPortfolio(currentCount: Int) -> Bool {
        FeatureGate.canAddPortfolio(currentCount: currentCount, tier: currentTier)
    }

    func canAddWatchlistGroup(currentCount: Int) -> Bool {
        FeatureGate.canAddWatchlist(currentCount: currentCount, tier: currentTier)
    }
    
    func hasFeatureAccess(feature: Feature) -> Bool {
        switch feature {
        case .portfolio:
            return currentTier.hasPortfolioAccess
        case .advancedStats:
            return currentTier.hasAdvancedStats
        case .technicalAnalysis:
            return currentTier.hasTechnicalAnalysis
        case .aiInsights:
            return currentTier.hasAIInsights
        case .aiAgent:
            return currentTier != .free
        case .allTimeRanges:
            return currentTier != .free
        case .adFree:
            return currentTier.isAdFree
        case .realTimeData:
            return currentTier != .free
        case .exportReports:
            return currentTier != .free
        }
    }
    
    func getRemainingCount(for limit: LimitType, currentCount: Int) -> String {
        switch limit {
        case .watchlist:
            guard let max = FeatureGate.maxWatchlistAssets(for: currentTier) else { return "Unlimited" }
            return "\(currentCount)/\(max)"
        case .portfolio:
            guard let max = FeatureGate.maxPortfolioHoldings(for: currentTier) else { return "Unlimited" }
            return "\(currentCount)/\(max)"
        case .alerts:
            guard let max = FeatureGate.maxAlerts(for: currentTier) else { return "Unlimited" }
            return "\(currentCount)/\(max)"
        }
    }

    enum Feature {
        case portfolio
        case advancedStats
        case technicalAnalysis
        case aiInsights
        case aiAgent          // NEW: For the AI Agent tab
        case allTimeRanges
        case adFree
        case realTimeData
        case exportReports
    }
    
    enum LimitType {
        case watchlist
        case portfolio
        case alerts
    }
}

// MARK: - Subscription Plans
struct SubscriptionPlan: Identifiable {
    let id = UUID()
    let tier: SubscriptionTier
    let monthlyPrice: Double
    let yearlyPrice: Double
    let features: [String]
    let badge: String?
    
    var monthlySavings: Double {
        (monthlyPrice * 12) - yearlyPrice
    }
    
    var yearlySavingsPercentage: Double {
        ((monthlyPrice * 12 - yearlyPrice) / (monthlyPrice * 12)) * 100
    }
    
    static let plans: [SubscriptionPlan] = [
        SubscriptionPlan(
            tier: .free,
            monthlyPrice: 0,
            yearlyPrice: 0,
            features: [
                "Track up to 10 assets",
                "Basic charts (1D, 1W, 1M)",
                "1 price alert",
                "5 news articles/day",
                "Manual refresh only"
            ],
            badge: nil
        ),

        SubscriptionPlan(
            tier: .pro,
            monthlyPrice: 9.99,
            yearlyPrice: 79.99,
            features: [
                "Track up to 50 assets",
                "2 watchlists",
                "Full portfolio tracking",
                "All chart timeframes",
                "25 price alerts",
                "AI Investing Assistant (20/day)",
                "Advanced statistics & technical analysis",
                "60s auto-refresh",
                "20 news articles/day",
                "Export reports",
                "Ad-free experience"
            ],
            badge: "POPULAR"
        ),

        SubscriptionPlan(
            tier: .black,
            monthlyPrice: 19.99,
            yearlyPrice: 159.99,
            features: [
                "Track 500+ assets",
                "5 portfolios, unlimited watchlists",
                "Unlimited AI insights",
                "Unlimited price alerts",
                "30s auto-refresh",
                "Portfolio benchmark vs S&P 500",
                "Unlimited news + Daily Brief",
                "Priority support",
                "Early feature access"
            ],
            badge: "BEST VALUE"
        )
    ]
}

// MARK: - Feature Lock View
struct FeatureLockView: View {
    let featureName: String
    let requiredTier: SubscriptionTier
    @State private var showPaywall = false
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    var body: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundColor(requiredTier.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(featureName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Upgrade to \(requiredTier.displayName)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(white: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(requiredTier.color.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(requiredTier: requiredTier, featureName: featureName)
        }
    }
}
