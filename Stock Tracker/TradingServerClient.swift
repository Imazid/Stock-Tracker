//
//  TradingServerClient.swift
//  Stock Tracker
//
//  Talks to the `trading-api` edge function for a signed-in person. The server
//  runs the same engine as the phone (proven by shared test vectors), keeps
//  agents running while the app is closed, and is the record of truth when an
//  account is in use.
//
//  Every call carries the person's own session token; the server derives who
//  they are from it, never from the request body. Refusals come back with the
//  engine's own reasons, so the app can show them unchanged.
//

import Foundation
import OSLog
import Supabase
import TradingCore

enum TradingServerError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case unavailable(String)
    case refused(code: String, message: String, reasons: [String])
    case badReply

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Your account's trading server isn't set up in this build."
        case .notSignedIn: return "Sign in to use trading in your account."
        case .unavailable(let why): return why
        case .refused(_, let message, let reasons):
            // The engine's reasons are the useful part; the message is a summary of them.
            let extra = reasons.filter { !message.contains($0) }
            return ([message] + extra).joined(separator: " ")
        case .badReply: return "The trading server sent something the app couldn't read. Nothing was changed on this phone."
        }
    }

    /// The server is missing or not deployed (as opposed to refusing one request).
    var meansServerUnavailable: Bool {
        switch self {
        case .notConfigured, .unavailable, .badReply: return true
        case .refused(let code, _, _): return code == "unknown_action" || code == "internal"
        case .notSignedIn: return false
        }
    }
}

/// One successful reply: the action's own data, plus the state as saved after the change
/// when it was asked for.
struct TradingServerReply {
    let data: [String: Any]
    let state: TradingState?

    /// Decodes one field of the reply with the trading codec (millisecond dates).
    func decode<T: Decodable>(_ type: T.Type, at key: String) throws -> T {
        guard let value = data[key], JSONSerialization.isValidJSONObject(["v": value]) else { throw TradingServerError.badReply }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        do { return try TradingCodec.decoder().decode(T.self, from: bytes) } catch { throw TradingServerError.badReply }
    }
}

nonisolated struct TradingServerClient: Sendable {
    let baseURL: URL
    let anonKey: String
    /// Sends `"fixture": "ui-test"` with every request (UI tests against a local stack only).
    let fixture: String?
    private let session: URLSession

    init?(supabaseURL: String, anonKey: String, fixture: String? = nil) {
        guard !supabaseURL.isEmpty, !anonKey.isEmpty, supabaseURL != "https://placeholder.supabase.co",
              let url = URL(string: supabaseURL)?.appendingPathComponent("functions/v1/trading-api") else { return nil }
        self.baseURL = url
        self.anonKey = anonKey
        self.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Calls one action. `idempotencyKey` makes a repeated request (a retry after a dropped
    /// connection) return the first answer instead of doing the work twice.
    func call(_ action: String, _ body: [String: Any] = [:], includeState: Bool = true,
              idempotencyKey: String? = nil) async throws -> TradingServerReply {
        guard let token = try? await SupabaseManager.auth.session.accessToken, !token.isEmpty else {
            throw TradingServerError.notSignedIn
        }
        var payload = body
        payload["action"] = action
        if includeState { payload["includeState"] = true }
        if let fixture { payload["fixture"] = fixture }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TradingServerError.unavailable("The trading server couldn't be reached. Check your connection; nothing was changed.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A gateway page (no function deployed) or an empty body.
            throw status == 404 ? TradingServerError.unavailable("Your account's trading server isn't running yet.")
                : TradingServerError.badReply
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "http_\(status)"
            if status == 401 { throw TradingServerError.notSignedIn }
            let details = error["details"] as? [String: Any]
            let reasons = (details?["reasons"] as? [String]) ?? (error["reasons"] as? [String]) ?? []
            throw TradingServerError.refused(code: code, message: error["message"] as? String ?? "The trading server refused that.", reasons: reasons)
        }
        let payloadData = object["data"] as? [String: Any] ?? [:]
        var state: TradingState?
        if let raw = payloadData["state"] {
            do {
                let bytes = try JSONSerialization.data(withJSONObject: raw)
                state = try TradingCodec.decoder().decode(TradingState.self, from: bytes)
            } catch {
                AppLogger.sync.error("Trading state from the server couldn't be decoded: \(error.localizedDescription)")
                throw TradingServerError.badReply
            }
        }
        return TradingServerReply(data: payloadData, state: state)
    }

    /// The person's whole trading state.
    func state() async throws -> TradingState {
        let reply = try await call("state", includeState: false)
        if let state = reply.state { return state }
        return try reply.decode(TradingState.self, at: "state")
    }

    /// A Codable value as a JSON object for a request body, using the trading codec.
    static func json<T: Encodable>(_ value: T) throws -> Any {
        let bytes = try TradingCodec.encoder().encode(value)
        return try JSONSerialization.jsonObject(with: bytes)
    }
}
