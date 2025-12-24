//
//  SnapTradeService.swift
//  Stock Tracker
//
//  Fixed SnapTrade Integration
//

import Foundation
import CryptoKit
import SwiftUI
import Combine

// MARK: - SnapTrade Service
@MainActor
class SnapTradeService: ObservableObject {
    static let shared = SnapTradeService()
    
    // Your credentials
    private let clientId = "STOCK-TRADER-TEST-LUVFK"
    private let consumerKey = "IN3qbLlN479XDDwNgPUNBjg8AxOJ2bbXOQW6iToHt7QO3klwms"
    
    @Published var userId: String = "StockTracker20047"
    @Published var userSecret: String = "ae818a6f-c0e6-44ed-894a-c65131b3f3eb"
    @Published var isConnected: Bool = true
    @Published var connectedAccounts: [BrokerAccount] = []
    @Published var holdings: [BrokerHolding] = []
    @Published var isLoading: Bool = false
    
    private let baseURL = "https://api.snaptrade.com/api/v1"
    
    private init() {
        print("✅ SnapTrade initialized")
        print("   ClientId: \(clientId)")
        print("   UserId: \(userId)")
    }
    
    
    
    
    // MARK: - Core Request Builder
    
    func createRequest(
        path: String,
        method: String = "GET",
        queryParams: [String: String] = [:],
        unsignedQueryParams: Set<String> = [],
        body: [String: Any]? = nil
    ) throws -> URLRequest {

        let timestamp = String(Int(Date().timeIntervalSince1970))

        // All params that go into the URL
        var allParams = queryParams
        allParams["timestamp"] = timestamp

        // Params that go into the SIGNATURE
        let signedParams = allParams
            .filter { !unsignedQueryParams.contains($0.key) }
            .sorted { $0.key < $1.key }

        let signedQueryString = signedParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        // Build URL with ALL params
        let urlParams = allParams.sorted { $0.key < $1.key }

        var components = URLComponents(string: "\(baseURL)\(path)")!
        components.queryItems = urlParams.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }

        guard let url = components.url else {
            throw SnapTradeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let signature = try generateSignature(
            path: path,
            queryString: signedQueryString, // ✅ ONLY signed params
            body: body
        )

        request.setValue(signature, forHTTPHeaderField: "Signature")

        print("📤 URL: \(url.absoluteString)")
        print("🔐 Signed query: \(signedQueryString)")

        return request
    }


      
      // MARK: - Signature Generation (FIXED)
      
    private func generateSignature(
        path: String,
        queryString: String,
        body: [String: Any]?
    ) throws -> String {
        
        // Build in alphabetical order: content first, then path, then query
        var sigObject: [String: Any] = [:]
        
        // Add content first (null if empty)
        if let body = body, !body.isEmpty {
            sigObject["content"] = body
        } else {
            sigObject["content"] = NSNull()
        }
        
        sigObject["path"] = path
        sigObject["query"] = queryString
        
        // Serialize with sorted keys (extra safety)
        let jsonData = try JSONSerialization.data(
            withJSONObject: sigObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SnapTradeError.invalidResponse
        }
        
        // Remove ALL spaces
        //jsonString = jsonString.replacingOccurrences(of: " ", with: "")
        
        print("🔐 Final Signed JSON:\n\(jsonString)")
        
        let keyData = Data(consumerKey.utf8)
        let messageData = Data(jsonString.utf8)
        let symmetricKey = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
        
        return Data(signature).base64EncodedString()
    }
  

    // MARK: - API Status Check
    
    func checkAPIStatus() async throws -> String {
        var log = "🔍 Checking API Status...\n\n"
        
        let request = try createRequest(
            path: "/",
            queryParams: ["clientId": clientId]
        )
        
        log += "📡 Request:\n"
        log += "URL: \(request.url?.absoluteString ?? "nil")\n"
        log += "Method: \(request.httpMethod ?? "nil")\n"
        log += "Signature Header: \(request.value(forHTTPHeaderField: "Signature")?.prefix(20) ?? "nil")...\n\n"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            log += "❌ Invalid response type\n"
            throw SnapTradeError.requestFailed
        }
        
