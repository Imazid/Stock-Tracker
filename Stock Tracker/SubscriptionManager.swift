//
//  SubscriptionManager.swift
//  Stock Tracker
//

import Foundation
import SwiftUI
import Combine

// MARK: - Subscription Tier
enum SubscriptionTier: String, Codable, CaseIterable {
    case free = "Free"
    case pro = "Pro"
    case max = "Max"
    
    var displayName: String {
        rawValue
    }
    
    var icon: String {
        switch self {
        case .free: return "star"
        case .pro: return "star.fill"
        case .max: return "crown.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .free: return .gray
        case .pro: return .blue
        case .max: return .purple
        }
    }
    
    var gradientColors: [Color] {
        switch self {
        case .free: return [.gray.opacity(0.6), .gray.opacity(0.3)]
        case .pro: return [.blue, .cyan]
        case .max: return [.purple, .pink]
        }
    }
    
    // Feature limits
    var maxWatchlistAssets: Int? {
        switch self {
        case .free: return 10
        case .pro, .max: return nil
        }
    }
    
    var maxPriceAlerts: Int? {
        switch self {
        case .free: return 3
        case .pro, .max: return nil
        }
    }
    
    var hasPortfolioAccess: Bool {
        switch self {
        case .free: return false
        case .pro, .max: return true
        }
    }
    
    var hasAdvancedStats: Bool {
        switch self {
        case .free: return false
        case .pro, .max: return true
        }
    }
    
    var hasTechnicalAnalysis: Bool {
        switch self {
        case .free: return false
        case .pro, .max: return true
        }
    }
    
    var hasAIInsights: Bool {
        switch self {
        case .free, .pro: return false
        case .max: return true
        }
    }
    
    var availableTimeRanges: [TimeRange] {
        switch self {
        case .free: return [.oneDay, .oneWeek, .oneMonth]
        case .pro, .max: return TimeRange.allCases
        }
    }
    
    var isAdFree: Bool {
        switch self {
        case .free: return false
        case .pro, .max: return true
        }
    }
}

// MARK: - Subscription Manager
@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var currentTier: SubscriptionTier = .free
    @Published var isSubscriptionActive: Bool = false
    @Published var expirationDate: Date?
    
    private let userDefaultsKey = "user_subscription_tier"
    
    private init() {
        loadSubscription()
    }
    
    func loadSubscription() {
        if let savedTier = UserDefaults.standard.string(forKey: userDefaultsKey),
           let tier = SubscriptionTier(rawValue: savedTier) {
            currentTier = tier
            isSubscriptionActive = tier != .free
        }
    }
    
    func setSubscription(tier: SubscriptionTier) {
        currentTier = tier
        isSubscriptionActive = tier != .free
        UserDefaults.standard.set(tier.rawValue, forKey: userDefaultsKey)
        
        if tier != .free {
            expirationDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())
        } else {
            expirationDate = nil
        }
    }
    
    func canAddToWatchlist(currentCount: Int) -> Bool {
        guard let limit = currentTier.maxWatchlistAssets else { return true }
        return currentCount < limit
    }
    
    func canAddPriceAlert(currentCount: Int) -> Bool {
        guard let limit = currentTier.maxPriceAlerts else { return true }
        return currentCount < limit
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
            guard let max = currentTier.maxWatchlistAssets else { return "Unlimited" }
            return "\(currentCount)/\(max)"
        case .alerts:
            guard let max = currentTier.maxPriceAlerts else { return "Unlimited" }
            return "\(currentCount)/\(max)"
        }
    }
    
    enum Feature {
        case portfolio
        case advancedStats
        case technicalAnalysis
        case aiInsights
        case allTimeRanges
        case adFree
        case realTimeData
        case exportReports
    }
    
    enum LimitType {
        case watchlist
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
                "Basic statistics",
                "3 price alerts",
                "Standard news feed"
            ],
            badge: nil
        ),
        
        SubscriptionPlan(
            tier: .pro,
            monthlyPrice: 9.99,
            yearlyPrice: 79.99,
            features: [
                "Unlimited watchlist",
                "Full portfolio tracking",
                "All chart timeframes",
                "Unlimited price alerts",
                "Advanced statistics",
                "Technical analysis",
                "Real-time data",
                "Export reports",
                "Ad-free experience"
            ],
            badge: "POPULAR"
        ),
        
        SubscriptionPlan(
            tier: .max,
            monthlyPrice: 19.99,
            yearlyPrice: 159.99,
            features: [
                "Everything in Pro",
                "AI-powered insights",
                "Custom alert conditions",
                "Advanced charting tools",
                "Earnings calendar",
                "Analyst ratings",
                "Options data",
                "Priority support",
                "Early feature access"
            ],
            badge: "BEST VALUE"
        )
    ]
}

