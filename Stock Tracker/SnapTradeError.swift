//
//  SnapTradeError.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeError.swift
//  Stock Tracker
//
//  PHASE 11 - Error Types
//

import Foundation

enum SnapTradeError: LocalizedError {
    case notAuthenticated
    case invalidCredentials
    case connectionFailed
    case networkError(String)
    case invalidResponse
    case serverError(Int)
    case rateLimitExceeded
    case brokerageNotSupported
    case missingData
    case invalidURL
    case signatureGenerationFailed
    case apiError(code: String, message: String)
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case noAccountsFound
    case noHoldingsFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You need to connect your brokerage account first"
        case .invalidCredentials:
            return "Invalid SnapTrade credentials. Please check your API keys"
        case .connectionFailed:
            return "Failed to connect to your brokerage. Please try again"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Received invalid response from SnapTrade"
        case .serverError(let code):
            return "Server error (code \(code)). Please try again later"
        case .rateLimitExceeded:
            return "Too many requests. Please wait a moment and try again"
        case .brokerageNotSupported:
            return "This brokerage is not currently supported"
        case .missingData:
            return "Some required data is missing from your account"
        case .invalidURL:
            return "Invalid request URL"
        case .signatureGenerationFailed:
            return "Failed to generate request signature"
        case .apiError(let code, let message):
            return "API Error (\(code)): \(message)"
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .noAccountsFound:
            return "No brokerage accounts found"
        case .noHoldingsFound:
            return "No holdings found"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated:
            return "Connect your brokerage account in Settings"
        case .invalidCredentials:
            return "Contact support for assistance with API credentials"
        case .connectionFailed:
            return "Check your internet connection and try again"
        case .networkError:
            return "Check your internet connection"
        case .invalidResponse, .serverError:
            return "If this persists, contact support"
        case .rateLimitExceeded:
            return "Wait a few minutes before trying again"
        case .brokerageNotSupported:
            return "Check our supported brokerages list"
        case .missingData:
            return "Contact support if this continues"
        case .invalidURL, .signatureGenerationFailed:
            return "Please try again"
        case .apiError, .httpError, .decodingError:
            return "If this persists, contact support"
        case .noAccountsFound:
            return "Connect a brokerage account first"
        case .noHoldingsFound:
            return "Ensure your brokerage account has holdings"
        }
    }
}