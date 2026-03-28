//
//  PaywallView.swift
//  Stock Tracker
//
//  Comparison-table paywall: shows Free / Pro / Black side by side.
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    let requiredTier: SubscriptionTier
    let featureName: String

    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedPeriod: BillingPeriod = .yearly

    // MARK: - Billing Period

    enum BillingPeriod: String, CaseIterable {
        case monthly = "Monthly"
        case yearly  = "Annual"
    }

    // MARK: - Design Tokens

    private let pageBg  = Color(red: 0.04, green: 0.04, blue: 0.07)
    private let cardBg  = Color(red: 0.10, green: 0.10, blue: 0.14)
    private let border  = Color.white.opacity(0.08)

    private var highlightColor: Color {
        requiredTier == .black
            ? Color(red: 0.85, green: 0.75, blue: 0.45)
            : Color(red: 0.40, green: 0.65, blue: 1.0)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                pageBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        contextHeader
                            .padding(.top, 20)

                        billingToggle
                            .padding(.horizontal, 20)

                        comparisonTable
                            .padding(.horizontal, 12)

                        ctaRow
                            .padding(.horizontal, 20)

                        footer
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 30, height: 30)
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
            }
            .alert("Purchase Failed", isPresented: .constant(subscriptionManager.purchaseError != nil)) {
                Button("OK") { subscriptionManager.purchaseError = nil }
            } message: {
                Text(subscriptionManager.purchaseError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Context Header

    private var contextHeader: some View {
        VStack(spacing: 6) {
            Text(featureName)
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Text("Compare plans and choose the best fit")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: - Billing Toggle

    private var billingToggle: some View {
        HStack(spacing: 0) {
            ForEach(BillingPeriod.allCases, id: \.self) { period in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedPeriod = period
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(period.rawValue)
                            .font(.subheadline.weight(.semibold))
                        if period == .yearly {
                            Text("Save 33%")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                        }
                    }
                    .foregroundColor(selectedPeriod == period ? .white : .white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedPeriod == period ? highlightColor.opacity(0.7) : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(cardBg)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 0.5))
    }

    // MARK: - Comparison Table

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            // Column headers
            tierHeaderRow

            Divider().background(border)

            // Feature rows
            ForEach(Array(featureRows.enumerated()), id: \.offset) { index, row in
                featureComparisonRow(row)
                if index < featureRows.count - 1 {
                    Divider().background(border.opacity(0.5))
                }
            }
        }
        .background(cardBg)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(border, lineWidth: 0.5)
        )
    }

    // MARK: - Tier Header Row

    private var tierHeaderRow: some View {
        HStack(spacing: 0) {
            // Feature label column
            Color.clear.frame(maxWidth: .infinity)

            ForEach([SubscriptionTier.free, .pro, .black], id: \.self) { tier in
                VStack(spacing: 4) {
                    if tier == requiredTier && tier != subscriptionManager.currentTier {
                        Text(tier == .pro ? "Popular" : "Best Value")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(highlightColor)
                            .cornerRadius(4)
                    } else {
                        Color.clear.frame(height: 16)
                    }

                    Text(tier.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(tier == subscriptionManager.currentTier ? highlightColor : .white)

                    Text(priceLabel(for: tier))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    tier == subscriptionManager.currentTier
                        ? RoundedRectangle(cornerRadius: 8)
                            .stroke(highlightColor.opacity(0.4), lineWidth: 1)
                            .padding(2)
                        : nil
                )
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Feature Row

    private func featureComparisonRow(_ row: FeatureComparisonRow) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)

            cellView(row.free)
                .frame(maxWidth: .infinity)
            cellView(row.pro)
                .frame(maxWidth: .infinity)
            cellView(row.black)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func cellView(_ value: CellValue) -> some View {
        switch value {
        case .text(let str):
            Text(str)
                .font(.caption.weight(.medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .check:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundColor(.green)
        case .dash:
            Image(systemName: "minus")
                .font(.caption.weight(.bold))
                .foregroundColor(.white.opacity(0.2))
        }
    }

    // MARK: - CTA Row

    private var ctaRow: some View {
        HStack(spacing: 12) {
            ForEach([SubscriptionTier.free, .pro, .black], id: \.self) { tier in
                if tier == subscriptionManager.currentTier {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                } else if tier == .free {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 40)
                } else {
                    Button {
                        purchaseTier(tier)
                    } label: {
                        HStack(spacing: 4) {
                            if subscriptionManager.isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text("Subscribe")
                                    .font(.caption.weight(.bold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            tier == requiredTier
                                ? highlightColor
                                : Color.white.opacity(0.15)
                        )
                        .cornerRadius(10)
                    }
                    .disabled(subscriptionManager.isPurchasing)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                Button("Restore Purchases") {
                    Task { await subscriptionManager.restorePurchases() }
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))

                Button("Terms & Privacy") { }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    // MARK: - Data

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

    private var featureRows: [FeatureComparisonRow] {
        [
            FeatureComparisonRow(label: "Watchlist items",       free: .text("10"),     pro: .text("50"),     black: .text("Unlimited")),
            FeatureComparisonRow(label: "Portfolio holdings",    free: .text("4"),      pro: .text("25"),     black: .text("Unlimited")),
            FeatureComparisonRow(label: "Price alerts",          free: .text("1"),      pro: .text("25"),     black: .text("Unlimited")),
            FeatureComparisonRow(label: "Auto-refresh",          free: .text("Manual"), pro: .text("60s"),    black: .text("5–30s")),
            FeatureComparisonRow(label: "Chart timeframes",      free: .text("3"),      pro: .text("All"),    black: .text("All")),
            FeatureComparisonRow(label: "AI insights",           free: .dash,           pro: .text("20/day"), black: .text("Unlimited")),
            FeatureComparisonRow(label: "Benchmark vs S&P 500", free: .dash,           pro: .dash,           black: .check),
            FeatureComparisonRow(label: "Ad-free",               free: .dash,           pro: .check,          black: .check),
            FeatureComparisonRow(label: "Cloud sync",            free: .text("Watchlist"), pro: .text("All"), black: .text("All")),
            FeatureComparisonRow(label: "Multiple watchlists",   free: .text("1"),      pro: .text("2"),      black: .text("Unlimited")),
        ]
    }

    // MARK: - Helpers

    private func priceLabel(for tier: SubscriptionTier) -> String {
        guard let plan = SubscriptionPlan.plans.first(where: { $0.tier == tier }) else { return "" }
        if tier == .free { return "Free" }
        if selectedPeriod == .yearly {
            return String(format: "$%.2f/mo", plan.yearlyPrice / 12)
        }
        return String(format: "$%.2f/mo", plan.monthlyPrice)
    }

    private func purchaseTier(_ tier: SubscriptionTier) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let isMonthly = selectedPeriod == .monthly
        let productID: String
        switch tier {
        case .pro:
            productID = isMonthly ? SubscriptionManager.ProductID.proMonthly : SubscriptionManager.ProductID.proYearly
        case .black:
            productID = isMonthly ? SubscriptionManager.ProductID.blackMonthly : SubscriptionManager.ProductID.blackYearly
        case .free:
            return
        }
        guard let product = subscriptionManager.products.first(where: { $0.id == productID }) else { return }
        Task { await subscriptionManager.purchase(product) }
    }
}

// MARK: - Legacy FeatureRow (kept for compatibility if referenced elsewhere)

struct FeatureRow: View {
    let feature: (String, Bool, Bool, Bool)
    let animate: Bool
    let delay: Double

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 0) {
            Text(feature.0)
                .font(.subheadline)
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            checkmark(enabled: feature.1, color: theme.secondaryText).frame(width: 44)
            checkmark(enabled: feature.2, color: SubscriptionTier.pro.color).frame(width: 44)
            checkmark(enabled: feature.3, color: theme.primaryText).frame(width: 44)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 20)
        .onAppear {
            if animate && !reduceMotion {
                withAnimation(.easeOut(duration: 0.4).delay(delay)) { appeared = true }
            } else {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func checkmark(enabled: Bool, color: Color) -> some View {
        if enabled {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
        } else {
            Image(systemName: "minus")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color.secondary.opacity(0.3))
        }
    }
}

#Preview("Pro Tier") {
    PaywallView(requiredTier: .pro, featureName: "Advanced Analytics")
        .environmentObject(SubscriptionManager.shared)
}

#Preview("Black Tier") {
    PaywallView(requiredTier: .black, featureName: "AI Insights")
        .environmentObject(SubscriptionManager.shared)
}