// MARK: - Paywall View
struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    
    let requiredTier: SubscriptionTier
    let featureName: String
    
    @State private var selectedPeriod: SubscriptionPeriod = .yearly
    @State private var showingPurchase = false
    
    enum SubscriptionPeriod {
        case monthly
        case yearly
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color.purple.opacity(0.2), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 32) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: requiredTier.gradientColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 100, height: 100)
                                    .blur(radius: 30)
                                
                                Image(systemName: requiredTier.icon)
                                    .font(.system(size: 50))
                                    .foregroundColor(.white)
                            }
                            
                            Text("Unlock \(requiredTier.displayName)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text(featureName)
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        
                        HStack(spacing: 16) {
                            PeriodButton(
                                period: .monthly,
                                isSelected: selectedPeriod == .monthly,
                                action: { selectedPeriod = .monthly }
                            )
                            
                            PeriodButton(
                                period: .yearly,
                                isSelected: selectedPeriod == .yearly,
                                action: { selectedPeriod = .yearly }
                            )
                        }
                        .padding(.horizontal)
                        
                        VStack(spacing: 20) {
                            ForEach(SubscriptionPlan.plans.filter { $0.tier != .free }) { plan in
                                SubscriptionCard(
                                    plan: plan,
                                    period: selectedPeriod,
                                    isRecommended: plan.tier == requiredTier
                                )
                            }
                        }
                        .padding(.horizontal)
                        
                        if let plan = SubscriptionPlan.plans.first(where: { $0.tier == requiredTier }) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("What You'll Get")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                
                                ForEach(plan.features, id: \.self) { feature in
                                    HStack(spacing: 12) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text(feature)
                                            .foregroundColor(.white.opacity(0.9))
                                        Spacer()
                                    }
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .padding(.horizontal)
                        }
                        
                        Button {
                            showingPurchase = true
                        } label: {
                            Text("Start Free Trial")
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(
                                        colors: [.white, .white.opacity(0.9)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .cornerRadius(16)
                        }
                        .padding(.horizontal)
                        
                        VStack(spacing: 8) {
                            Text("7-day free trial • Cancel anytime")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                            
                            HStack(spacing: 16) {
                                Button("Terms") {}
                                Button("Privacy") {}
                                Button("Restore") {}
                            }
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
            }
            .alert("Purchase Subscription", isPresented: $showingPurchase) {
                Button("Subscribe to \(requiredTier.displayName)") {
                    subscriptionManager.setSubscription(tier: requiredTier)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is a demo. In production, this would connect to App Store subscriptions.")
            }
        }
    }
}

struct PeriodButton: View {
    let period: PaywallView.SubscriptionPeriod
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(period == .monthly ? "Monthly" : "Yearly")
                    .font(.headline)
                    .foregroundColor(isSelected ? .black : .white)
                
                if period == .yearly {
                    Text("Save 33%")
                        .font(.caption.bold())
                        .foregroundColor(isSelected ? .green : .green.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.white : Color.white.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

struct SubscriptionCard: View {
    let plan: SubscriptionPlan
    let period: PaywallView.SubscriptionPeriod
    let isRecommended: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            if let badge = plan.badge {
                Text(badge)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: plan.tier.gradientColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            
            HStack {
                Image(systemName: plan.tier.icon)
                    .font(.title2)
                    .foregroundColor(plan.tier.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.tier.displayName)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("$\(period == .monthly ? String(format: "%.2f", plan.monthlyPrice) : String(format: "%.2f", plan.yearlyPrice))")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text(period == .monthly ? "/month" : "/year")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                Spacer()
                
                if isRecommended {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    isRecommended
                        ? LinearGradient(
                            colors: [plan.tier.color.opacity(0.2), plan.tier.color.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.05), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            isRecommended ? plan.tier.color.opacity(0.5) : Color.white.opacity(0.1),
                            lineWidth: isRecommended ? 2 : 1
                        )
                )
        )
    }
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
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundColor(requiredTier.color)
                
                Text(featureName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("Upgrade to \(requiredTier.displayName)")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [requiredTier.color.opacity(0.2), requiredTier.color.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(requiredTier.color.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(requiredTier: requiredTier, featureName: featureName)
        }
    }
}
