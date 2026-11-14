import Foundation

struct CoinFacts: Decodable, Sendable, Equatable {
    struct Platform: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let contract: String
    }

    let id: String
    let symbol: String
    let name: String
    let sourceURL: URL
    let observedAt: String?
    let rank: Int?
    let marketCap: Double?
    let fullyDilutedValuation: Double?
    let volume24h: Double?
    let high24h: Double?
    let low24h: Double?
    let circulatingSupply: Double?
    let totalSupply: Double?
    let maxSupply: Double?
    let unlimitedSupply: Bool
    let allTimeHigh: Double?
    let allTimeHighDate: String?
    let launchedOn: String?
    let about: String?
    let homepage: URL?
    let explorers: [URL]
    let platforms: [Platform]

    var marketDate: Date? {
        guard let observedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: observedAt) ?? ISO8601DateFormatter().date(from: observedAt)
    }
}

@MainActor
final class CoinGeckoCoinService {
    static let shared = CoinGeckoCoinService()

    private var cache: [String: (facts: CoinFacts, fetchedAt: Date)] = [:]
    private var inFlight: [String: Task<CoinFacts, Error>] = [:]
    private let ttl: TimeInterval = 5 * 60

    enum CoinError: LocalizedError {
        case unavailable
        var errorDescription: String? { "CoinGecko token research is temporarily unavailable." }
    }

    func facts(for symbol: String) async throws -> CoinFacts {
        if let hit = cache[symbol], Date().timeIntervalSince(hit.fetchedAt) < ttl { return hit.facts }
        if let running = inFlight[symbol] { return try await running.value }

        let task = Task { () throws -> CoinFacts in
            let data = try await SecureBackend.invoke("market-workspace", body: ["action": "cryptoFacts", "symbol": symbol],
                                                      requiresSession: false)
            struct Reply: Decodable { let data: CoinFacts }
            let facts = try JSONDecoder().decode(Reply.self, from: data).data
            guard facts.symbol == symbol else { throw CoinError.unavailable }
            return facts
        }
        inFlight[symbol] = task
        defer { inFlight[symbol] = nil }
        let facts = try await task.value
        cache[symbol] = (facts, Date())
        return facts
    }
}
