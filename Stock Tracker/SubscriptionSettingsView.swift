//
//  SubscriptionSettingsView.swift
//  Stock Tracker
//
//  Your plan, the other plans (App Store prices in your currency), manage and restore.
//

import SwiftUI
import StoreKit

struct SubscriptionSettingsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.theme) private var theme

    @State private var paywallTier: PaywallTier?
    @State private var showManage = false
    @State private var restoreMessage: String?

    private struct PaywallTier: Identifiable { let tier: SubscriptionTier; var id: String { tier.rawValue } }

    var body: some View {
        List {
            Section {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: subscriptionManager.currentTier.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(DS.accent.opacity(0.14)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(subscriptionManager.currentTier.displayName) plan")
                            .font(.headline)
                            .foregroundStyle(theme.primaryText)
                        Text(subscriptionManager.currentTier == .free ? "Free forever, with ads" : "Active subscription")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }

            if subscriptionManager.currentTier != .black {
                Section("Upgrade") {
                    ForEach([SubscriptionTier.pro, .black].filter { $0.rank > subscriptionManager.currentTier.rank }, id: \.self) { tier in
                        Button {
                            paywallTier = PaywallTier(tier: tier)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tier.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(theme.primaryText)
                                    Text(fromPrice(for: tier))
                                        .font(.footnote)
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText.opacity(0.6))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("subscription.plan.\(tier.rawValue.lowercased())")
                    }
                }
            }

            Section {
                if subscriptionManager.currentTier != .free {
                    Button("Manage subscription") { showManage = true }
                }
                Button {
                    Task {
                        await subscriptionManager.restorePurchases()
                        restoreMessage = subscriptionManager.currentTier != .free
                            ? "Your subscription is restored."
                            : "No active subscription was found for this Apple ID."
                    }
                } label: {
                    HStack {
                        Text("Restore purchases")
                        Spacer()
                        if subscriptionManager.isPurchasing { ProgressView() }
                    }
                }
                .disabled(subscriptionManager.isPurchasing)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .listRowBackground(theme.subtleFill)
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showManage)
        .task {
            if subscriptionManager.products.isEmpty { await subscriptionManager.loadProducts() }
        }
        .sheet(item: $paywallTier) { item in
            PaywallView(requiredTier: item.tier, featureName: "\(item.tier.displayName) plan")
                .environmentObject(subscriptionManager)
        }
        .alert("Restore purchases", isPresented: Binding(
            get: { restoreMessage != nil },
            set: { if !$0 { restoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    /// "From A$9.99 a month" using App Store prices, or a neutral line if they haven't loaded.
    private func fromPrice(for tier: SubscriptionTier) -> String {
        let id = tier == .pro ? SubscriptionManager.ProductID.proMonthly : SubscriptionManager.ProductID.blackMonthly
        guard let product = subscriptionManager.products.first(where: { $0.id == id }) else {
            return "See plans and prices"
        }
        return "From \(product.displayPrice) a month"
    }
}

#Preview {
    NavigationStack {
        SubscriptionSettingsView()
            .environmentObject(SubscriptionManager.shared)
    }
}
