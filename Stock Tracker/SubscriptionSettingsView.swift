//
//  SubscriptionSettingsView.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 14/12/2025.
//


//
//  SubscriptionSettingsView.swift
//  Stock Tracker
//

import SwiftUI

struct SubscriptionSettingsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @State private var showPaywall = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Current Plan Card
                        currentPlanCard
                            .padding(.horizontal)
                            .padding(.top, 20)
                        
                        // Usage Stats
                        if subscriptionManager.currentTier == .free {
                            usageStatsSection
                                .padding(.horizontal)
                        }
                        
                        // Feature Comparison
                        featureComparisonSection
                            .padding(.horizontal)
                        
                        // Upgrade Button
                        if subscriptionManager.currentTier != .max {
                            upgradeButton
                                .padding(.horizontal)
                        }
                        
                        // Manage Subscription
                        if subscriptionManager.currentTier != .free {
                            manageSubscriptionSection
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showPaywall) {
                PaywallView(
                    requiredTier: subscriptionManager.currentTier == .free ? .pro : .max,
                    featureName: "Unlock Premium Features"
                )
            }
        }
    }
    
    // MARK: - Current Plan Card
    private var currentPlanCard: some View {
        VStack(spacing: 20) {
            HStack {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: subscriptionManager.currentTier.gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: subscriptionManager.currentTier.icon)
                        .font(.title)
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(subscriptionManager.currentTier.displayName)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    if subscriptionManager.currentTier != .free {
                        Text("Active Subscription")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    } else {
                        Text("Limited Features")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                Spacer()
            }
            
            if let expirationDate = subscriptionManager.expirationDate {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Renews On")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                        Text(expirationDate, style: .date)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            subscriptionManager.currentTier.color.opacity(0.2),
                            subscriptionManager.currentTier.color.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(subscriptionManager.currentTier.color.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Usage Stats
    private var usageStatsSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Usage Limits")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            
            VStack(spacing: 12) {
                UsageLimitRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Watchlist Assets",
                    current: 7,
                    limit: 10,
                    color: .blue
                )
                
                UsageLimitRow(
                    icon: "bell.fill",
                    title: "Price Alerts",
                    current: 2,
                    limit: 3,
                    color: .purple
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }
    
    // MARK: - Feature Comparison
    private var featureComparisonSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Feature Comparison")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            
            VStack(spacing: 0) {
                FeatureRow(feature: "Watchlist Assets", free: "10", pro: "Unlimited", max: "Unlimited")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "Portfolio Tracking", free: "✗", pro: "✓", max: "✓")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "Price Alerts", free: "3", pro: "Unlimited", max: "Unlimited")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "Technical Analysis", free: "✗", pro: "✓", max: "✓")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "AI Insights", free: "✗", pro: "✗", max: "✓")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "Ad-Free", free: "✗", pro: "✓", max: "✓")
                Divider().background(Color.white.opacity(0.1))
                
                FeatureRow(feature: "Export Reports", free: "✗", pro: "✓", max: "✓")
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }
    
    // MARK: - Upgrade Button
    private var upgradeButton: some View {
        Button {
            showPaywall = true
        } label: {
            HStack {
                Image(systemName: subscriptionManager.currentTier == .free ? "star.fill" : "crown.fill")
                Text(subscriptionManager.currentTier == .free ? "Upgrade to Pro" : "Upgrade to Max")
                    .font(.headline)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [.white, .white.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(16)
        }
    }
    
    // MARK: - Manage Subscription
    private var manageSubscriptionSection: some View {
        VStack(spacing: 12) {
            Button {
                // Open App Store subscription management
            } label: {
                HStack {
                    Text("Manage Subscription")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                )
            }
            
            Button {
                // Restore purchases
            } label: {
                HStack {
                    Text("Restore Purchases")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
    }
}

// MARK: - Usage Limit Row
struct UsageLimitRow: View {
    let icon: String
    let title: String
    let current: Int
    let limit: Int
    let color: Color
    
    private var percentage: Double {
        Double(current) / Double(limit)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("\(current)/\(limit)")
                    .font(.subheadline.bold())
                    .foregroundColor(percentage > 0.8 ? .orange : .white)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * percentage, height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let feature: String
    let free: String
    let pro: String
    let max: String
    
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    var body: some View {
        HStack(spacing: 16) {
            Text(feature)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(free)
                .font(.caption.bold())
                .foregroundColor(subscriptionManager.currentTier == .free ? .white : .white.opacity(0.5))
                .frame(width: 60)
            
            Text(pro)
                .font(.caption.bold())
                .foregroundColor(subscriptionManager.currentTier == .pro ? .blue : .white.opacity(0.5))
                .frame(width: 60)
            
            Text(max)
                .font(.caption.bold())
                .foregroundColor(subscriptionManager.currentTier == .max ? .purple : .white.opacity(0.5))
                .frame(width: 60)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    SubscriptionSettingsView()
        .environmentObject(SubscriptionManager.shared)
        .preferredColorScheme(.dark)
}