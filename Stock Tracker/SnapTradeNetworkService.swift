//
//  SnapTradeNetworkService.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeNetworkService.swift
//  Stock Tracker
//
//  Pure networking layer for SnapTrade API
//  Responsibilities: HTTP requests, auth, signatures, error handling
//  Does NOT handle business logic or model mapping
//

import Foundation
import CryptoKit

// MARK: - Network Service

@MainActor
class SnapTradeNetworkService {
    
    // MARK: - Configuration
    
    private let baseURL = "https://api.snaptrade.com/api/v1"
    private let clientId: String
    private let consumerKey: String
    
    // MARK: - Initialization
    
    // SECURITY: Secure URLSession with timeouts
    private let secureSession = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 30)

    init(clientId: String, consumerKey: String) {
        self.clientId = clientId
        self.consumerKey = consumerKey

        SecureLogger.info("SnapTradeNetworkService initialized")
    }
    
    // MARK: - Authentication
    
    /// Register a new user with SnapTrade
    func registerUser(userId: String) async throws -> SnapTradeRegisterResponse {
        SecureLogger.info("Registering SnapTrade user")
        
        let request = try createRequest(
            path: "/snapTrade/registerUser",
            method: "POST",
            body: ["userId": userId]
        )
        
        return try await executeRequest(request)
    }
    
    /// Get login URL for broker connection
    func getLoginURL(
        userId: String,
        userSecret: String,
        broker: String = "ALPACA",
        immediateRedirect: Bool = false,
        customRedirect: String? = nil
    ) async throws -> SnapTradeLoginResponse {
        SecureLogger.info("Getting SnapTrade login URL")
        
        var body: [String: Any] = [
            "broker": broker,
            "immediateRedirect": immediateRedirect,
            "connectionType": "read",
            "connectionPortalVersion": "v3"
        ]

        if let customRedirect = customRedirect {
            body["customRedirect"] = customRedirect
        }
        
        let request = try createRequest(
            path: "/snapTrade/login",
            method: "POST",
            queryParams: [
                "userId": userId,
                "userSecret": userSecret
            ],
            body: body
        )
        
        return try await executeRequest(request)
    }
    
    // MARK: - Accounts
    
    /// Fetch all accounts for a user
    func fetchAccounts(userId: String, userSecret: String) async throws -> [SnapTradeAccount] {
        SecureLogger.info("Fetching SnapTrade accounts")
        
        let request = try createRequest(
            path: "/accounts",
            method: "GET",
            queryParams: [
                "userId": userId,
                "userSecret": userSecret
            ]
        )
        
        return try await executeRequest(request)
    }
    
    // MARK: - Holdings
    
    /// Fetch holdings for a specific account
    /// Fetch positions via /positions (returns plain array — ASX/CHESS shares).
    private func fetchPositionsArray(
        accountId: String,
        userId: String,
        userSecret: String
    ) async throws -> [SnapTradePosition] {
        let request = try createRequest(
            path: "/accounts/\(accountId)/positions",
            method: "GET",
            queryParams: ["userId": userId, "userSecret": userSecret]
        )
        return try await executeRequest(request)
    }

    /// Fetch positions via /holdings (returns wrapper object — may include international shares).
    private func fetchHoldingsWrapper(
        accountId: String,
        userId: String,
        userSecret: String
    ) async throws -> [SnapTradePosition] {
        let request = try createRequest(
            path: "/accounts/\(accountId)/holdings",
            method: "GET",
            queryParams: ["userId": userId, "userSecret": userSecret]
        )
        let wrapper: SnapTradeAccountHoldingsResponse = try await executeRequest(request)
        return wrapper.positions ?? []
    }

    /// Fetch ALL positions for an account by merging both endpoints.
    /// CommSec (and similar brokers) report ASX shares via /positions and
    /// international shares only via /holdings — both are needed for a complete view.
    func fetchAccountHoldings(
        accountId: String,
        userId: String,
        userSecret: String
    ) async throws -> [SnapTradePosition] {
        SecureLogger.info("Fetching holdings for account")

        // Run both endpoints concurrently; failures fall back to empty.
        async let positionsResult = (try? fetchPositionsArray(accountId: accountId, userId: userId, userSecret: userSecret)) ?? []
        async let holdingsResult  = (try? fetchHoldingsWrapper(accountId: accountId, userId: userId, userSecret: userSecret)) ?? []

        let (fromPositions, fromHoldings) = await (positionsResult, holdingsResult)

        // Merge, deduplicating by ticker symbol (prefer /holdings data when both present)
        var merged: [String: SnapTradePosition] = [:]
        for p in fromPositions { merged[p.symbol.symbol.symbol] = p }
        for p in fromHoldings  { merged[p.symbol.symbol.symbol] = p }   // overwrites dupes

        let all = Array(merged.values)
        SecureLogger.info("Account \(accountId): \(fromPositions.count) from /positions, \(fromHoldings.count) from /holdings → \(all.count) merged")
        return all
    }

    /// Fetch holdings for all accounts, keyed by account ID
    func fetchAllHoldings(
        userId: String,
        userSecret: String
    ) async throws -> [(accountId: String, positions: [SnapTradePosition])] {
        SecureLogger.info("Fetching all SnapTrade holdings")

        let accounts = try await fetchAccounts(userId: userId, userSecret: userSecret)

        return try await withThrowingTaskGroup(of: (String, [SnapTradePosition])?.self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        let positions = try await self.fetchAccountHoldings(
                            accountId: account.id,
                            userId: userId,
                            userSecret: userSecret
                        )
                        return (account.id, positions)
                    } catch {
                        SecureLogger.error("Failed to fetch holdings for account")
                        return nil
                    }
                }
            }

            var results: [(String, [SnapTradePosition])] = []
            for try await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            return results
        }
    }
    
    // MARK: - Request Building
    
    private func createRequest(
        path: String,
        method: String = "GET",
        queryParams: [String: String] = [:],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        
        // Add clientId and timestamp to every request (required by all SnapTrade endpoints)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var allParams = queryParams
        allParams["clientId"] = clientId
        allParams["timestamp"] = timestamp
        
        // Sort params alphabetically
        let sortedParams = allParams.sorted { $0.key < $1.key }
        let queryString = sortedParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        
        // Build URL
        var components = URLComponents(string: "\(baseURL)\(path)")!
        components.queryItems = sortedParams.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        
        guard let url = components.url else {
            throw SnapTradeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add body if present
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        // IMPORTANT: Use the FULL path from the constructed URL (e.g. "/api/v1/snapTrade/login").
        // The SnapTrade server extracts url.path when verifying — using just `path` (which lacks
        // the "/api/v1" prefix) always produces a signature mismatch.
        let signaturePath = url.path
        let signature = try generateSignature(
            path: signaturePath,
            queryString: queryString,
            body: body
        )
        
        request.setValue(signature, forHTTPHeaderField: "Signature")

        // SECURITY: Only log method and path, never full URL (contains secrets in query params)
        SecureLogger.info("SnapTrade \(method) \(path)")

        return request
    }
    
    // MARK: - Signature Generation
    
    private func generateSignature(
        path: String,
        queryString: String,
        body: [String: Any]?
    ) throws -> String {
        
        // Sort body keys alphabetically
        let sortedBody: Any
        if let body = body, !body.isEmpty {
            sortedBody = sortDictionary(body)
        } else {
            sortedBody = NSNull()
        }
        
        // Build signature object with keys in alphabetical order: content, path, query
        let sigObject: [String: Any] = [
            "content": sortedBody,
            "path": path,
            "query": queryString
        ]
        
        // Serialize to JSON with sorted keys and no whitespace
        let jsonData = try JSONSerialization.data(
            withJSONObject: sigObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SnapTradeError.signatureGenerationFailed
        }
        
        // Remove ALL whitespace
        jsonString = jsonString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\r", with: "")
        
        // Generate HMAC-SHA256 signature
        let keyData = Data(consumerKey.utf8)
        let messageData = Data(jsonString.utf8)
        let symmetricKey = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
        
        return Data(signature).base64EncodedString()
    }
    
    private func sortDictionary(_ dict: [String: Any]) -> [String: Any] {
        var sorted = [String: Any]()
        
        for key in dict.keys.sorted() {
            if let nestedDict = dict[key] as? [String: Any] {
                sorted[key] = sortDictionary(nestedDict)
            } else if let array = dict[key] as? [[String: Any]] {
                sorted[key] = array.map { sortDictionary($0) }
            } else {
                sorted[key] = dict[key]
            }
        }
        
        return sorted
    }
    
    // MARK: - Request Execution
    
    private func executeRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        // SECURITY: Use rate-limited secure session
        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "snapTrade",
            config: .snapTrade
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SnapTradeError.invalidResponse
        }

        SecureLogger.info("SnapTrade response: \(httpResponse.statusCode)")
        
        // Handle error responses
        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to decode error response
            if let errorResponse = try? JSONDecoder().decode(SnapTradeErrorResponse.self, from: data) {
                throw SnapTradeError.apiError(
                    code: errorResponse.code ?? "unknown",
                    message: errorResponse.detail ?? "Unknown error"
                )
            }
            
            // SECURITY: Don't include response body in error (may contain sensitive data)
            throw SnapTradeError.httpError(
                statusCode: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode) error"
            )
        }
        
        // Decode success response
        #if DEBUG
        if let rawString = String(data: data, encoding: .utf8) {
            print("SnapTrade raw response (\(data.count) bytes): \(rawString.prefix(2000))")
        }
        #endif
        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(T.self, from: data)
            SecureLogger.info("SnapTrade response decoded successfully")
            return decoded
        } catch {
            #if DEBUG
            print("SnapTrade decode error detail: \(error)")
            #endif
            SecureLogger.error("SnapTrade decode error: \(error.localizedDescription)")
            throw SnapTradeError.decodingError(error)
        }
    }
}
