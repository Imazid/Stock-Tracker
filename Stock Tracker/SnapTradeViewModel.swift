//
//  SnapTradeViewModel.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeViewModel.swift
//  Stock Tracker
//
//  UI state management for SnapTrade integration
//  Responsibilities: Loading states, error handling, user actions
//  Coordinates between repository and SwiftUI views
//

import Foundation
import SwiftUI
import Combine

@MainActor
class SnapTradeViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadingMessage: String = ""
    
    @Published var accounts: [BrokerAccount] = []
    @Published var holdings: [BrokerHolding] = []
    
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    
    // Connection state
    @Published var connectionURL: URL?
    @Published var showConnectionView: Bool = false
    
    // MARK: - Dependencies
    
    private let repository: SnapTradeRepository
    
    // MARK: - Initialization
    
    init(repository: SnapTradeRepository) {
        self.repository = repository
        self.isAuthenticated = repository.isAuthenticated

        // Auto-load accounts if credentials are already in Keychain
        if repository.isAuthenticated {
            Task { await syncAll() }
        }
    }
    
    // MARK: - Authentication
    
    /// Connect to a broker - handles full authentication flow
    func connectBroker(broker: String = "ALPACA") async {
        isLoading = true
        loadingMessage = "Connecting to \(broker)..."
        errorMessage = nil
        
        do {
            // Ensure user is authenticated with SnapTrade
            if !repository.isAuthenticated {
                loadingMessage = "Authenticating with SnapTrade..."
                _ = try await repository.authenticateUser()
                isAuthenticated = true
            }
            
            // Get connection URL
            loadingMessage = "Generating connection link..."
            let url = try await repository.getBrokerConnectionURL(broker: broker)
            
            // Show connection view
            connectionURL = url
            showConnectionView = true
            
            isLoading = false
            loadingMessage = ""
            
        } catch {
            handleError(error)
        }
    }
    
    /// Disconnect from all brokers
    func disconnect() {
        repository.disconnect()
        isAuthenticated = false
        accounts = []
        holdings = []
    }
    
    // MARK: - Accounts
    
    /// Fetch all connected brokerage accounts
    func fetchAccounts() async {
        isLoading = true
        loadingMessage = "Loading accounts..."
        errorMessage = nil
        
        do {
            let fetchedAccounts = try await repository.fetchAccounts()
            accounts = fetchedAccounts
            isLoading = false
            loadingMessage = ""
            
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Holdings
    
    /// Fetch all holdings from all accounts
    func fetchAllHoldings() async {
        isLoading = true
        loadingMessage = "Loading holdings..."
        errorMessage = nil
        
        do {
            var fetchedHoldings = try await repository.fetchAllHoldings()
            
            // Enrich with latest market data
            loadingMessage = "Updating prices..."
            fetchedHoldings = await repository.enrichHoldings(fetchedHoldings)
            
            holdings = fetchedHoldings
            isLoading = false
            loadingMessage = ""
            
        } catch {
            handleError(error)
        }
    }
    
    /// Fetch holdings for a specific account
    func fetchHoldings(for accountId: String) async {
        isLoading = true
        loadingMessage = "Loading account holdings..."
        errorMessage = nil
        
        do {
            let fetchedHoldings = try await repository.fetchHoldings(for: accountId)
            
            // Update holdings array with new data
            holdings.removeAll { $0.accountId == accountId }
            holdings.append(contentsOf: fetchedHoldings)
            
            isLoading = false
            loadingMessage = ""
            
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Full Sync
    
    /// Sync all data - accounts and holdings
    func syncAll() async {
        isLoading = true
        errorMessage = nil
        
        // Fetch accounts first
        await fetchAccounts()
        
        // Then fetch all holdings
        if !accounts.isEmpty {
            await fetchAllHoldings()
        }
    }
    
    // MARK: - Portfolio Integration
    
    /// Convert broker holdings to app portfolio holdings
    func syncToPortfolio(marketData: MarketData) async {
        guard !holdings.isEmpty else {
            errorMessage = "No holdings to sync"
            showError = true
            return
        }
        
        isLoading = true
        loadingMessage = "Syncing to portfolio..."
        
        // Clear existing portfolio
        marketData.portfolio.removeAll()
        
        // Known crypto security type codes from SnapTrade
        let cryptoTypeCodes: Set<String> = ["CRYPTO", "DIGITAL_CURRENCY", "DIGITAL CURRENCY"]
        // Known crypto ticker symbols (mirrors QuoteService.coinGeckoIDMap)
        let knownCryptoSymbols: Set<String> = ["BTC", "ETH", "SOL", "ADA", "BNB", "XRP", "DOGE",
                                                "DOT", "MATIC", "LINK", "AVAX", "UNI", "LTC", "ATOM"]

        // Group holdings by symbol (in case same stock in multiple accounts)
        let groupedHoldings = Dictionary(grouping: holdings, by: { $0.symbol })

        for (symbol, symbolHoldings) in groupedHoldings {
            // Sum quantities and calculate weighted average cost
            let totalQuantity = symbolHoldings.reduce(0.0) { $0 + $1.quantity }

            let weightedCost = symbolHoldings.reduce(0.0) { sum, holding in
                let cost = holding.averageCost ?? holding.currentPrice ?? 0
                return sum + (cost * holding.quantity)
            } / totalQuantity

            guard let firstHolding = symbolHoldings.first else { continue }

            // Detect crypto by security type or by matching the CoinGecko ID map
            let secType = firstHolding.securityType?.uppercased() ?? ""
            let isCrypto = cryptoTypeCodes.contains(secType)
                || knownCryptoSymbols.contains(symbol.uppercased())

            let asset = Asset(
                symbol: symbol,
                name: firstHolding.displayName,
                price: firstHolding.currentPrice ?? 0,
                change: 0,
                changePercent: 0,
                volume: 0,
                kind: isCrypto ? .crypto : .stock,
                exchange: firstHolding.exchange ?? (isCrypto ? "Crypto" : "Unknown")
            )

            marketData.addToPortfolio(
                asset: asset,
                shares: totalQuantity,
                avgCost: weightedCost
            )
        }
        
        isLoading = false
        loadingMessage = ""
        
        SecureLogger.info("Synced \(groupedHoldings.count) unique holdings to portfolio")
    }
    
    // MARK: - Error Handling
    
    private func handleError(_ error: Error) {
        isLoading = false
        loadingMessage = ""
        
        if let snapTradeError = error as? SnapTradeError {
            errorMessage = snapTradeError.errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
        
        showError = true
        
        SecureLogger.error("SnapTrade error: \(errorMessage ?? "Unknown")")
    }
    
    // MARK: - Computed Properties
    
    var totalAccountsValue: Double {
        accounts.compactMap { $0.balance?.total?.amount }.reduce(0, +)
    }
    
    var totalHoldingsValue: Double {
        holdings.reduce(0) { $0 + $1.marketValue }
    }
    
    var accountsWithHoldings: [(account: BrokerAccount, holdings: [BrokerHolding])] {
        accounts.map { account in
            let accountHoldings = holdings.filter { $0.accountId == account.id }
            return (account, accountHoldings)
        }
    }
}
