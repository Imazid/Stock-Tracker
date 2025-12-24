//
//  SnapTradeService.swift
//  Stock Tracker
//
//  Complete SnapTrade Integration
//

import Foundation
import CryptoKit
import SwiftUI

// MARK: - SnapTrade Service
@MainActor
class SnapTradeService: ObservableObject {
    static let shared = SnapTradeService()
    
    // IMPORTANT: Replace these with your actual credentials from https://dashboard.snaptrade.com
    private let clientId = "YOUR_CLIENT_ID_HERE"  // Get from SnapTrade dashboard
    private let consumerKey = "YOUR_CONSUMER_KEY_HERE"  // Keep this SECRET!
    
    @Published var userId: String = ""
    @Published var userSecret: String = ""
    @Published var isConnected: Bool = false
    @Published var connectedAccounts: [BrokerAccount] = []
    @Published var holdings: [BrokerHolding] = []
    @Published var isLoading: Bool = false
    
    private let baseURL = "https://api.snaptrade.com/api/v1"
    
    private init() {
        loadStoredCredentials()
    }
    
    // MARK: - Storage
    
    private func loadStoredCredentials() {
        userId = UserDefaults.standard.string(forKey: "snaptrade_userId") ?? ""
        userSecret = UserDefaults.standard.string(forKey: "snaptrade_userSecret") ?? ""
        isConnected = !userId.isEmpty && !userSecret.isEmpty
    }
    
    private func saveCredentials() {
        UserDefaults.standard.set(userId, forKey: "snaptrade_userId")
        UserDefaults.standard.set(userSecret, forKey: "snaptrade_userSecret")
    }
    
    // MARK: - User Registration
    
    func registerUser() async throws {
        // Generate unique user ID (you can use device ID or your own user ID)
        let newUserId = UUID().uuidString
        
        let url = URL(string: "\(baseURL)/snapTrade/registerUser")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(consumerKey, forHTTPHeaderField: "ConsumerKey")
        
        let body: [String: String] = ["userId": newUserId]
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SnapTradeError.registrationFailed
        }
        
        let result = try JSONDecoder().decode(RegisterUserResponse.self, from: data)
        
        userId = newUserId
        userSecret = result.userSecret
        isConnected = true
        saveCredentials()
        
        print("✅ SnapTrade user registered: \(userId)")
    }
    
    // MARK: - Connection Portal
    
    func getConnectionPortalURL() -> URL? {
        guard !userId.isEmpty else { return nil }
        
        let redirectURI = "stocktracker://snaptrade-callback"
        
        var components = URLComponents(string: "https://app.snaptrade.com/api/connect/v1")
        components?.queryItems = [
            URLQueryItem(name: "clientId", value: clientId),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "userSecret", value: userSecret),
            URLQueryItem(name: "redirectURI", value: redirectURI),
            URLQueryItem(name: "immediateRedirect", value: "true")
        ]
        
        return components?.url
    }
    
    // MARK: - Fetch Connected Accounts
    
    func fetchConnectedAccounts() async throws {
        guard !userId.isEmpty, !userSecret.isEmpty else {
            throw SnapTradeError.notAuthenticated
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let url = URL(string: "\(baseURL)/accounts")!
        let request = createAuthenticatedRequest(url: url, userId: userId, userSecret: userSecret)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SnapTradeError.requestFailed
        }
        
        let accounts = try JSONDecoder().decode([BrokerAccount].self, from: data)
        connectedAccounts = accounts
        
        print("✅ Fetched \(accounts.count) connected accounts")
    }
    
    // MARK: - Fetch Holdings
    
    func fetchHoldings() async throws {
        guard !userId.isEmpty, !userSecret.isEmpty else {
            throw SnapTradeError.notAuthenticated
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let url = URL(string: "\(baseURL)/holdings")!
        let request = createAuthenticatedRequest(url: url, userId: userId, userSecret: userSecret)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SnapTradeError.requestFailed
        }
        
        let fetchedHoldings = try JSONDecoder().decode([BrokerHolding].self, from: data)
        holdings = fetchedHoldings
        
        print("✅ Fetched \(fetchedHoldings.count) holdings")
    }
    
    // MARK: - Sync Holdings to Portfolio
    
    func syncToPortfolio(marketData: MarketData) async {
        guard !holdings.isEmpty else { return }
        
        // Clear existing portfolio
        marketData.portfolio.removeAll()
        
        for holding in holdings {
            // Convert BrokerHolding to Asset
            let asset = Asset(
                symbol: holding.symbol,
                name: holding.symbol, // You might want to fetch full name
                price: holding.price,
                change: 0,
                changePercent: 0,
                volume: 0,
                kind: .stock
            )
            
            // Add to portfolio
            marketData.addToPortfolio(
                asset: asset,
                shares: holding.quantity,
                avgCost: holding.averagePurchasePrice ?? holding.price
            )
        }
        
        print("✅ Synced \(holdings.count) holdings to portfolio")
    }
    
    // MARK: - Helper Methods
    
    private func createAuthenticatedRequest(url: URL, userId: String, userSecret: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(consumerKey, forHTTPHeaderField: "ConsumerKey")
        
        // Create signature
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signatureContent = timestamp + userId + userSecret
        let signature = signatureContent.sha256()
        
        request.setValue(signature, forHTTPHeaderField: "Signature")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        
        return request
    }
    
    // MARK: - Disconnect
    
    func disconnect() {
        userId = ""
        userSecret = ""
        isConnected = false
        connectedAccounts = []
        holdings = []
        
        UserDefaults.standard.removeObject(forKey: "snaptrade_userId")
        UserDefaults.standard.removeObject(forKey: "snaptrade_userSecret")
        
        print("✅ SnapTrade disconnected")
    }
}

