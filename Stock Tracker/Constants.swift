//
//  Constants.swift
//  Stock Tracker
//
//  Single source of truth for all magic numbers, timeouts, and base URLs.
//

import Foundation

enum Constants {

    // MARK: - API Base URLs

    enum URLs {
        static let alpacaData    = "https://data.alpaca.markets"
        static let alpacaBroker  = "https://broker-api.alpaca.markets"
        static let alphaVantage  = "https://www.alphavantage.co"
        static let finnhub       = "https://finnhub.io/api/v1"
        static let coinGecko     = "https://api.coingecko.com/api/v3"
        static let exchangeRate  = "https://api.exchangerate.host/latest"
        static let openAI        = "https://api.openai.com/v1/chat/completions"
        static let fiscalAI      = "https://api.fiscal.ai"
        static let snapTrade     = "https://api.snaptrade.com/api/v1"
        static let yahooFinance  = "https://query1.finance.yahoo.com"
        static let privacyPolicy      = "https://yoursite.com/privacy"          // TODO: Replace with real URL
        static let termsOfService     = "https://yoursite.com/terms"            // TODO: Replace with real URL
        /// Your backend endpoint that proxies Apple's App Store Server API.
        /// Set this to a real URL to enable server-side receipt validation.
        static let receiptValidation  = "https://api.yoursite.com/v1/validate-receipt" // TODO: Replace
    }

    // MARK: - Networking

    enum Network {
        /// Default URLSession timeout for API requests (seconds).
        static let requestTimeout: TimeInterval = 30
        /// How long to wait between retry attempts.
        static let retryDelay: TimeInterval = 1.0
        /// Maximum number of automatic retries per request.
        static let maxRetries = 3
        /// Search debounce delay (milliseconds).
        static let searchDebouncems: Int = 350
        /// Number of search results to eagerly detail-fetch.
        static let searchDetailPrefetch = 5
    }

    // MARK: - Rate Limiting (requests per minute)

    enum RateLimit {
        static let alpacaPerMinute    = 200
        static let alphaVantagePerMin = 5
        static let finnhubPerMinute   = 60     // Finnhub free tier: 60 calls/min
        static let coinGeckoPerMin    = 10
        static let openAIPerMin       = 60
        static let snapTradePerMin    = 60
        static let fiscalAIPerDay     = 250    // Fiscal.ai free tier: 250 calls/day
    }

    // MARK: - Refresh / Cache

    enum Refresh {
        /// Minimum seconds between background refreshes.
        static let minimumInterval: TimeInterval = 30
        /// Seconds after which cached data is considered stale.
        static let staleThreshold: TimeInterval = 300
        /// Seconds to cache exchange rates before re-fetching.
        static let exchangeRateCacheDuration: TimeInterval = 300
        /// Maximum portfolio history snapshots kept locally.
        static let maxPortfolioHistoryDays = 1825   // 5 years of daily data
    }

    // MARK: - Pagination

    enum Pagination {
        /// Default news articles per page.
        static let newsPageSize = 20
        /// Maximum news articles fetched in a single request.
        static let newsMaxResults = 50
    }

    // MARK: - Free Tier Limits

    enum FreeTier {
        static let maxWatchlistAssets    = 10
        static let maxPortfolioHoldings  = 4
        static let maxPriceAlerts        = 1
    }

    // MARK: - Widget

    enum Widget {
        static let appGroup = "group.com.cubeplay.stocktracker"
    }

    // MARK: - AI

    enum AI {
        static let model          = "gpt-4o-mini"
        static let maxTokens      = 1000
        static let systemPromptMaxChars = 3000

        // Insight-specific settings
        static let insightMaxTokens     = 150
        static let insightTemperature   = 0.5
        static let dailyCacheTTL: TimeInterval   = 86400  // 24 hours
        static let defaultCacheTTL: TimeInterval = 14400   // 4 hours
        static let holdingCacheTTL: TimeInterval = 3600    // 1 hour
    }

    // MARK: - Notifications

    enum Notifications {
        static let blackTierRefreshIntervalChanged = "blackTierRefreshIntervalChanged"
    }

    // MARK: - Sync

    enum Sync {
        /// Seconds to wait after a mutation before uploading to Supabase (debounce).
        static let backgroundSyncDebounce: TimeInterval = 2.0
        /// Minimum seconds between foreground pulls from Supabase.
        static let foregroundPullThrottle: TimeInterval = 30.0
        /// Maximum number of portfolio snapshot days synced to Supabase.
        static let maxSnapshotSyncDays = 90
        static let sessionKeychainKey = "com.stocktracker.supabase.session"
        static let lastSyncDateKey    = "com.stocktracker.sync.lastSyncDate"
    }
}

extension Notification.Name {
    static let blackTierRefreshIntervalChanged = Notification.Name(Constants.Notifications.blackTierRefreshIntervalChanged)
}
