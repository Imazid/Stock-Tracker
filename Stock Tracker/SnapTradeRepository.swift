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
import Auth

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
        if networkService.isServerBacked {
            // The identity lives on the server; this flag only saves a round trip at launch.
            // A stale flag corrects itself: the server answers NOT_REGISTERED.
            isAuthenticated = UserDefaults.standard.bool(forKey: Self.serverRegisteredKey)
        } else {
            loadAuthFromStorage()
        }
    }

    private static let serverRegisteredKey = "snaptrade_server_registered"

    private func setServerRegistered(_ value: Bool) {
        isAuthenticated = value
        UserDefaults.standard.set(value, forKey: Self.serverRegisteredKey)
    }

    /// The identity to pass to the network layer. In server mode the server supplies it, so
    /// this only checks that one exists.
    private func requireIdentity() throws -> (userId: String, userSecret: String) {
        if networkService.isServerBacked {
            guard isAuthenticated else { throw SnapTradeError.notAuthenticated }
            return ("", "")
        }
        guard let userId, let userSecret else { throw SnapTradeError.notAuthenticated }
        return (userId, userSecret)
    }

    /// Runs a server call; if the server no longer knows this account's identity, forget the flag.
    private func tracked<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch SnapTradeError.notAuthenticated {
            if networkService.isServerBacked { setServerRegistered(false) }
            throw SnapTradeError.notAuthenticated
        }
    }
    
    // MARK: - Authentication
    
    /// Register a new user or restore existing credentials
    func authenticateUser(customUserId: String? = nil) async throws {
        if networkService.isServerBacked {
            try await authenticateOnServer()
            return
        }
        // Check if already authenticated
        if userId != nil, userSecret != nil {
            SecureLogger.info("Using existing SnapTrade credentials")
            return
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
    }

    /// Server mode: move a Keychain identity from an older app version if there is one,
    /// otherwise create a fresh identity. Either way the device keeps no secret afterwards.
    private func authenticateOnServer() async throws {
        let legacyId = KeychainManager.shared.retrieve(key: keychainUserIdKey)
        let legacySecret = KeychainManager.shared.retrieve(key: keychainUserSecretKey)
        if let legacyId, let legacySecret {
            do {
                try await networkService.importLegacyIdentity(userId: legacyId, userSecret: legacySecret)
                SecureLogger.info("Moved SnapTrade identity from Keychain to the server")
            } catch SnapTradeError.apiError(let code, _) where code == "ALREADY_REGISTERED" {
                SecureLogger.info("Server already holds a SnapTrade identity for this account")
            } catch SnapTradeError.apiError(let code, _)
                        where code == "LEGACY_CREDENTIALS_REJECTED" || code == "IDENTITY_IN_USE" {
                // Invalid, or already claimed by another account (early builds shared one
                // hard-coded test identity): start this account with its own identity.
                SecureLogger.warning("Old SnapTrade identity unusable (\(code)); registering a new one")
                try await networkService.registerOnServer()
            }
            clearAuthFromStorage()
            userId = nil
            userSecret = nil
        } else {
            try await networkService.registerOnServer()
        }
        setServerRegistered(true)
    }
    
    /// Get broker connection URL
    func getBrokerConnectionURL(broker: String = "ALPACA") async throws -> URL {
        let identity = try requireIdentity()

        let response = try await tracked {
            try await networkService.getLoginURL(
                userId: identity.userId,
                userSecret: identity.userSecret,
                broker: broker
            )
        }
        
        guard let url = URL(string: response.redirectURI) else {
            throw SnapTradeError.invalidURL
        }
        
        return url
    }
    
    /// Deletes the user at SnapTrade (with all their broker connections), then forgets it here.
    /// Throws — and keeps the local login — if SnapTrade can't be reached.
    func deleteUserAndDisconnect() async throws {
        if networkService.isServerBacked {
            if isAuthenticated { try await networkService.deleteUser(userId: "") }
        } else if let userId {
            try await networkService.deleteUser(userId: userId)
        }
        disconnect()
    }

    /// Clear authentication and disconnect
    func disconnect() {
        userId = nil
        userSecret = nil
        isAuthenticated = false
        clearAuthFromStorage()
        if networkService.isServerBacked { setServerRegistered(false) }
        SecureLogger.info("SnapTrade user disconnected")
    }
    
    // MARK: - Accounts

    func refreshRegistration() async throws -> Bool {
        guard networkService.isServerBacked else { return isAuthenticated }
        let owner = SupabaseManager.auth.currentUser?.id
        guard owner != nil else { return false }
        let registered = try await networkService.registrationStatus()
        guard SupabaseManager.auth.currentUser?.id == owner else { throw CancellationError() }
        setServerRegistered(registered)
        return registered
    }

    /// Institutions SnapTrade can connect right now (no user needed).
    func fetchBrokerages() async throws -> [SnapTradeBrokerage] {
        try await networkService.fetchBrokerages()
    }

    /// Fetch all brokerage accounts for the authenticated user
    func fetchAccounts() async throws -> [BrokerAccount] {
        let identity = try requireIdentity()

        let accounts = try await tracked {
            try await networkService.fetchAccounts(userId: identity.userId, userSecret: identity.userSecret)
        }
        SecureLogger.info("Fetched \(accounts.count) SnapTrade accounts")
        return accounts
    }
    
    // MARK: - Holdings
    
    /// Fetch all holdings across all accounts
    func fetchAllHoldings(accountIds: [String]) async throws -> [BrokerHolding] {
        let identity = try requireIdentity()

        let holdings = try await tracked {
            try await networkService.fetchAllHoldings(accountIds: accountIds, userId: identity.userId, userSecret: identity.userSecret)
        }
        SecureLogger.info("Fetched \(holdings.count) total holdings")
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
