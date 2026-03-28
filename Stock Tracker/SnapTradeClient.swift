//
//  SnapTradeClient.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeClient.swift
//  Stock Tracker
//
//  PHASE 11 - Low-Level HTTP Client
//

import Foundation
import CryptoKit

final class SnapTradeClient {
    
    // MARK: - Configuration
    
    private let baseURL = "https://api.snaptrade.com/api/v1"
    private let clientID: String
    private let consumerKey: String
    
    // MARK: - Initialization
    
    init(clientID: String, consumerKey: String) {
        self.clientID = clientID
        self.consumerKey = consumerKey
    }
    
    // MARK: - Request Building
    
    func createRequest(
        path: String,
        method: String = "GET",
        queryParams: [String: String] = [:],
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        
        // Add timestamp
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var allParams = queryParams
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
            throw SnapTradeError.invalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add body if present
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        // Generate and add signature
        // IMPORTANT: Use the FULL path from the constructed URL (e.g. "/api/v1/snapTrade/login").
        // The SnapTrade server extracts url.path when verifying — using just `path` (which lacks
        // the "/api/v1" prefix) always produces a signature mismatch.
        let signature = try generateSignature(
            path: url.path,
            queryString: queryString,
            body: body
        )
        
        request.setValue(signature, forHTTPHeaderField: "Signature")
        
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
        
        // Build signature object (keys must be alphabetically ordered: content, path, query)
        let sigObject: [String: Any] = [
            "content": sortedBody,
            "path": path,
            "query": queryString
        ]
        
        // Serialize to JSON with sorted keys
        let jsonData = try JSONSerialization.data(
            withJSONObject: sigObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SnapTradeError.invalidResponse
        }
        
        // Remove ALL whitespace (match Python's compact JSON)
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
    
    // Helper to recursively sort dictionary keys
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
    
    // SECURITY: Secure session with timeouts
    private let secureSession = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 30)

    func execute<T: Decodable>(request: URLRequest) async throws -> T {
        // SECURITY: Rate-limited request
        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "snapTrade",
            config: .snapTrade
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SnapTradeError.invalidResponse
        }

        // Handle different status codes
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw SnapTradeError.invalidCredentials
        case 429:
            throw SnapTradeError.rateLimitExceeded
        case 500...599:
            throw SnapTradeError.serverError(httpResponse.statusCode)
        default:
            throw SnapTradeError.connectionFailed
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            // SECURITY: Don't log response bodies (may contain sensitive data)
            SecureLogger.error("SnapTrade decode error: \(error.localizedDescription)")
            throw SnapTradeError.invalidResponse
        }
    }
}