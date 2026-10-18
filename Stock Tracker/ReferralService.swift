//
//  ReferralService.swift
//  Stock Tracker
//
//  Protocol-based referral service layer.
//  SupabaseReferralService uses SupabaseManager.client.from(...)
//  following the same pattern as SyncManager.
//

import Foundation
import Supabase
import Auth
import OSLog

// MARK: - Protocol

protocol ReferralServiceProtocol: Sendable {
    func fetchOrCreateCode() async throws -> ReferralCode
    func validateCode(_ code: String) async throws -> ReferralValidationResult
    func attachReferral(code: String) async throws
    func updateQualificationEvent(_ event: QualificationEvent) async throws
    func fetchReferralStats() async throws -> ReferralStats
}

// MARK: - Errors

enum ReferralError: LocalizedError {
    case notSignedIn
    case codeNotFound
    case selfReferral
    case alreadyReferred
    case referralExpired
    case maxReferralsReached
    case supabaseNotConfigured

    var errorDescription: String? {
        switch self {
        case .notSignedIn:          return "You must be signed in to use referrals."
        case .codeNotFound:         return "Referral code not found."
        case .selfReferral:         return "You cannot use your own referral code."
        case .alreadyReferred:      return "You have already used a referral code."
        case .referralExpired:      return "This referral has expired."
        case .maxReferralsReached:  return "Maximum referral limit reached."
        case .supabaseNotConfigured: return "Cloud sync is not configured."
        }
    }
}

// MARK: - Supabase Implementation

final class SupabaseReferralService: ReferralServiceProtocol {

    private var currentUserId: UUID? {
        SupabaseManager.auth.currentUser?.id
    }

    // MARK: - Fetch or Create Code

    func fetchOrCreateCode() async throws -> ReferralCode {
        guard SupabaseManager.isConfigured else { throw ReferralError.supabaseNotConfigured }
        guard let userId = currentUserId else { throw ReferralError.notSignedIn }

        // Try to fetch existing code first
        let existing: [RemoteReferralCode] = try await SupabaseManager.client
            .from("referral_codes")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        if let remote = existing.first {
            let code = remote.toDomain()
            DataPersistenceManager.shared.saveReferralCode(code)
            return code
        }

        // Generate via RPC
        let _: String = try await SupabaseManager.client
            .rpc("generate_referral_code", params: ["p_user_id": userId.uuidString])
            .execute()
            .value

        // Fetch the newly created code
        let created: [RemoteReferralCode] = try await SupabaseManager.client
            .from("referral_codes")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        guard let remote = created.first else {
            throw ReferralError.codeNotFound
        }

        let code = remote.toDomain()
        DataPersistenceManager.shared.saveReferralCode(code)
        AppLogger.referral.info("Generated referral code: \(code.code)")
        return code
    }

    // MARK: - Validate Code

    func validateCode(_ code: String) async throws -> ReferralValidationResult {
        guard SupabaseManager.isConfigured else { throw ReferralError.supabaseNotConfigured }
        guard let userId = currentUserId else { throw ReferralError.notSignedIn }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Ask the server who owns the code. Codes aren't readable as a table: that let
        // any signed-in user list every code with its owner's account id.
        let owner: String? = try await SupabaseManager.client
            .rpc("referral_code_owner", params: ["p_code": trimmed])
            .execute()
            .value

        guard let referrerId = owner.flatMap(UUID.init(uuidString:)) else {
            return .invalid(reason: "Code not found")
        }

        // Self-referral check
        if referrerId == userId {
            return .invalid(reason: "You cannot use your own referral code")
        }

        // Already-referred check
        let existingReferrals: [RemoteReferral] = try await SupabaseManager.client
            .from("referrals")
            .select()
            .eq("referee_id", value: userId.uuidString)
            .execute()
            .value

        if !existingReferrals.isEmpty {
            return .invalid(reason: "You have already used a referral code")
        }

        return .valid(referrerId: referrerId)
    }

    // MARK: - Attach Referral

