//
//  CoinGeckoCoinService.swift
//  Stock Tracker
//
//  Coin facts for the crypto detail screen (market cap, 24h volume and range,
//  supply, all-time high, description) from CoinGecko `/coins/{id}`.
//  Free, no key needed (a Demo key is used when configured); shares the app's
//  CoinGecko rate limiter and caches each coin for 10 minutes. All amounts are
//  USD, matching the app's money invariant.
//

import Foundation
import OSLog

struct CoinFacts: Sendable, Equatable {
    let id: String
    let name: String
    let rank: Int?
    let marketCap: Double?
    let fullyDilutedValuation: Double?
    let volume24h: Double?
    let high24h: Double?
    let low24h: Double?
    let circulatingSupply: Double?
    let totalSupply: Double?
    let maxSupply: Double?
    let allTimeHigh: Double?
    let allTimeHighDate: Date?
    let about: String?
    let homepage: URL?
}

@MainActor
final class CoinGeckoCoinService {
    static let shared = CoinGeckoCoinService()

    private var cache: [String: (facts: CoinFacts, fetchedAt: Date)] = [:]
    private var inFlight: [String: Task<CoinFacts, Error>] = [:]
    private let ttl: TimeInterval = 10 * 60

    enum CoinError: LocalizedError {
        case unavailable(Int)
        var errorDescription: String? { "Coin details are unavailable right now." }
    }

    func facts(for coinID: String) async throws -> CoinFacts {
        if let hit = cache[coinID], Date().timeIntervalSince(hit.fetchedAt) < ttl { return hit.facts }
        if let running = inFlight[coinID] { return try await running.value }

        let task = Task { () throws -> CoinFacts in
            var components = URLComponents(string: "https://api.coingecko.com/api/v3/coins/\(coinID)")!
            components.queryItems = [
                URLQueryItem(name: "localization", value: "false"),
                URLQueryItem(name: "tickers", value: "false"),
                URLQueryItem(name: "market_data", value: "true"),
                URLQueryItem(name: "community_data", value: "false"),
                URLQueryItem(name: "developer_data", value: "false"),
                URLQueryItem(name: "sparkline", value: "false")
            ]
            var request = URLRequest(url: components.url!)
            let key = SecretsConfig.coinGeckoAPIKey
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key") }
            let (data, response) = try await URLSession.shared.rateLimitedData(
                for: request, endpoint: "coinGecko", config: .coinGecko)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                AppLogger.api.warning("CoinGecko coin \(coinID) HTTP \(status)")
                throw CoinError.unavailable(status)
            }
            return try Self.parse(data, id: coinID)
        }
        inFlight[coinID] = task
        defer { inFlight[coinID] = nil }
        do {
            let facts = try await task.value
            cache[coinID] = (facts, Date())
            return facts
        } catch {
            if let stale = cache[coinID] { return stale.facts }
            throw error
        }
    }

    nonisolated private static func parse(_ data: Data, id: String) throws -> CoinFacts {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoinError.unavailable(0)
        }
        let market = json["market_data"] as? [String: Any] ?? [:]
        func usd(_ key: String) -> Double? {
            guard let dict = market[key] as? [String: Any], let v = dict["usd"] as? Double, v.isFinite, v > 0 else { return nil }
            return v
        }
        func number(_ key: String) -> Double? {
            guard let v = market[key] as? Double, v.isFinite, v > 0 else { return nil }
            return v
        }
        let athDate: Date? = {
            guard let dict = market["ath_date"] as? [String: Any], let raw = dict["usd"] as? String else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }()
        let about: String? = {
            guard let dict = json["description"] as? [String: Any], let raw = dict["en"] as? String else { return nil }
            let text = plainText(raw)
            return text.isEmpty ? nil : text
        }()
        let homepage: URL? = {
            guard let links = json["links"] as? [String: Any],
                  let pages = links["homepage"] as? [String],
                  let first = pages.first(where: { !$0.isEmpty }) else { return nil }
            return URL(string: first)
        }()
        return CoinFacts(
            id: id,
            name: json["name"] as? String ?? id.capitalized,
            rank: json["market_cap_rank"] as? Int,
            marketCap: usd("market_cap"),
            fullyDilutedValuation: usd("fully_diluted_valuation"),
            volume24h: usd("total_volume"),
            high24h: usd("high_24h"),
            low24h: usd("low_24h"),
            circulatingSupply: number("circulating_supply"),
            totalSupply: number("total_supply"),
            maxSupply: number("max_supply"),
            allTimeHigh: usd("ath"),
            allTimeHighDate: athDate,
            about: about,
            homepage: homepage
        )
    }

    /// CoinGecko descriptions are HTML fragments ("<a href=…>Bitcoin</a>"); keep the words.
    nonisolated static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
