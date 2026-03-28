//
//  SubscriptionSettingsView.swift
//  Stock Tracker
//

import SwiftUI
import UIKit

struct SubscriptionSettingsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss

    @State private var showPaywall = false
    @State private var selectedTier: SubscriptionTier?
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    var body: some View {
        List {
            // Current Plan
            Section {
                currentPlanCard
            }
            
            // Available Plans
            if subscriptionManager.currentTier != .black {
                Section {
                    ForEach(availablePlans, id: \.tier) { plan in
                        PlanCard(plan: plan) {
                            selectedTier = plan.tier
                            showPaywall = true
                        }
                    }
                } header: {
                    Text("Available Plans")
                }
            }
            
            // Manage
            Section {
                if subscriptionManager.currentTier != .free {
                    Button {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Manage Subscription", systemImage: "app.badge")
                    }
                }

                Button {
                    Task {
                        await subscriptionManager.restorePurchases()
                        restoreMessage = subscriptionManager.currentTier != .free
                            ? "Subscription restored successfully."
                            : "No active subscription found."
                        showRestoreAlert = true
                    }
                } label: {
                    HStack {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                        Spacer()
                        if subscriptionManager.isPurchasing {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                }
                .disabled(subscriptionManager.isPurchasing)
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            if let tier = selectedTier {
                PaywallView(requiredTier: tier, featureName: "Premium Features")
                    .environmentObject(subscriptionManager)
            }
        }
        .alert("Restore Purchases", isPresented: $showRestoreAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
    }
    
    private var currentPlanCard: some View {
        HStack(spacing: 16) {
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
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(subscriptionManager.currentTier.displayName)
                    .font(.title3.bold())
                
                if subscriptionManager.currentTier == .free {
                    Text("Limited features")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("Active subscription")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var availablePlans: [SubscriptionPlan] {
        SubscriptionPlan.plans.filter { $0.tier != subscriptionManager.currentTier }
    }
}

// MARK: - Plan Card
struct PlanCard: View {
    let plan: SubscriptionPlan
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(plan.tier.displayName)
                            .font(.headline)
                        
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(plan.tier.color)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text("From $\(String(format: "%.2f", plan.monthlyPrice))/month")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundColor(plan.tier.color)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SubscriptionSettingsView()
            .environmentObject(SubscriptionManager.shared)
    }
}