        log += "📊 Response Status: \(httpResponse.statusCode)\n"
        
        if let responseString = String(data: data, encoding: .utf8) {
            log += "📦 Response Body:\n\(responseString)\n\n"
        }
        
        if (200...299).contains(httpResponse.statusCode) {
            log += "✅ API is reachable!\n"
        } else {
            log += "❌ API returned error\n"
            throw SnapTradeError.requestFailed
        }
        
        return log
    }
    
    // MARK: - Register User
    
    func registerUser() async throws {
        print("🔄 Registering new SnapTrade user...")
        
        let newUserId = "StockTracker\(Int.random(in: 10000...99999))"
        
        let request = try createRequest(
            path: "/snapTrade/registerUser",
            method: "POST",
            queryParams: ["clientId": clientId],
            body: ["userId": newUserId]
        )
        
        print("📤 Request URL: \(request.url?.absoluteString ?? "nil")")
        print("📤 User ID: \(newUserId)")
        print("🔐 Signature: \(request.value(forHTTPHeaderField: "Signature")?.prefix(20) ?? "nil")...")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Invalid response")
            throw SnapTradeError.invalidResponse
        }
        
        print("📊 Status: \(httpResponse.statusCode)")
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("📦 Response: \(responseString)")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ Registration failed")
            throw SnapTradeError.registrationFailed
        }
        
        let result = try JSONDecoder().decode(RegisterUserResponse.self, from: data)
        
        userId = newUserId
        userSecret = result.userSecret
        isConnected = true
        
        // Save to UserDefaults
        UserDefaults.standard.set(userId, forKey: "snaptrade_userId")
        UserDefaults.standard.set(userSecret, forKey: "snaptrade_userSecret")
        
        print("✅ Registration successful!")
        print("   UserId: \(userId)")
        print("   UserSecret: \(userSecret.prefix(10))...")
    }
    
    // MARK: - Get Login URL (for connecting broker)
    
    func getLoginURL(broker: String = "COMMSEC") async throws -> URL {
        print("🔗 Getting login URL for broker: \(broker)")
        
        // Sort body keys alphabetically
        let body: [String: Any] = [
            "broker": broker,
            "darkMode": true,
            "immediateRedirect": true,
            "showCloseButton": true
        ]
        
        let request = try createRequest(
            path: "/snapTrade/login",
            method: "POST",
            queryParams: [
                "clientId": clientId,
                "userId": userId,
                "userSecret": userSecret
            ],
            body: body
        )
        
        print("📤 Request URL: \(request.url?.absoluteString ?? "nil")")
        print("🔐 Signature: \(request.value(forHTTPHeaderField: "Signature")?.prefix(20) ?? "nil")...")
        
        if let bodyData = request.httpBody,
           let bodyString = String(data: bodyData, encoding: .utf8) {
            print("📦 Request Body: \(bodyString)")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                throw SnapTradeError.requestFailed
            }
            
            print("📊 Status: \(httpResponse.statusCode)")
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("📦 Response: \(responseString)")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Failed to get login URL - Status \(httpResponse.statusCode)")
                
                // Try to parse error details
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("❌ Error details: \(errorJson)")
                }
                
                throw SnapTradeError.requestFailed
            }
            
            let result = try JSONDecoder().decode(LoginResponse.self, from: data)
            
            guard let url = URL(string: result.redirectURI) else {
                print("❌ Invalid redirect URI: \(result.redirectURI)")
                throw SnapTradeError.invalidResponse
            }
            
            print("✅ Got login URL: \(url.absoluteString)")
            return url
            
        } catch let error as DecodingError {
            print("❌ JSON Decode Error: \(error)")
            throw SnapTradeError.invalidResponse
        } catch let error as URLError {
            print("❌ Network Error: \(error.localizedDescription)")
            print("   Code: \(error.code.rawValue)")
            throw SnapTradeError.requestFailed
        } catch {
            print("❌ Unknown Error: \(error)")
            throw error
        }
    }
    
    // MARK: - Fetch Connected Accounts
    
    func fetchConnectedAccounts() async throws {
        print("🔍 Fetching connected accounts...")
        
        guard !userId.isEmpty, !userSecret.isEmpty else {
            print("❌ Not authenticated")
            throw SnapTradeError.notAuthenticated
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let request = try createRequest(
            path: "/accounts",
            queryParams: [
                "userId": userId,
                "userSecret": userSecret,
                "clientId": clientId
            ]
        )
        
        print("📤 Request URL: \(request.url?.absoluteString ?? "nil")")
        print("📋 Headers:")
        request.allHTTPHeaderFields?.forEach { print("   \($0.key): \($0.value)") }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response")
                throw SnapTradeError.requestFailed
            }
            
            print("📊 Status: \(httpResponse.statusCode)")
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("📦 Response: \(responseString)")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Failed to fetch accounts - Status \(httpResponse.statusCode)")
                
                // Try to parse error details
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("❌ Error details: \(errorJson)")
                }
                
                throw SnapTradeError.requestFailed
            }
            
            let accounts = try JSONDecoder().decode([BrokerAccount].self, from: data)
            connectedAccounts = accounts
            
            print("✅ Found \(accounts.count) accounts")
            
        } catch let error as DecodingError {
            print("❌ JSON Decode Error: \(error)")
            throw SnapTradeError.invalidResponse
        } catch let error as URLError {
            print("❌ Network Error: \(error.localizedDescription)")
            print("   Code: \(error.code.rawValue)")
            throw SnapTradeError.requestFailed
        } catch {
            print("❌ Unknown Error: \(error)")
            throw error
        }
    }
    
    // MARK: - Fetch Holdings
    
    func fetchHoldings() async throws {
        print("🔍 Fetching holdings...")
        
        guard !userId.isEmpty, !userSecret.isEmpty else {
            print("❌ Not authenticated")
            throw SnapTradeError.notAuthenticated
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let request = try createRequest(
            path: "/holdings",
            queryParams: [
                "userId": userId,
                "userSecret": userSecret,
                "clientId": clientId
            ]
        )
        
        print("📤 Request URL: \(request.url?.absoluteString ?? "nil")")
        print("📋 Headers:")
        request.allHTTPHeaderFields?.forEach { print("   \($0.key): \($0.value)") }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response")
                throw SnapTradeError.requestFailed
            }
            
            print("📊 Status: \(httpResponse.statusCode)")
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("📦 Response: \(responseString)")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Failed to fetch holdings - Status \(httpResponse.statusCode)")
                
                // Try to parse error details
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("❌ Error details: \(errorJson)")
                }
                
                throw SnapTradeError.requestFailed
            }
            
            let fetchedHoldings = try JSONDecoder().decode([BrokerHolding].self, from: data)
            holdings = fetchedHoldings
            
            print("✅ Found \(fetchedHoldings.count) holdings")
            
        } catch let error as DecodingError {
            print("❌ JSON Decode Error: \(error)")
            throw SnapTradeError.invalidResponse
        } catch let error as URLError {
            print("❌ Network Error: \(error.localizedDescription)")
            print("   Code: \(error.code.rawValue)")
            throw SnapTradeError.requestFailed
        } catch {
            print("❌ Unknown Error: \(error)")
            throw error
        }
    }
    
    // MARK: - Sync to Portfolio
    
    func syncToPortfolio(marketData: MarketData) async {
        guard !holdings.isEmpty else {
            print("⚠️ No holdings to sync")
            return
        }
        
        print("🔄 Syncing \(holdings.count) holdings to portfolio...")
        
        // Clear existing portfolio
        marketData.portfolio.removeAll()
        
        for holding in holdings {
            let asset = Asset(
                symbol: holding.symbol,
                name: holding.symbol,
                price: holding.price,
                change: 0,
                changePercent: 0,
                volume: 0,
                kind: .stock,
                exchange: holding.symbol
            )
            
            marketData.addToPortfolio(
                asset: asset,
                shares: holding.quantity,
                avgCost: holding.averagePurchasePrice ?? holding.price
            )
        }
        
        print("✅ Synced \(holdings.count) holdings to portfolio")
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
        
        print("✅ Disconnected from SnapTrade")
    }
}

