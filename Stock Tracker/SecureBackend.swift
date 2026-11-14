//
//  SecureBackend.swift
//  Stock Tracker
//
//  Calls the app's own Supabase Edge Functions with the signed-in user's session.
//
//  Provider secrets (SnapTrade's consumer key and each person's SnapTrade user secret, the
//  OpenAI and Gemini keys) live only on the server — see supabase/functions/snaptrade-proxy
//  and supabase/functions/ai-proxy. Release builds always go through here; Debug builds may
//  fall back to direct provider calls only while no Supabase project is configured, so a
//  developer can still run the app from a bare checkout.
//

import Foundation
import Supabase

enum SecureBackend {

    struct FunctionError: LocalizedError {
        let status: Int
        let code: String
        let message: String

        var errorDescription: String? { message }
    }

    /// True when the app can reach its Supabase project (URL + anon key configured).
    static var isConfigured: Bool { SupabaseManager.isConfigured }

    /// Whether a feature should use the server instead of calling a provider directly.
    /// Release builds never call providers with embedded keys.
    static var shouldUseServer: Bool {
        #if DEBUG
        return isConfigured
        #else
        return true
        #endif
    }

    private static let session = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 60)

    /// POSTs `body` to `functions/v1/<function>` and returns the response body on 2xx.
    /// Non-2xx responses become `FunctionError` with the server's machine-readable code.
    static func invoke(_ function: String, body: [String: Any], requiresSession: Bool = true,
                       expectedUserID: UUID? = nil, idempotencyKey: String? = nil) async throws -> Data {
        guard isConfigured, let base = URL(string: SecretsConfig.supabaseURL) else {
            throw FunctionError(status: 503, code: "BACKEND_NOT_CONFIGURED",
                                message: "This feature needs the Stock Tracker server, which isn't configured in this build.")
        }
        var accessToken: String?
        if requiresSession {
            do {
                let session = try await SupabaseManager.auth.session
                if let expectedUserID, session.user.id != expectedUserID { throw CancellationError() }
                accessToken = session.accessToken
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FunctionError(status: 401, code: "SIGN_IN_REQUIRED",
                                    message: "Sign in to your Stock Tracker account to use this feature.")
            }
        }

        var request = URLRequest(url: base.appendingPathComponent("functions/v1/\(function)"))
        request.httpMethod = "POST"
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.setValue(SecretsConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw decodeError(status: status, data: data)
        }
        return data
    }

    static func decodeError(status: Int, data: Data) -> FunctionError {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: String?; let message: String? }
            let error: Body?
        }
        let body = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        return FunctionError(status: status,
                             code: body?.code ?? "HTTP_\(status)",
                             message: body?.message ?? "The server returned an error (\(status)).")
    }
}
