//
//  FeatureGate.swift
//  Stock Tracker
//
//  Single source of truth for all subscription-tier feature caps.
//  Views and services query this type — never hard-code tier checks inline.
//

import Foundation

enum FeatureGate {

    // MARK: - Watchlist / Asset Limits

    /// Maximum assets trackable on the watchlist. nil = unlimited.
    static func maxWatchlistAssets(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 10
        case .pro:   return 50
        case .black: return nil
        }
    }

    // MARK: - Portfolio Limits

    /// Maximum holdings in a single portfolio. nil = unlimited.
    static func maxPortfolioHoldings(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 4
        case .pro:   return 25
        case .black: return nil
        }
    }

    /// Maximum portfolio groups. nil = unlimited.
    static func maxPortfolios(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 1
        case .pro:   return 1
        case .black: return 5
        }
    }

    // MARK: - Watchlist Group Limits

    /// Maximum watchlist groups. nil = unlimited.
    static func maxWatchlists(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 1
        case .pro:   return 2
        case .black: return nil
        }
    }

    // MARK: - Price Alert Limits

    /// Maximum active price alerts. nil = unlimited.
    static func maxAlerts(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 1
        case .pro:   return 25
        case .black: return nil
        }
    }

    // MARK: - Auto-Refresh

    /// Seconds between automatic quote refreshes.
    /// `nil` means no auto-refresh — user must pull to refresh.
    /// Black tier reads the user-chosen interval from UserDefaults (default 30s).
    static func autoRefreshInterval(for tier: SubscriptionTier) -> TimeInterval? {
        switch tier {
        case .free:  return nil   // manual only
        case .pro:   return 60
        case .black:
            let stored = UserDefaults.standard.integer(forKey: "blackTierRefreshInterval")
            let interval = stored > 0 ? stored : 30
            return TimeInterval(interval)
        }
    }

    /// Valid refresh interval options for Black tier (in seconds).
    static let blackTierRefreshOptions: [Int] = [30, 15, 10, 5]

    // MARK: - News

    /// Maximum news articles fetched per day. nil = unlimited.
    static func newsDailyLimit(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 5
        case .pro:   return 20
        case .black: return nil
        }
    }

    // MARK: - AI Queries

    /// Maximum AI chat queries per day. nil = unlimited. 0 = no access.
    static func aiDailyQueryLimit(for tier: SubscriptionTier) -> Int? {
        switch tier {
        case .free:  return 0   // no access
        case .pro:   return 20
        case .black: return nil // unlimited
        }
    }

    // MARK: - Convenience Helpers

    /// Returns whether the tier can add more watchlist assets.
    static func canAddWatchlistAsset(currentCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = maxWatchlistAssets(for: tier) else { return true }
        return currentCount < limit
    }

    /// Returns whether the tier can add another holding to a portfolio.
    static func canAddPortfolioHolding(currentCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = maxPortfolioHoldings(for: tier) else { return true }
        return currentCount < limit
    }

    /// Returns whether the tier can add another portfolio group.
    static func canAddPortfolio(currentCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = maxPortfolios(for: tier) else { return true }
        return currentCount < limit
    }

    /// Returns whether the tier can create another watchlist group.
    static func canAddWatchlist(currentCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = maxWatchlists(for: tier) else { return true }
        return currentCount < limit
    }

    /// Returns whether the tier can add another price alert.
    static func canAddAlert(currentCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = maxAlerts(for: tier) else { return true }
        return currentCount < limit
    }

    /// Returns whether the tier can use an AI insight (shared budget with chat).
    static func canUseAIInsight(currentDailyCount: Int, tier: SubscriptionTier) -> Bool {
        guard let limit = aiDailyQueryLimit(for: tier) else { return true }
        if limit == 0 { return false }
        return currentDailyCount < limit
    }
}