// MARK: - Models

struct RegisterUserResponse: Codable {
    let userSecret: String
}

struct LoginResponse: Codable {
    let redirectURI: String
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

// MARK: - SnapTrade Connection View

struct SnapTradeConnectionView: View {
    @EnvironmentObject var marketData: MarketData
    @StateObject private var snapTrade = SnapTradeService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showWebView = false
    @State private var loginURL: URL?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedBroker = "COMMSEC"
    
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
                            
                            Text("Automatically sync your portfolio")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 40)
                        
                        // Connection Status
                        if snapTrade.isConnected {
                            connectedStatusCard
                        } else {
                            disconnectedCard
                        }
                        
                        // Broker Selection
                        if snapTrade.isConnected {
                            brokerSelectionSection
                        }
                        
                        // Action Buttons
                        if snapTrade.isConnected {
                            connectedActions
                        } else {
                            Button {
                                Task { await registerAndConnect() }
                            } label: {
                                HStack {
                                    if snapTrade.isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "link")
                                        Text("Connect Broker Account")
                                            .font(.headline)
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.blue)
                                .cornerRadius(16)
                            }
                            .disabled(snapTrade.isLoading)
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
                Group {
                    if let url = loginURL {
                        SafariView(url: url)
                            .ignoresSafeArea()
                    } else {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading connection portal...")
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    }
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
            
            if !snapTrade.holdings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Holdings (\(snapTrade.holdings.count))")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    ForEach(snapTrade.holdings.prefix(5)) { holding in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(holding.symbol)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                
                                Text("\(holding.quantity, specifier: "%.2f") shares")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            Text(holding.totalValue, format: .currency(code: "USD"))
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
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
    
    private var brokerSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Broker to Connect")
                .font(.headline)
                .foregroundColor(.white)
            
            Picker("Broker", selection: $selectedBroker) {
                Text("CommSec").tag("COMMSEC")
                Text("Alpaca").tag("ALPACA")
                Text("TD Ameritrade").tag("TDAMERITRADE")
                Text("E*TRADE").tag("ETRADE")
                Text("Fidelity").tag("FIDELITY")
                Text("Charles Schwab").tag("SCHWAB")
                Text("Interactive Brokers").tag("IBKR")
                Text("Robinhood").tag("ROBINHOOD")
                Text("Webull").tag("WEBULL")
            }
            .pickerStyle(.menu)
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    private var connectedActions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await connectBroker() }
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Connect Another Broker")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.blue)
                .cornerRadius(16)
            }
            
            Button {
                Task { await syncHoldings() }
            } label: {
                HStack {
                    if snapTrade.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync Holdings")
                            .font(.headline)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.green)
                .cornerRadius(16)
            }
            .disabled(snapTrade.isLoading)
            
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
    
    private func registerAndConnect() async {
        do {
            print("\n🚀 === REGISTER AND CONNECT START ===")
            
            // If already have credentials, skip registration
            if snapTrade.userId.isEmpty || snapTrade.userSecret.isEmpty {
                print("📝 No credentials found, registering new user...")
                try await snapTrade.registerUser()
                print("✅ User registered!")
            } else {
                print("✅ Using existing credentials:")
                print("   UserId: \(snapTrade.userId)")
                print("   UserSecret: \(snapTrade.userSecret.prefix(10))...")
            }
            
            // Get login URL
            print("\n🔗 Getting broker connection URL...")
            let url = try await snapTrade.getLoginURL(broker: selectedBroker)
            print("✅ Got URL: \(url.absoluteString)")
            
            // Store the URL and show Safari
            loginURL = url
            showWebView = true
            
            print("🌐 Opening SnapTrade connection portal in Safari...")
            print("✅ === REGISTER AND CONNECT COMPLETE ===\n")
            
        } catch {
            print("\n❌ === REGISTER AND CONNECT FAILED ===")
            print("Error type: \(type(of: error))")
            print("Error: \(error)")
            print("Description: \(error.localizedDescription)")
            
            if let snapError = error as? SnapTradeError {
                errorMessage = snapError.errorDescription ?? "Unknown error"
            } else {
                errorMessage = error.localizedDescription
            }
            
            showError = true
        }
    }
    
    private func connectBroker() async {
        do {
            print("\n🔗 === CONNECT BROKER START ===")
            print("Selected broker: \(selectedBroker)")
            print("UserId: \(snapTrade.userId)")
            
            let url = try await snapTrade.getLoginURL(broker: selectedBroker)
            print("✅ Got URL: \(url.absoluteString)")
            
            // Store the URL and show Safari
            loginURL = url
            showWebView = true
            
            print("🌐 Opening Safari sheet...")
            print("✅ === CONNECT BROKER COMPLETE ===\n")
            
        } catch {
            print("\n❌ === CONNECT BROKER FAILED ===")
            print("Error: \(error)")
            
            if let snapError = error as? SnapTradeError {
                errorMessage = snapError.errorDescription ?? "Unknown error"
            } else {
                errorMessage = error.localizedDescription
            }
            
            showError = true
        }
    }
    
    private func syncHoldings() async {
        do {
            print("\n🔄 === SYNC HOLDINGS START ===")
            print("UserId: \(snapTrade.userId)")
            print("UserSecret: \(snapTrade.userSecret.prefix(10))...")
            
            // Step 1: Fetch accounts first
            print("\n📊 Step 1: Fetching connected accounts...")
            try await snapTrade.fetchConnectedAccounts()
            print("✅ Accounts fetched: \(snapTrade.connectedAccounts.count)")
            
            // Check if we have any accounts
            if snapTrade.connectedAccounts.isEmpty {
                print("⚠️ No connected accounts found!")
                errorMessage = "No broker accounts connected. Please connect a broker first."
                showError = true
                return
            }
            
            // Step 2: Fetch holdings
            print("\n📈 Step 2: Fetching holdings...")
            try await snapTrade.fetchHoldings()
            print("✅ Holdings fetched: \(snapTrade.holdings.count)")
            
            // Check if we have any holdings
            if snapTrade.holdings.isEmpty {
                print("⚠️ No holdings found!")
                errorMessage = "No holdings found in your connected accounts."
                showError = true
                return
            }
            
            // Step 3: Sync to portfolio
            print("\n💾 Step 3: Syncing to portfolio...")
            await snapTrade.syncToPortfolio(marketData: marketData)
            
            print("\n✅ === SYNC COMPLETE ===")
            print("Synced \(snapTrade.holdings.count) holdings to portfolio\n")
            
        } catch {
            print("\n❌ === SYNC FAILED ===")
            print("Error type: \(type(of: error))")
            print("Error: \(error)")
            print("Description: \(error.localizedDescription)")
            
            if let snapError = error as? SnapTradeError {
                errorMessage = snapError.errorDescription ?? "Unknown error"
            } else {
                errorMessage = "Failed to sync holdings: \(error.localizedDescription)"
            }
            
            showError = true
        }
    }
}

// MARK: - Safari View

import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        print("🌐 Creating SFSafariViewController with URL: \(url.absoluteString)")
        
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.preferredControlTintColor = .systemBlue
        safari.preferredBarTintColor = .systemBackground
        safari.dismissButtonStyle = .close
        
        return safari
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        print("🔄 Updating SFSafariViewController")
    }
}

#Preview {
    SnapTradeConnectionView()
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}
