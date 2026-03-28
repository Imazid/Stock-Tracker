//
//  SnapTradeRepository.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeRepository.swift
//  Stock Tracker
//
//  Business logic layer for SnapTrade integration
//  Responsibilities: Model mapping, data transformation, business rules
//  Sits between network service and view models
//

import Foundation

@MainActor
class SnapTradeRepository {
    
    // MARK: - Dependencies
    
    private let networkService: SnapTradeNetworkService
    
    // MARK: - Authentication State
    
    private(set) var userId: String?
    private(set) var userSecret: String?
    private(set) var isAuthenticated: Bool = false
    
    // MARK: - Initialization
    
    init(networkService: SnapTradeNetworkService) {
        self.networkService = networkService
        loadAuthFromStorage()
    }
    
    // MARK: - Authentication
    
    /// Register a new user or restore existing credentials
    func authenticateUser(customUserId: String? = nil) async throws -> (userId: String, userSecret: String) {
        // Check if already authenticated
        if let userId = userId, let userSecret = userSecret {
            SecureLogger.info("Using existing SnapTrade credentials")
            return (userId, userSecret)
        }
        
        // Generate or use custom user ID
        let newUserId = customUserId ?? "StockTracker_\(UUID().uuidString.prefix(8))"
        
        SecureLogger.info("Registering new SnapTrade user")
        
        let response = try await networkService.registerUser(userId: newUserId)
        
        self.userId = response.userId ?? newUserId
        self.userSecret = response.userSecret
        self.isAuthenticated = true
        
        // Persist credentials
        saveAuthToStorage()
        
        SecureLogger.info("SnapTrade user authenticated")
        return (self.userId!, self.userSecret!)
    }
    
    /// Get broker connection URL
    func getBrokerConnectionURL(broker: String = "ALPACA") async throws -> URL {
        guard let userId = userId, let userSecret = userSecret else {
            throw SnapTradeError.notAuthenticated
        }
        
        let response = try await networkService.getLoginURL(
            userId: userId,
            userSecret: userSecret,
            broker: broker
        )
        
        guard let url = URL(string: response.redirectURI) else {
            throw SnapTradeError.invalidURL
        }
        
        return url
    }
    
    /// Clear authentication and disconnect
    func disconnect() {
        userId = nil
        userSecret = nil
        isAuthenticated = false
        clearAuthFromStorage()
        SecureLogger.info("SnapTrade user disconnected")
    }
    
    // MARK: - Accounts
    
    /// Fetch all brokerage accounts for the authenticated user
    func fetchAccounts() async throws -> [BrokerAccount] {
        guard let userId = userId, let userSecret = userSecret else {
            throw SnapTradeError.notAuthenticated
        }
        
        let snapTradeAccounts = try await networkService.fetchAccounts(
            userId: userId,
            userSecret: userSecret
        )
        
        // Map to app models (empty list is valid — no broker connected yet)
        let accounts = snapTradeAccounts.map { BrokerAccount.from(snapTradeAccount: $0) }
        
        SecureLogger.info("Fetched \(accounts.count) SnapTrade accounts")
        return accounts
    }
    
    // MARK: - Holdings
    
    /// Fetch all holdings across all accounts
    func fetchAllHoldings() async throws -> [BrokerHolding] {
        guard let userId = userId, let userSecret = userSecret else {
            throw SnapTradeError.notAuthenticated
        }

        let accountsWithPositions = try await networkService.fetchAllHoldings(
            userId: userId,
            userSecret: userSecret
        )

        let allHoldings = accountsWithPositions.flatMap { (accountId, positions) in
            positions.map { BrokerHolding.from(snapTradePosition: $0, accountId: accountId) }
        }

        SecureLogger.info("Fetched \(allHoldings.count) total holdings")
        return allHoldings
    }

    /// Fetch holdings for a specific account
    func fetchHoldings(for accountId: String) async throws -> [BrokerHolding] {
        guard let userId = userId, let userSecret = userSecret else {
            throw SnapTradeError.notAuthenticated
        }

        let positions = try await networkService.fetchAccountHoldings(
            accountId: accountId,
            userId: userId,
            userSecret: userSecret
        )

        let holdings = positions.map { BrokerHolding.from(snapTradePosition: $0, accountId: accountId) }
        SecureLogger.info("Fetched \(holdings.count) holdings for account")
        return holdings
    }
    
    // MARK: - Data Enrichment
    
    /// Enrich holdings with latest market prices
    /// This is a hook for future integration with market data APIs
    func enrichHoldings(_ holdings: [BrokerHolding]) async -> [BrokerHolding] {
        // TODO: Fetch latest prices from market data API
        // For now, return as-is since SnapTrade provides current prices
        return holdings
    }
    
    // MARK: - Persistence (SECURITY: Keychain instead of UserDefaults)

    private let keychainUserIdKey = "snaptrade_repo_userId"
    private let keychainUserSecretKey = "snaptrade_repo_userSecret"

    private func saveAuthToStorage() {
        guard let userId = userId, let userSecret = userSecret else { return }
        _ = KeychainManager.shared.save(key: keychainUserIdKey, value: userId)
        _ = KeychainManager.shared.save(key: keychainUserSecretKey, value: userSecret)
    }

    private func loadAuthFromStorage() {
        userId = KeychainManager.shared.retrieve(key: keychainUserIdKey)
        userSecret = KeychainManager.shared.retrieve(key: keychainUserSecretKey)
        isAuthenticated = userId != nil && userSecret != nil

        if isAuthenticated {
            SecureLogger.info("Loaded existing SnapTrade credentials from Keychain")
        }
    }

    private func clearAuthFromStorage() {
        _ = KeychainManager.shared.delete(key: keychainUserIdKey)
        _ = KeychainManager.shared.delete(key: keychainUserSecretKey)
    }
}
