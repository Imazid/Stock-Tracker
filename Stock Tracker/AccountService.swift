//
//  AccountService.swift
//  Stock Tracker
//
//  Whether Stock Tracker's account service (Supabase) can be reached right now.
//  Sign-in, sign-up, onboarding's account step and Refer a friend all ask this
//  first, so when the service is down (its host stopped resolving on 2026-10-16)
//  they say so plainly instead of spinning or showing a raw URL error.
//

import Foundation
import Combine
import OSLog

@MainActor
final class AccountService: ObservableObject {
    static let shared = AccountService()

    enum Status: Equatable {
        case unknown, checking, available, unavailable, offline
    }

    @Published private(set) var status: Status = .unknown
    private var checkedAt: Date?
    private var inFlight: Task<Status, Never>?

    var isUnavailable: Bool { status == .unavailable || status == .offline }

    /// Pings the auth health endpoint with a short deadline. Answers are reused for
    /// 30 seconds unless `force` is set (a Retry tap). Never takes longer than ~6s.
    @discardableResult
    func check(force: Bool = false) async -> Status {
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 30,
           status == .available || status == .unavailable || status == .offline {
            return status
        }
        if let inFlight { return await inFlight.value }

        guard SupabaseManager.isConfigured,
              let base = URL(string: SecretsConfig.supabaseURL) else {
            status = .unavailable
            checkedAt = Date()
            return status
        }
        status = .checking
        let task = Task<Status, Never> {
            var request = URLRequest(url: base.appending(path: "auth/v1/health"), timeoutInterval: 6)
            request.setValue(SecretsConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (200..<500).contains(code) ? .available : .unavailable
            } catch let error as URLError where Self.offlineCodes.contains(error.code) {
                return .offline
            } catch {
                return .unavailable
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if result != status || checkedAt == nil {
            AppLogger.sync.info("Account service check: \(String(describing: result))")
        }
        status = result
        checkedAt = Date()
        return result
    }

    /// Marks the service down after a sign-in or fetch failed for a network reason,
    /// so other screens don't each wait out their own timeout.
    func noteFailure(_ error: Error) {
        guard let urlError = (error as? URLError) ?? ((error as NSError).underlyingErrors.first as? URLError) else { return }
        if Self.offlineCodes.contains(urlError.code) {
            status = .offline
        } else if Self.unreachableCodes.contains(urlError.code) {
            status = .unavailable
        } else {
            return
        }
        checkedAt = Date()
    }

    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]
    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .networkConnectionLost,
        .secureConnectionFailed, .badServerResponse
    ]
}

enum AccountServiceError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "The account service didn't answer in time."
    }
}

/// Runs `operation`, throwing `AccountServiceError.timedOut` if it takes longer
/// than `seconds` — account calls otherwise wait out URLSession's 60s default.
func withAccountDeadline<T: Sendable>(seconds: Double = 15,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AccountServiceError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AccountServiceError.timedOut }
        return first
    }
}
