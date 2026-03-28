//
//  SnapTradeAuthManager.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeAuthManager.swift
//  Stock Tracker
//
//  PHASE 11 - Auth & Connection Management
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SnapTradeAuthManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published var connectionState: ConnectionState = .notConnected
    @Published var userId: String?
    @Published var userSecret: String?
    @Published var errorMessage: String?
    
    enum ConnectionState {
        case notConnected
        case connecting
        case connected
        case error
        
        var displayText: String {
            switch self {
            case .notConnected: return "Not Connected"
            case .connecting: return "Connecting..."
            case .connected: return "Connected"
            case .error: return "Connection Error"
            }
        }
    }
    
    // MARK: - Configuration
    
    private let clientID = SecretsConfig.snapTradeClientId
    private let consumerKey = SecretsConfig.snapTradeConsumerKey
    
    private lazy var client: SnapTradeClient = {
        SnapTradeClient(clientID: clientID, consumerKey: consumerKey)
    }()
    
    // MARK: - Keychain Keys
    
    private let userIdKey = "snaptrade_userId"
    private let userSecretKey = "snaptrade_userSecret"
    
    // MARK: - Initialization
    
    init() {
        loadCredentials()
    }
    
    // MARK: - Credential Management
    
    private func loadCredentials() {
        userId = KeychainManager.shared.retrieve(key: userIdKey)
        userSecret = KeychainManager.shared.retrieve(key: userSecretKey)
        
        if userId != nil && userSecret != nil {
            connectionState = .connected
        }
    }
    
    private func saveCredentials(userId: String, userSecret: String) {
        _ = KeychainManager.shared.save(key: userIdKey, value: userId)
        _ = KeychainManager.shared.save(key: userSecretKey, value: userSecret)
        
        self.userId = userId
        self.userSecret = userSecret
    }
    
    private func clearCredentials() {
        _ = KeychainManager.shared.delete(key: userIdKey)
        _ = KeychainManager.shared.delete(key: userSecretKey)
        
        userId = nil
        userSecret = nil
    }
    
    // MARK: - User Registration
    
    func registerUser() async throws {
        connectionState = .connecting
        errorMessage = nil
        
        let newUserId = "StockTracker\(Int.random(in: 10000...99999))"
        
        let request = try client.createRequest(
            path: "/snapTrade/registerUser",
            method: "POST",
            queryParams: ["clientId": clientID],
            body: ["userId": newUserId]
        )
        
        do {
            let response: RegisterUserResponse = try await client.execute(request: request)
            
            saveCredentials(userId: newUserId, userSecret: response.userSecret)
            connectionState = .connected
            
        } catch {
            connectionState = .error
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    // MARK: - Login URL Generation
    
    func getLoginURL(broker: String = "ALPACA") async throws -> URL {
        guard let userId = userId, let userSecret = userSecret else {
            throw SnapTradeError.notAuthenticated
        }
        
        let body: [String: Any] = [
            "broker": broker,
            "immediateRedirect": true,
            "customRedirect": "stocktracker://auth/callback",
            "reconnect": false,
            "connectionType": "read",
            "connectionPortalVersion": "v3"
        ]
        
        let request = try client.createRequest(
            path: "/snapTrade/login",
            method: "POST",
            queryParams: [
                "userId": userId,
                "userSecret": userSecret
            ],
            body: body
        )
        
        let response: LoginResponse = try await client.execute(request: request)
        
        guard let url = URL(string: response.redirectURI) else {
            throw SnapTradeError.invalidResponse
        }
        
        return url
    }
    
    // MARK: - Connection Status Check
    
    func checkConnectionStatus() async throws -> Bool {
        guard let userId = userId, let userSecret = userSecret else {
            connectionState = .notConnected
            return false
        }
        
        do {
            let request = try client.createRequest(
                path: "/authorizations",
                queryParams: [
                    "userId": userId,
                    "userSecret": userSecret
                ]
            )
            
            let _: [Authorization] = try await client.execute(request: request)
            connectionState = .connected
            return true
            
        } catch {
            connectionState = .error
            errorMessage = error.localizedDescription
            return false
        }
    }
    
    // MARK: - Disconnect
    
    func disconnect() {
        clearCredentials()
        connectionState = .notConnected
        errorMessage = nil
    }
}

// MARK: - Response Models

struct RegisterUserResponse: Codable {
    let userSecret: String
}

struct LoginResponse: Codable {
    let redirectURI: String
}

struct Authorization: Codable {
    let id: String
    let createdDate: String?
    let brokerage: Brokerage?
    
    struct Brokerage: Codable {
        let id: String
        let name: String
    }
}
