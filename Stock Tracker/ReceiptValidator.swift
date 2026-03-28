//
//  ReceiptValidator.swift
//  Stock Tracker
//
//  Server-side StoreKit 2 transaction validation with a local cryptographic fallback.
//
//  Architecture:
//    ChainedReceiptValidator  (primary → fallback)
//    ├── ServerReceiptValidator   (POST transaction ID to your backend)
//    └── LocalReceiptValidator    (StoreKit 2 already verified via checkVerified())
//
//  To activate server-side validation:
//    1. Set Constants.URLs.receiptValidation to your backend endpoint.
//    2. Your server should call Apple's App Store Server API (/inApps/v1/lookup)
//       and return { "tier": "Pro"|"Black"|"Free", "expires_at": <unix timestamp> }.
//
//  Until the server is live, all calls fall through to LocalReceiptValidator.
//

import Foundation
import OSLog

// MARK: - Result

enum ValidationResult {
    /// Transaction confirmed valid; tier and optional expiry from the validator.
    case valid(tier: SubscriptionTier, expiresAt: Date?)
    /// Transaction explicitly rejected (refund, fraud, test).
    case invalid
    /// Transient error (network, server down); caller should preserve current state.
    case networkError(String)
}

// MARK: - Protocol

protocol ReceiptValidatorProtocol {
    func validate(transactionID: UInt64, productID: String) async -> ValidationResult
}

// MARK: - Server-side Validator

/// Sends the transaction ID to your backend for server-authoritative validation.
/// Falls through to `.networkError` if the server is unreachable, returning control
/// to `ChainedReceiptValidator` which will use the local fallback.
final class ServerReceiptValidator: ReceiptValidatorProtocol {

    private let endpoint: URL

    init(endpoint: URL = URL(string: Constants.URLs.receiptValidation)!) {
        self.endpoint = endpoint
    }

    func validate(transactionID: UInt64, productID: String) async -> ValidationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "transaction_id": transactionID,
            "product_id":     productID,
            "bundle_id":      Bundle.main.bundleIdentifier ?? ""
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.store.warning("Server validation non-200 for tx \(transactionID); will fall back to local")
                return .networkError("Non-200 response")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tierString = json["tier"] as? String,
                  let tier = SubscriptionTier(rawValue: tierString.capitalized) else {
                return .networkError("Invalid response format")
            }

            let expiresAt: Date? = (json["expires_at"] as? TimeInterval)
                .map { Date(timeIntervalSince1970: $0) }

            AppLogger.store.info("Server validated tx \(transactionID) → \(tier.rawValue)")
            return .valid(tier: tier, expiresAt: expiresAt)

        } catch {
            AppLogger.store.warning("Server validator network error: \(error.localizedDescription)")
            return .networkError(error.localizedDescription)
        }
    }
}

// MARK: - Local Fallback Validator

/// Passes through because StoreKit 2's `checkVerified()` already performs
/// cryptographic signature validation before we reach this point.
/// This validator resolves the tier from the product ID alone.
final class LocalReceiptValidator: ReceiptValidatorProtocol {

    func validate(transactionID: UInt64, productID: String) async -> ValidationResult {
        AppLogger.store.debug("Local validation for tx \(transactionID), product \(productID, privacy: .public)")
        return .valid(tier: Self.resolveTier(productID), expiresAt: nil)
    }

    static func resolveTier(_ productID: String) -> SubscriptionTier {
        switch productID {
        case SubscriptionManager.ProductID.blackMonthly,
             SubscriptionManager.ProductID.blackYearly:
            return .black
        case SubscriptionManager.ProductID.proMonthly,
             SubscriptionManager.ProductID.proYearly:
            return .pro
        default:
            return .free
        }
    }
}

// MARK: - Chained Validator (server → local fallback)

/// Tries the primary validator first. On `.networkError`, automatically retries
/// with the fallback. Hard `.invalid` results are respected from either validator.
final class ChainedReceiptValidator: ReceiptValidatorProtocol {

    private let primary: any ReceiptValidatorProtocol
    private let fallback: any ReceiptValidatorProtocol

    init(
        primary: any ReceiptValidatorProtocol = ServerReceiptValidator(),
        fallback: any ReceiptValidatorProtocol = LocalReceiptValidator()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func validate(transactionID: UInt64, productID: String) async -> ValidationResult {
        let result = await primary.validate(transactionID: transactionID, productID: productID)
        switch result {
        case .valid, .invalid:
            return result
        case .networkError(let reason):
            AppLogger.store.warning("Primary validator failed (\(reason)); using local fallback for tx \(transactionID)")
            return await fallback.validate(transactionID: transactionID, productID: productID)
        }
    }
}
