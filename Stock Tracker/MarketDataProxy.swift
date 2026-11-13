import Foundation
import Supabase

/// Routes keyed market-data calls through the server for signed-in accounts.
@MainActor
enum MarketDataProxy {
    static func available(debugKey: String) -> Bool {
        if SupabaseManager.isConfigured { return true }
        #if DEBUG
        return !debugKey.isEmpty
        #else
        return false
        #endif
    }

    static func data(for url: URL, using session: URLSession,
                     provider: String? = nil, direct: URLRequest? = nil,
                     config: APIRateLimiter.EndpointConfig = .alpaca) async throws -> (Data, URLResponse) {
        if SupabaseManager.isConfigured, let base = URL(string: SecretsConfig.supabaseURL),
           let accessToken = try? await SupabaseManager.auth.session.accessToken,
           let upstream = URLComponents(url: url, resolvingAgainstBaseURL: false),
           var proxy = URLComponents(url: base.appendingPathComponent("functions/v1/market-data-proxy"),
                                     resolvingAgainstBaseURL: false) {
            var items = [URLQueryItem(name: "path", value: upstream.path)]
            if let provider { items.append(URLQueryItem(name: "provider", value: provider)) }
            items += (upstream.queryItems ?? []).filter { !["token", "apikey"].contains($0.name) }
            proxy.queryItems = items
            guard let proxyURL = proxy.url else { throw URLError(.badURL) }
            var request = URLRequest(url: proxyURL)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(SecretsConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
            // The shared GET cache is keyed by URL alone. Keep authenticated requests out of it.
            return try await session.data(for: request)
        }

        #if DEBUG
        if !SupabaseManager.isConfigured, let direct, let provider {
            return try await session.rateLimitedData(for: direct, endpoint: provider, config: config)
        }
        let key = SecretsConfig.alpacaAPIKey
        let secret = SecretsConfig.alpacaSecretKey
        if provider == nil, !SupabaseManager.isConfigured, !key.isEmpty, !secret.isEmpty {
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "APCA-API-KEY-ID")
            request.setValue(secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
            return try await session.rateLimitedData(for: request, endpoint: "alpaca", config: .alpaca)
        }
        #endif

        throw URLError(.userAuthenticationRequired)
    }
}
