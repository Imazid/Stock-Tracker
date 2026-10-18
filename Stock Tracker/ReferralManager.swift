//
//  ReferralManager.swift
//  Stock Tracker
//
//  @MainActor ObservableObject singleton that bridges the ReferralService
//  layer to SwiftUI views. Published state drives the Refer & Earn UI.
//  Follows the same pattern as SyncManager.shared / SubscriptionManager.shared.
//

import Foundation
import Auth
import OSLog
import Combine

@MainActor
final class ReferralManager: ObservableObject {

    static let shared = ReferralManager()

    // MARK: - Published State

    @Published var myCode: ReferralCode?
    @Published var stats: ReferralStats?
    @Published var isLoading = false
    @Published var error: String?

    /// What the Refer a friend screen can show. Every load ends in one of the
    /// settled states — never an endless spinner.
    enum LoadState: Equatable {
        case idle, loading, ready, signedOut, unavailable, offline, failed
    }
    @Published private(set) var loadState: LoadState = .idle

    // MARK: - Private

    private let service: ReferralServiceProtocol
    private let persist = DataPersistenceManager.shared

    private init(service: ReferralServiceProtocol? = nil) {
        self.service = service ?? SupabaseReferralService()
        // Load cached code from Keychain immediately (offline-first)
        myCode = persist.loadReferralCode()
    }

    // MARK: - Screen load

    /// Checks the account service, then the person's code and stats (each with a
    /// deadline). A cached code is only shown once the service has answered —
    /// a code nobody can redeem isn't worth sharing.
    func refresh() async {
        loadState = .loading
        switch await AccountService.shared.check(force: true) {
        case .offline: loadState = .offline; return
        case .unavailable: loadState = .unavailable; return
        default: break
        }
        guard SupabaseManager.isConfigured else { loadState = .unavailable; return }
        guard SupabaseManager.auth.currentUser != nil else { loadState = .signedOut; return }

        let service = self.service
        do {
            let code = try await withAccountDeadline(seconds: 12) { try await service.fetchOrCreateCode() }
            myCode = code
            stats = try? await withAccountDeadline(seconds: 12) { try await service.fetchReferralStats() }
            error = nil
            loadState = .ready
        } catch {
            AppLogger.referral.error("Refer a friend failed to load: \(error)")
            AccountService.shared.noteFailure(error)
            self.error = error.localizedDescription
            switch AccountService.shared.status {
            case .offline: loadState = .offline
            case .unavailable: loadState = .unavailable
            default: loadState = error is AccountServiceError ? .unavailable : .failed
            }
        }
    }

    // MARK: - Load / Refresh Code

    func loadCode() async {
        guard SupabaseManager.isConfigured,
              SupabaseManager.auth.currentUser != nil else { return }

        do {
            let code = try await service.fetchOrCreateCode()
            myCode = code
            error = nil
        } catch {
            AppLogger.referral.error("Failed to load referral code: \(error)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Load Stats

    func loadStats() async {
        guard SupabaseManager.isConfigured,
              SupabaseManager.auth.currentUser != nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            stats = try await service.fetchReferralStats()
            error = nil
        } catch {
            AppLogger.referral.error("Failed to load referral stats: \(error)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Validate

    func validate(_ code: String) async -> ReferralValidationResult {
        guard SupabaseManager.isConfigured,
              SupabaseManager.auth.currentUser != nil else {
            return .invalid(reason: "Sign in to use referral codes")
        }

        do {
            return try await service.validateCode(code)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    // MARK: - Attach Referral

    func attachReferral(code: String) async throws {
        try await service.attachReferral(code: code)
        AppLogger.referral.info("Referral attached with code: \(code)")
    }

    // MARK: - Report Qualification Event (idempotent)

    func reportQualificationEvent(_ event: QualificationEvent) async {
        guard SupabaseManager.isConfigured,
              SupabaseManager.auth.currentUser != nil else { return }

        do {
            try await service.updateQualificationEvent(event)
        } catch {
            // Non-fatal — event will be retried on next opportunity
            AppLogger.referral.error("Qualification event \(event.rawValue) failed: \(error)")
        }
    }

    // MARK: - Consume Pending Referral Code

    /// Checks UserDefaults for a pending referral code (from deep link or onboarding),
    /// attaches it if found, then clears it. Safe to call multiple times.
    func consumePendingReferralCode() async {
        guard let pending = persist.loadPendingReferralCode(),
              !pending.isEmpty else { return }

        guard SupabaseManager.isConfigured,
              SupabaseManager.auth.currentUser != nil else { return }

        AppLogger.referral.info("Consuming pending referral code: \(pending)")

        do {
            try await attachReferral(code: pending)
            persist.clearPendingReferralCode()
        } catch {
            // If it's a permanent failure (self-referral, already referred), clear anyway
            if error is ReferralError {
                persist.clearPendingReferralCode()
            }
            // Otherwise leave it for retry on next sign-in
            AppLogger.referral.error("Failed to consume pending referral: \(error)")
        }
    }

    // MARK: - Sharing Helpers

    /// nil until `Constants.Referral.referralBaseURL` points at a real domain —
    /// it's still the "yourdomain.com" placeholder, and a dead link helps nobody.
    var shareURL: URL? {
        guard let code = myCode?.code,
              !Constants.Referral.referralBaseURL.contains("yourdomain") else { return nil }
        return URL(string: Constants.Referral.referralBaseURL + code)
    }

    var shareText: String {
        guard let code = myCode?.code else { return "Join me on Stock Tracker!" }
        if let url = shareURL {
            return "I track my stocks and crypto with Stock Tracker. Use my code \(code) when you sign up, or join here: \(url.absoluteString)"
        }
        return "I track my stocks and crypto with Stock Tracker. Use my code \(code) when you create your account."
    }
}
