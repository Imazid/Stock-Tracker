//
//  ReferralModels.swift
//  Stock Tracker
//
//  Domain models + Supabase DTOs for the referral program.
//  Follows the same pattern as SyncModels.swift:
//    - CodingKeys map camelCase → Postgres snake_case
//    - toDomain() converts remote row → domain model
//    - Encodable payloads use snake_case for INSERT/UPDATE
//

import Foundation

// MARK: - ISO 8601 formatter (referral-local, mirrors SyncModels)

private let referralISO8601Full: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let referralISO8601Basic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseReferralDate(_ string: String) -> Date {
    referralISO8601Full.date(from: string)
        ?? referralISO8601Basic.date(from: string)
        ?? Date()
}

private func parseReferralDateOptional(_ string: String?) -> Date? {
    guard let string else { return nil }
    return referralISO8601Full.date(from: string)
        ?? referralISO8601Basic.date(from: string)
}

// MARK: - Referral Status

enum ReferralStatus: String, Codable, CaseIterable {
    case pending   = "pending"
    case qualified = "qualified"
    case rewarded  = "rewarded"
    case expired   = "expired"
    case blocked   = "blocked"

    var displayName: String {
        rawValue.capitalized
    }

    var iconName: String {
        switch self {
        case .pending:   return "clock"
        case .qualified: return "checkmark.circle"
        case .rewarded:  return "gift.fill"
        case .expired:   return "clock.badge.xmark"
        case .blocked:   return "xmark.shield"
        }
    }
}

// MARK: - Qualification Event

enum QualificationEvent: String {
    case signedUp         = "signed_up"
    case portfolioCreated = "portfolio_created"
    case firstHolding     = "first_holding"
}

// MARK: - Validation Result

enum ReferralValidationResult {
    case valid(referrerId: UUID)
    case invalid(reason: String)
}

// MARK: - Domain Models

struct ReferralCode: Codable, Equatable {
    let id: UUID
    let userId: UUID
    let code: String
    let isActive: Bool
    let createdAt: Date
}

struct Referral: Identifiable, Codable, Equatable {
    let id: UUID
    let referrerId: UUID
    let refereeId: UUID
    let codeUsed: String
    let status: ReferralStatus
    let signedUpAt: Date?
    let portfolioCreatedAt: Date?
    let firstHoldingAt: Date?
    let expiresAt: Date
    let createdAt: Date

    var isExpired: Bool { expiresAt < Date() }

    var qualificationProgress: Int {
        var count = 0
        if signedUpAt != nil { count += 1 }
        if portfolioCreatedAt != nil { count += 1 }
        if firstHoldingAt != nil { count += 1 }
        return count
    }
}

struct ReferralStats: Equatable {
    let totalReferred: Int
    let pendingCount: Int
    let qualifiedCount: Int
    let rewardedCount: Int
    let referrals: [Referral]

    static let empty = ReferralStats(
        totalReferred: 0,
        pendingCount: 0,
        qualifiedCount: 0,
        rewardedCount: 0,
        referrals: []
    )
}

// MARK: - Supabase DTOs

struct RemoteReferralCode: Codable {
    let id: String
    let userId: String
    let code: String
    let isActive: Bool
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case code
        case isActive  = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func toDomain() -> ReferralCode {
        ReferralCode(
            id: UUID(uuidString: id) ?? UUID(),
            userId: UUID(uuidString: userId) ?? UUID(),
            code: code,
            isActive: isActive,
            createdAt: parseReferralDate(createdAt)
        )
    }
}

struct RemoteReferral: Codable {
    let id: String
    let referrerId: String
    let refereeId: String
    let codeUsed: String
    let status: String
    let signedUpAt: String?
    let portfolioCreatedAt: String?
    let firstHoldingAt: String?
    let blockReason: String?
    let expiresAt: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case referrerId         = "referrer_id"
        case refereeId          = "referee_id"
        case codeUsed           = "code_used"
        case status
        case signedUpAt         = "signed_up_at"
        case portfolioCreatedAt = "portfolio_created_at"
        case firstHoldingAt     = "first_holding_at"
        case blockReason        = "block_reason"
        case expiresAt          = "expires_at"
        case createdAt          = "created_at"
        case updatedAt          = "updated_at"
    }

    func toDomain() -> Referral {
        Referral(
            id: UUID(uuidString: id) ?? UUID(),
            referrerId: UUID(uuidString: referrerId) ?? UUID(),
            refereeId: UUID(uuidString: refereeId) ?? UUID(),
            codeUsed: codeUsed,
            status: ReferralStatus(rawValue: status) ?? .pending,
            signedUpAt: parseReferralDateOptional(signedUpAt),
            portfolioCreatedAt: parseReferralDateOptional(portfolioCreatedAt),
            firstHoldingAt: parseReferralDateOptional(firstHoldingAt),
            expiresAt: parseReferralDate(expiresAt),
            createdAt: parseReferralDate(createdAt)
        )
    }
}

// MARK: - Insert / Update Payloads

struct ReferralAttachPayload: Encodable {
    let referee_id: String
    let referrer_id: String
    let code_used: String
}

struct ReferralQualificationUpdate: Encodable {
    let portfolio_created_at: String?
    let first_holding_at: String?
    let status: String?
    let updated_at: String

    init(event: QualificationEvent, existingReferral: Referral) {
        let now = ISO8601DateFormatter().string(from: Date())
        self.updated_at = now

        switch event {
        case .signedUp:
            // signed_up_at is set by default on INSERT, no update needed
            self.portfolio_created_at = nil
            self.first_holding_at = nil
        case .portfolioCreated:
            self.portfolio_created_at = existingReferral.portfolioCreatedAt == nil ? now : nil
            self.first_holding_at = nil
        case .firstHolding:
            self.portfolio_created_at = nil
            self.first_holding_at = existingReferral.firstHoldingAt == nil ? now : nil
        }

        // Check if all events are now complete → qualified
        let willHaveSignup = existingReferral.signedUpAt != nil
        let willHavePortfolio = existingReferral.portfolioCreatedAt != nil || event == .portfolioCreated
        let willHaveHolding = existingReferral.firstHoldingAt != nil || event == .firstHolding

        if willHaveSignup && willHavePortfolio && willHaveHolding
            && existingReferral.status == .pending {
            self.status = ReferralStatus.qualified.rawValue
        } else {
            self.status = nil
        }
    }
}