    func attachReferral(code: String) async throws {
        guard SupabaseManager.isConfigured else { throw ReferralError.supabaseNotConfigured }
        guard let userId = currentUserId else { throw ReferralError.notSignedIn }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Validate first
        let result = try await validateCode(trimmed)
        switch result {
        case .valid(let referrerId):
            let payload = ReferralAttachPayload(
                referee_id: userId.uuidString,
                referrer_id: referrerId.uuidString,
                code_used: trimmed
            )
            try await SupabaseManager.client
                .from("referrals")
                .insert(payload)
                .execute()

            AppLogger.referral.info("Attached referral: code=\(trimmed), referrer=\(referrerId)")

        case .invalid(let reason):
            AppLogger.referral.warning("Referral validation failed: \(reason)")
            switch reason {
            case _ where reason.contains("own"):    throw ReferralError.selfReferral
            case _ where reason.contains("already"): throw ReferralError.alreadyReferred
            default:                                  throw ReferralError.codeNotFound
            }
        }
    }

    // MARK: - Update Qualification Event

    func updateQualificationEvent(_ event: QualificationEvent) async throws {
        guard SupabaseManager.isConfigured else { throw ReferralError.supabaseNotConfigured }
        guard let userId = currentUserId else { throw ReferralError.notSignedIn }

        // Fetch the current user's referral record (as referee)
        let records: [RemoteReferral] = try await SupabaseManager.client
            .from("referrals")
            .select()
            .eq("referee_id", value: userId.uuidString)
            .execute()
            .value

        guard let remote = records.first else {
            // User was not referred — no-op
            return
        }

        let referral = remote.toDomain()

        // Check expiry
        if referral.isExpired {
            try await SupabaseManager.client
                .from("referrals")
                .update(["status": "expired", "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: remote.id)
                .execute()
            return
        }

        // Check if the event is already recorded (idempotent)
        switch event {
        case .signedUp where referral.signedUpAt != nil: return
        case .portfolioCreated where referral.portfolioCreatedAt != nil: return
        case .firstHolding where referral.firstHoldingAt != nil: return
        default: break
        }

        // Build the update payload
        let update = ReferralQualificationUpdate(event: event, existingReferral: referral)
        try await SupabaseManager.client
            .from("referrals")
            .update(update)
            .eq("id", value: remote.id)
            .execute()

        AppLogger.referral.info("Updated qualification event: \(event.rawValue) for referral \(remote.id)")
    }

    // MARK: - Fetch Stats

    func fetchReferralStats() async throws -> ReferralStats {
        guard SupabaseManager.isConfigured else { throw ReferralError.supabaseNotConfigured }
        guard let userId = currentUserId else { throw ReferralError.notSignedIn }

        let records: [RemoteReferral] = try await SupabaseManager.client
            .from("referrals")
            .select()
            .eq("referrer_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value

        let referrals = records.map { $0.toDomain() }
        return ReferralStats(
            totalReferred: referrals.count,
            pendingCount: referrals.filter { $0.status == .pending }.count,
            qualifiedCount: referrals.filter { $0.status == .qualified }.count,
            rewardedCount: referrals.filter { $0.status == .rewarded }.count,
            referrals: referrals
        )
    }
}

// MARK: - Mock Implementation (Previews)

final class MockReferralService: ReferralServiceProtocol {
    func fetchOrCreateCode() async throws -> ReferralCode {
        ReferralCode(
            id: UUID(),
            userId: UUID(),
            code: "DEMO-A1B2",
            isActive: true,
            createdAt: Date()
        )
    }

    func validateCode(_ code: String) async throws -> ReferralValidationResult {
        .valid(referrerId: UUID())
    }

    func attachReferral(code: String) async throws {}

    func updateQualificationEvent(_ event: QualificationEvent) async throws {}

    func fetchReferralStats() async throws -> ReferralStats {
        ReferralStats(
            totalReferred: 5,
            pendingCount: 2,
            qualifiedCount: 2,
            rewardedCount: 1,
            referrals: [
                Referral(
                    id: UUID(), referrerId: UUID(), refereeId: UUID(),
                    codeUsed: "DEMO-A1B2", status: .qualified,
                    signedUpAt: Date(), portfolioCreatedAt: Date(), firstHoldingAt: Date(),
                    expiresAt: Date().addingTimeInterval(86400 * 30), createdAt: Date()
                ),
                Referral(
                    id: UUID(), referrerId: UUID(), refereeId: UUID(),
                    codeUsed: "DEMO-A1B2", status: .pending,
                    signedUpAt: Date(), portfolioCreatedAt: nil, firstHoldingAt: nil,
                    expiresAt: Date().addingTimeInterval(86400 * 30), createdAt: Date()
                ),
            ]
        )
    }
}
