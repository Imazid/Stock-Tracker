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

    /// When true, every call goes through the `snaptrade-proxy` Edge Function: the server
    /// signs with the consumer key and supplies the person's SnapTrade identity, so this
    /// device holds neither. `userId` / `userSecret` arguments are ignored in this mode.
    let isServerBacked: Bool

    /// Direct mode — signs on the device. Debug builds only, for running without a server.
    init(clientId: String, consumerKey: String) {
        self.clientId = clientId
        self.consumerKey = consumerKey
        self.isServerBacked = false
        SecureLogger.info("SnapTradeNetworkService initialized (direct)")
    }

    private init(serverBacked: Void) {
        self.clientId = ""
        self.consumerKey = ""
        self.isServerBacked = true
        SecureLogger.info("SnapTradeNetworkService initialized (server)")
    }

    /// Server mode — no SnapTrade secret on the device.
    static func serverBacked() -> SnapTradeNetworkService {
        SnapTradeNetworkService(serverBacked: ())
    }

    // MARK: - Server transport

    private func serverData(_ operation: String, _ params: [String: Any] = [:]) async throws -> Data {
        do {
            return try await SecureBackend.invoke("snaptrade-proxy", body: ["operation": operation, "params": params])
        } catch let error as SecureBackend.FunctionError {
            if error.code == "NOT_REGISTERED" { throw SnapTradeError.notAuthenticated }
            throw SnapTradeError.apiError(code: error.code, message: error.message)
        }
    }

    private func viaServer<T: Decodable>(_ operation: String, _ params: [String: Any] = [:]) async throws -> T {
        let data = try await serverData(operation, params)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SnapTradeError.decodingError(error)
        }
    }

    func registrationStatus() async throws -> Bool {
        struct Status: Decodable { let registered: Bool }
        let status: Status = try await viaServer("status")
        return status.registered
    }

    /// Creates (or confirms) this account's SnapTrade identity on the server.
    func registerOnServer() async throws {
        _ = try await serverData("registerUser")
    }

    /// One-time move of an identity an older app version kept in the Keychain. The server
    /// proves it with SnapTrade before storing it sealed; the caller then deletes its copy.
    func importLegacyIdentity(userId: String, userSecret: String) async throws {
        _ = try await serverData("importLegacyUser", ["snapTradeUserId": userId, "userSecret": userSecret])
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

        if isServerBacked {
            var params: [String: Any] = [
                "broker": broker,
                "immediateRedirect": immediateRedirect,
                "connectionType": "read",
                "connectionPortalVersion": "v3"
            ]
            if let customRedirect { params["customRedirect"] = customRedirect }
            return try await viaServer("loginLink", params)
        }

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
    
    // MARK: - Users

    /// Deletes the SnapTrade user and every broker connection it has (SnapTrade removes them
    /// shortly after). Afterwards nothing can read the person's broker any more.
    func deleteUser(userId: String) async throws {
        if isServerBacked {
            let _: SnapTradeDeleteUserResponse = try await viaServer("deleteUser")
            return
        }
        let request = try createRequest(path: "/snapTrade/deleteUser", method: "DELETE",
                                        queryParams: ["userId": userId])
        let _: SnapTradeDeleteUserResponse = try await executeRequest(request)
    }

    // MARK: - Brokerages

    /// Every institution SnapTrade can connect, with the slug `getLoginURL` needs, its
    /// display name, logo and whether it's enabled / in maintenance. Partner-signed, no user.
    func fetchBrokerages() async throws -> [SnapTradeBrokerage] {
        if isServerBacked { return try await viaServer("listBrokerages") }
        let request = try createRequest(path: "/brokerages", method: "GET")
        return try await executeRequest(request)
    }

    // MARK: - Accounts

    /// Fetch all accounts for a user
    func fetchAccounts(userId: String, userSecret: String) async throws -> [SnapTradeAccount] {
        SecureLogger.info("Fetching SnapTrade accounts")

        if isServerBacked { return try await viaServer("listAccounts") }

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
        if isServerBacked { return try await viaServer("accountPositions", ["accountId": accountId]) }
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
        if isServerBacked {
            let wrapper: SnapTradeAccountHoldingsResponse = try await viaServer("accountHoldings", ["accountId": accountId])
            guard let positions = wrapper.positions else { throw SnapTradeError.missingData }
            return positions
        }
        let request = try createRequest(
            path: "/accounts/\(accountId)/holdings",
            method: "GET",
            queryParams: ["userId": userId, "userSecret": userSecret]
        )
        let wrapper: SnapTradeAccountHoldingsResponse = try await executeRequest(request)
        guard let positions = wrapper.positions else { throw SnapTradeError.missingData }
        return positions
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

        async let positionsResult = fetchPositionsArray(accountId: accountId, userId: userId, userSecret: userSecret)
        async let holdingsResult = fetchHoldingsWrapper(accountId: accountId, userId: userId, userSecret: userSecret)
        let (fromPositions, fromHoldings) = try await (positionsResult, holdingsResult)

        // Merge the endpoints by listed instrument within this account.
        var merged: [[String]: SnapTradePosition] = [:]
        for position in fromPositions + fromHoldings {
            let listing = position.symbol.symbol
            let exchange = position.symbol.exchange?.code ?? listing.exchange?.code ?? ""
            let venue = ["ASX", "XASX"].contains(exchange.uppercased()) ? "ASX" : exchange.uppercased()
            merged[[listing.symbol.uppercased(), venue]] = position
        }
        return Array(merged.values)
    }

    func fetchAllHoldings(
        accountIds: [String],
        userId: String,
        userSecret: String
    ) async throws -> [(accountId: String, positions: [SnapTradePosition])] {
        try await withThrowingTaskGroup(of: (String, [SnapTradePosition]).self) { group in
            for accountId in accountIds {
                group.addTask {
                    let positions = try await self.fetchAccountHoldings(
                        accountId: accountId, userId: userId, userSecret: userSecret
                    )
                    return (accountId, positions)
                }
            }
            var results: [(String, [SnapTradePosition])] = []
            for try await result in group { results.append(result) }
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
