//
//  RefreshManager.swift
//  Stock Tracker
//
//  Manages data refresh strategy, rate limiting, and caching
//

import Foundation
import Combine
import OSLog

@MainActor
class RefreshManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshDate: Date?
    @Published var nextAllowedRefresh: Date?
    
    // MARK: - Configuration
    
    /// Minimum seconds between full refreshes (rate limiting)
    var minimumRefreshInterval: TimeInterval = Constants.Refresh.minimumInterval

    /// Time after which data is considered stale
    var staleDataThreshold: TimeInterval = Constants.Refresh.staleThreshold
    
    /// Maximum concurrent refresh operations
    var maxConcurrentRefreshes: Int = 3
    
    // MARK: - Private State
    
    private var refreshTimestamps: [String: Date] = [:]
    private var activeRefreshes: Set<String> = []
    private var refreshQueue: [String: Task<Void, Never>] = [:]
    
    // MARK: - Singleton
    
    static let shared = RefreshManager()
    
    private init() {
        AppLogger.refresh.debug("RefreshManager initialized")
    }
    
    // MARK: - Rate Limiting
    
    /// Check if refresh is allowed for a specific resource
    func canRefresh(resource: String) -> Bool {
        // Check if already refreshing
        if activeRefreshes.contains(resource) {
            AppLogger.refresh.debug("Refresh blocked: \(resource) already refreshing")
            return false
        }

        // Check cooldown period
        if let lastRefresh = refreshTimestamps[resource] {
            let timeSinceRefresh = Date().timeIntervalSince(lastRefresh)
            if timeSinceRefresh < minimumRefreshInterval {
                let remaining = minimumRefreshInterval - timeSinceRefresh
                nextAllowedRefresh = Date().addingTimeInterval(remaining)
                AppLogger.refresh.debug("Refresh blocked: \(resource) in cooldown (\(Int(remaining))s remaining)")
                return false
            }
        }

        // Check concurrent refresh limit
        if activeRefreshes.count >= maxConcurrentRefreshes {
            AppLogger.refresh.debug("Refresh blocked: max concurrent refreshes reached")
            return false
        }
        
        return true
    }
    
    /// Record that a refresh has started
    func startRefresh(resource: String) {
        activeRefreshes.insert(resource)
        isRefreshing = !activeRefreshes.isEmpty
        AppLogger.refresh.debug("Started refresh: \(resource)")
    }

    /// Record that a refresh has completed
    func endRefresh(resource: String) {
        activeRefreshes.remove(resource)
        refreshTimestamps[resource] = Date()
        lastRefreshDate = Date()
        isRefreshing = !activeRefreshes.isEmpty
        nextAllowedRefresh = nil
        AppLogger.refresh.debug("Completed refresh: \(resource)")
    }
    
    // MARK: - Stale Data Detection
    
    /// Check if data for a resource is stale
    func isStale(resource: String) -> Bool {
        guard let lastRefresh = refreshTimestamps[resource] else {
            return true // No data = stale
        }
        
        let timeSinceRefresh = Date().timeIntervalSince(lastRefresh)
        return timeSinceRefresh > staleDataThreshold
    }
    
    /// Get time since last refresh for a resource
    func timeSinceRefresh(resource: String) -> TimeInterval? {
        guard let lastRefresh = refreshTimestamps[resource] else {
            return nil
        }
        return Date().timeIntervalSince(lastRefresh)
    }
    
    /// Format last refresh time for display
    func formattedLastRefresh(resource: String) -> String {
        guard let lastRefresh = refreshTimestamps[resource] else {
            return "Never"
        }
        
        let interval = Date().timeIntervalSince(lastRefresh)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
    
    // MARK: - Smart Refresh
    
    /// Execute a refresh with rate limiting and debouncing
    func executeRefresh(
        resource: String,
        operation: @escaping () async throws -> Void
    ) async {
        
        // Cancel any pending refresh for this resource
        if let existingTask = refreshQueue[resource] {
            existingTask.cancel()
        }
        
        // Check if refresh is allowed
        guard canRefresh(resource: resource) else {
            AppLogger.refresh.debug("Skipping refresh: rate limited")
            return
        }

        // Create and store refresh task
        let task = Task {
            startRefresh(resource: resource)

            do {
                try await operation()
                AppLogger.refresh.info("Refresh succeeded: \(resource)")
            } catch {
                AppLogger.refresh.error("Refresh failed: \(resource) — \(error)")
            }

            endRefresh(resource: resource)
        }
        
        refreshQueue[resource] = task
        await task.value
        refreshQueue.removeValue(forKey: resource)
    }
    
    // MARK: - Background Refresh
    
    /// Refresh data when app becomes active (if stale)
    func refreshOnAppActive(
        resources: [String],
        operation: @escaping (String) async throws -> Void
    ) async {
        AppLogger.refresh.debug("App became active — checking stale data")
        for resource in resources {
            if isStale(resource: resource) {
                AppLogger.refresh.debug("Refreshing stale resource: \(resource)")
                await executeRefresh(resource: resource) {
                    try await operation(resource)
                }
            }
        }
    }
    
    // MARK: - Cache Management
    
    /// Clear refresh timestamps (force next refresh)
    func invalidateCache(resource: String? = nil) {
        if let resource = resource {
            refreshTimestamps.removeValue(forKey: resource)
            AppLogger.refresh.debug("Invalidated cache: \(resource)")
        } else {
            refreshTimestamps.removeAll()
            AppLogger.refresh.debug("Invalidated all cache")
        }
    }

    /// Reset all refresh state
    func reset() {
        activeRefreshes.removeAll()
        refreshTimestamps.removeAll()
        refreshQueue.values.forEach { $0.cancel() }
        refreshQueue.removeAll()
        isRefreshing = false
        lastRefreshDate = nil
        nextAllowedRefresh = nil
        AppLogger.refresh.debug("RefreshManager reset")
    }
}

// MARK: - Resource Identifiers

extension RefreshManager {
    enum Resource {
        static let accounts = "accounts"
        static let holdings = "holdings"
        static let transactions = "transactions"
        static let performance = "performance"
        static let marketData = "marketData"
        
        static func holding(accountId: String) -> String {
            "holding_\(accountId)"
        }
        
        static func transaction(accountId: String) -> String {
            "transaction_\(accountId)"
        }
    }
}
