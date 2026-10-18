//
//  PaywallView.swift
//  Stock Tracker
//
//  Plan comparison: Free / Pro / Black side by side. Prices come from the App
//  Store in the person's own currency (never hard-coded), the legal links work,
//  and if the App Store can't be reached it says so instead of a dead button.
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    let requiredTier: SubscriptionTier
    let featureName: String

    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var selectedPeriod: BillingPeriod = .yearly
    @State private var isLoadingProducts = false
    @State private var legal: LegalPage?

    enum BillingPeriod: String, CaseIterable {
        case monthly = "Monthly"
        case yearly = "Yearly"
    }

    private enum LegalPage: String, Identifiable {
        case terms, privacy
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.l) {
                    header
                    billingToggle
                    if subscriptionManager.products.isEmpty { storeUnavailable }
                    comparisonTable
                    ctaRow
                    footer
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("paywall.close")
                }
            }
            .task {
                if subscriptionManager.products.isEmpty { await loadProducts() }
            }
            .alert("Purchase didn't go through", isPresented: Binding(
                get: { subscriptionManager.purchaseError != nil },
                set: { if !$0 { subscriptionManager.purchaseError = nil } }
            )) {
                Button("OK") { subscriptionManager.purchaseError = nil }
            } message: {
                Text(subscriptionManager.purchaseError ?? "")
            }
            .sheet(item: $legal) { page in
                NavigationStack {
                    Group {
                        if page == .terms { BuiltInTermsView() } else { BuiltInPrivacyPolicyView() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { legal = nil } }
                    }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: DS.Space.s) {
            Text(featureName)
                .font(DS.display(.title, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text("\(requiredTier.displayName) unlocks this. Compare plans below.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DS.Space.s)
    }

    private var billingToggle: some View {
        Picker("Billing", selection: $selectedPeriod) {
            Text("Monthly").tag(BillingPeriod.monthly)
            if let saving = yearlySaving(for: requiredTier == .free ? .pro : requiredTier) {
                Text("Yearly · save \(saving)%").tag(BillingPeriod.yearly)
            } else {
                Text("Yearly").tag(BillingPeriod.yearly)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("paywall.period")
    }

    private var storeUnavailable: some View {
        HStack(spacing: DS.Space.m) {
            if isLoadingProducts {
                ProgressView()
                Text("Getting prices from the App Store…")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(theme.warningColor)
                Text("Prices couldn't load from the App Store.")
                    .font(.subheadline)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button { Task { await loadProducts() } } label: {
                    Text("Try again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(padding: DS.Space.m)
        .accessibilityIdentifier("paywall.storeUnavailable")
    }

    // MARK: Table

    private let tiers: [SubscriptionTier] = [.free, .pro, .black]

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(maxWidth: .infinity)
                ForEach(tiers, id: \.self) { tier in
                    VStack(spacing: 3) {
                        Text(tier.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(tier == requiredTier ? DS.accent : theme.primaryText)
                        Text(priceLabel(for: tier))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if tier == subscriptionManager.currentTier {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DS.accent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.m)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .fill(tier == requiredTier ? DS.accent.opacity(0.12) : .clear)
                    )
                }
            }
            Divider().overlay(theme.cardBorder.opacity(0.4))
            ForEach(Array(featureRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, DS.Space.s)
                    cell(row.free)
                    cell(row.pro)
                    cell(row.black)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                if index < featureRows.count - 1 {
                    Divider().overlay(theme.cardBorder.opacity(0.25))
                }
            }
        }
        .dsCard(padding: DS.Space.s)
    }

    @ViewBuilder
    private func cell(_ value: CellValue) -> some View {
        Group {
            switch value {
            case .text(let text):
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            case .check:
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DS.accent)
                    .accessibilityLabel("Included")
            case .dash:
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.secondaryText.opacity(0.4))
                    .accessibilityLabel("Not included")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: CTA

    private var ctaRow: some View {
        VStack(spacing: DS.Space.s) {
            ForEach([SubscriptionTier.pro, .black], id: \.self) { tier in
                if tier == subscriptionManager.currentTier {
                    Text("You're on \(tier.displayName)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 54)
                } else {
                    let product = self.product(for: tier)
                    Button {
                        guard let product else { return }
                        Haptics.tap()
                        Task { await subscriptionManager.purchase(product) }
                    } label: {
                        if subscriptionManager.isPurchasing {
                            ProgressView()
                        } else if let product {
                            Text("Get \(tier.displayName) · \(product.displayPrice)/\(selectedPeriod == .monthly ? "month" : "year")")
                        } else {
                            Text("Get \(tier.displayName)")
                        }
                    }
                    .buttonStyle(tier == requiredTier || (requiredTier == .free && tier == .pro)
                                 ? AnyButtonStyle(PrimaryPillButtonStyle()) : AnyButtonStyle(SecondaryPillButtonStyle()))
                    .disabled(product == nil || subscriptionManager.isPurchasing)
                    .accessibilityIdentifier("paywall.subscribe.\(tier.rawValue.lowercased())")
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: DS.Space.m) {
            Text("Subscriptions renew automatically until cancelled. Cancel at least 24 hours before the end of a period in Settings → your name → Subscriptions.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: DS.Space.l) {
                Button("Restore purchases") {
                    Task { await subscriptionManager.restorePurchases() }
                }
                .accessibilityIdentifier("paywall.restore")
                Button("Terms") { legal = .terms }
                    .accessibilityIdentifier("paywall.terms")
                Button("Privacy") { legal = .privacy }
                    .accessibilityIdentifier("paywall.privacy")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(DS.accent)
            .frame(minHeight: 44)
        }
    }

    // MARK: Data

    private enum CellValue {
        case text(String)
        case check
        case dash
    }

    private struct FeatureComparisonRow {
        let label: String
        let free: CellValue
        let pro: CellValue
        let black: CellValue
    }

    /// Built from FeatureGate / SubscriptionTier so the table always matches what each plan gets.
    private var featureRows: [FeatureComparisonRow] {
        func row(_ label: String, _ value: (SubscriptionTier) -> CellValue) -> FeatureComparisonRow {
            FeatureComparisonRow(label: label, free: value(.free), pro: value(.pro), black: value(.black))
        }
        func limit(_ n: Int?) -> CellValue { n.map { .text("\($0)") } ?? .text("Unlimited") }
        return [
            row("Watchlist items") { limit(FeatureGate.maxWatchlistAssets(for: $0)) },
            row("Watchlists") { limit(FeatureGate.maxWatchlists(for: $0)) },
            row("Portfolio holdings") { limit(FeatureGate.maxPortfolioHoldings(for: $0)) },
            row("Portfolios") { limit(FeatureGate.maxPortfolios(for: $0)) },
            row("Price alerts") { limit(FeatureGate.maxAlerts(for: $0)) },
            row("Auto-refresh") { tier in
                switch tier {
                case .free:  return .text("Manual")
                case .pro:   return .text("\(Int(FeatureGate.autoRefreshInterval(for: .pro) ?? 60)) s")
                case .black:
                    let options = FeatureGate.blackTierRefreshOptions
                    return .text("\(options.min() ?? 5)–\(options.max() ?? 30) s")
                }
            },
            row("AI insights") { tier in
                switch FeatureGate.aiDailyQueryLimit(for: tier) {
                case .some(0):     return .dash
                case .some(let n): return .text("\(n)/day")
                case .none:        return .text("Unlimited")
                }
            },
            row("Benchmark vs S&P 500") { $0.hasPortfolioBenchmark ? .check : .dash },
            row("No ads") { $0.isAdFree ? .check : .dash },
            row("Cloud sync") { $0 == .free ? .text("Watchlists") : .text("Everything") },
        ]
    }

    private func productID(for tier: SubscriptionTier, period: BillingPeriod) -> String? {
        switch (tier, period) {
        case (.pro, .monthly):   return SubscriptionManager.ProductID.proMonthly
        case (.pro, .yearly):    return SubscriptionManager.ProductID.proYearly
        case (.black, .monthly): return SubscriptionManager.ProductID.blackMonthly
        case (.black, .yearly):  return SubscriptionManager.ProductID.blackYearly
        case (.free, _):         return nil
        }
    }

    private func product(for tier: SubscriptionTier, period: BillingPeriod? = nil) -> Product? {
        guard let id = productID(for: tier, period: period ?? selectedPeriod) else { return nil }
        return subscriptionManager.products.first { $0.id == id }
    }

    private func priceLabel(for tier: SubscriptionTier) -> String {
        if tier == .free { return "Free" }
        guard let product = product(for: tier) else { return "—" }
        return "\(product.displayPrice)/\(selectedPeriod == .monthly ? "mo" : "yr")"
    }

    /// Yearly saving vs 12 × monthly, from real App Store prices.
    private func yearlySaving(for tier: SubscriptionTier) -> Int? {
        guard let monthly = product(for: tier, period: .monthly),
              let yearly = product(for: tier, period: .yearly) else { return nil }
        let twelve = monthly.price * 12
        guard twelve > 0 else { return nil }
        let saving = (twelve - yearly.price) / twelve * 100
        let value = NSDecimalNumber(decimal: saving).intValue
        return value > 0 ? value : nil
    }

    private func loadProducts() async {
        isLoadingProducts = true
        await subscriptionManager.loadProducts()
        isLoadingProducts = false
    }
}

#Preview("Pro Tier") {
    PaywallView(requiredTier: .pro, featureName: "Advanced Analytics")
        .environmentObject(SubscriptionManager.shared)
}