// MARK: - Models

struct RegisterUserResponse: Codable {
    let userSecret: String
}

struct BrokerAccount: Codable, Identifiable {
    let id: String
    let name: String
    let number: String?
    let institutionName: String
    let balance: AccountBalance?
    let meta: AccountMeta?
}

struct AccountBalance: Codable {
    let total: Double?
    let cash: Double?
}

struct AccountMeta: Codable {
    let type: String?
}

struct BrokerHolding: Codable, Identifiable {
    let id: String
    let symbol: String
    let description: String?
    let quantity: Double
    let price: Double
    let averagePurchasePrice: Double?
    let currency: String?
    
    var totalValue: Double {
        quantity * price
    }
}

// MARK: - Errors

enum SnapTradeError: LocalizedError {
    case notAuthenticated
    case registrationFailed
    case requestFailed
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User not authenticated with SnapTrade"
        case .registrationFailed:
            return "Failed to register user with SnapTrade"
        case .requestFailed:
            return "SnapTrade API request failed"
        case .invalidResponse:
            return "Invalid response from SnapTrade API"
        }
    }
}

// MARK: - SHA256 Extension

extension String {
    func sha256() -> String {
        let data = Data(self.utf8)
        let hashed = SHA256.hash(data: data)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SnapTrade Connection View

struct SnapTradeConnectionView: View {
    @EnvironmentObject var marketData: MarketData
    @StateObject private var snapTrade = SnapTradeService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showWebView = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 32) {
                        // Header
                        VStack(spacing: 16) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)
                            
                            Text("Connect Your Brokerage")
                                .font(.title.bold())
                                .foregroundColor(.white)
                            
                            Text("Automatically sync your portfolio from 20+ brokers")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        
                        // Connection Status
                        if snapTrade.isConnected {
                            connectedStatusCard
                        } else {
                            disconnectedCard
                        }
                        
                        // Supported Brokers
                        supportedBrokersSection
                        
                        // Action Buttons
                        if snapTrade.isConnected {
                            connectedActions
                        } else {
                            Button {
                                Task { await connectBroker() }
                            } label: {
                                HStack {
                                    Image(systemName: "link")
                                    Text("Connect Broker Account")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.blue)
                                .cornerRadius(16)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("SnapTrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showWebView) {
                if let url = snapTrade.getConnectionPortalURL() {
                    SafariView(url: url)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .overlay {
                if snapTrade.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.5))
                }
            }
        }
    }
    
    private var connectedStatusCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)
            
            Text("Connected")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            if !snapTrade.connectedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connected Accounts")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    ForEach(snapTrade.connectedAccounts) { account in
                        HStack {
                            Image(systemName: "building.columns.fill")
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.institutionName)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                
                                if let number = account.number {
                                    Text("••••\(number.suffix(4))")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Spacer()
                            
                            if let balance = account.balance?.total {
                                Text(balance, format: .currency(code: "USD"))
                                    .font(.subheadline.bold())
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(20)
        .padding(.horizontal)
    }
    
    private var disconnectedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.slash")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            
            Text("Not Connected")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Connect your brokerage to automatically sync holdings")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(20)
        .padding(.horizontal)
    }
    
    private var connectedActions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await syncHoldings() }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Holdings")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.blue)
                .cornerRadius(16)
            }
            
            Button {
                snapTrade.disconnect()
            } label: {
                Text("Disconnect")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(16)
            }
        }
        .padding(.horizontal)
    }
    
    private var supportedBrokersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Supported Brokers")
                .font(.headline)
                .foregroundColor(.white)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(supportedBrokers, id: \.self) { broker in
                    Text(broker)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private let supportedBrokers = [
        "TD Ameritrade", "E*TRADE", "Fidelity", "Charles Schwab",
        "Robinhood", "Interactive Brokers", "Webull", "Alpaca"
    ]
    
    private func connectBroker() async {
        do {
            if snapTrade.userId.isEmpty {
                try await snapTrade.registerUser()
            }
            showWebView = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func syncHoldings() async {
        do {
            try await snapTrade.fetchConnectedAccounts()
            try await snapTrade.fetchHoldings()
            await snapTrade.syncToPortfolio(marketData: marketData)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Safari View (for connection portal)

import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

#Preview {
    SnapTradeConnectionView()
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}