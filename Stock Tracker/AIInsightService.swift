//
//  AIInsightService.swift
//  Stock Tracker
//
//  Centralized AI insight engine. Manages shared daily query counter,
//  caches insight results, and provides typed methods for each feature.
//

import Foundation
import SwiftUI
import Combine
import OSLog

// MARK: - Insight Types

enum InsightType: String {
    case dailyBriefing
    case portfolioHealth
    case watchlistSpotlight
    case newsDigest
    case earningsPreview
    case holdingInsight
    case diversificationScore
}

struct CachedInsight: Identifiable {
    let id: String
    let text: String
    let generatedAt: Date
    let insightType: InsightType
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(generatedAt) > ttl
    }
}

// MARK: - AIInsightService

@MainActor
class AIInsightService: ObservableObject {

    static let shared = AIInsightService()

    // Shared daily query counter (used by both chat and insights)
    @AppStorage("aiQueryCount") var queryCount: Int = 0
    @AppStorage("aiQueryDate") var queryDateString: String = ""

    @Published var insightCache: [String: CachedInsight] = [:]
    @Published var loadingInsights: Set<String> = []

    private let aiService = AIAgentService()

    /// Rate limiter: tracks last request time so we enforce a minimum gap.
    private var lastRequestTime: Date = .distantPast
    private static let minRequestGap: TimeInterval = 8.0

    private init() {}

    /// Waits until enough time has passed since the last AI request.
    private func enforceRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let remaining = Self.minRequestGap - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    // MARK: - Daily Counter

    var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    var todayQueryCount: Int {
        queryDateString == todayString ? queryCount : 0
    }

    func canQuery(tier: SubscriptionTier) -> Bool {
        guard let limit = FeatureGate.aiDailyQueryLimit(for: tier) else { return true }
        if limit == 0 { return false }
        return todayQueryCount < limit
    }

    func remainingQueries(tier: SubscriptionTier) -> Int? {
        guard let limit = FeatureGate.aiDailyQueryLimit(for: tier) else { return nil }
        return max(0, limit - todayQueryCount)
    }

    func incrementQueryCount() {
        if queryDateString != todayString {
            queryDateString = todayString
            queryCount = 0
        }
        queryCount += 1
    }

    // MARK: - Cache

    func cached(_ key: String) -> CachedInsight? {
        guard let insight = insightCache[key], !insight.isExpired else {
            return nil
        }
        return insight
    }

    /// Remove expired entries — call outside of view body (e.g. on appear, after generation).
    func cleanExpiredCache() {
        insightCache = insightCache.filter { !$0.value.isExpired }
    }

    // MARK: - Core Generation

    /// Sends a focused insight prompt and caches the result. Returns the AI text.
    func generateInsight(
        key: String,
        type: InsightType,
        systemPrompt: String,
        userPrompt: String,
        tier: SubscriptionTier,
        ttl: TimeInterval = 14400, // 4 hours default
        maxTokens: Int = 150
    ) async -> String? {
        // Opportunistic cleanup of expired entries
        cleanExpiredCache()

        // Check cache first
        if let hit = cached(key) { return hit.text }

        // Tier check
        guard canQuery(tier: tier) else { return nil }

        // Mark loading
        loadingInsights.insert(key)
        defer { loadingInsights.remove(key) }

        // Enforce rate limit — waits if last request was too recent
        await enforceRateLimit()

        let systemMsg = ChatMessage(text: systemPrompt, isUser: false, role: "system")
        let userMsg = ChatMessage(text: userPrompt, isUser: true)

        do {
            let response = try await aiService.sendMessage(messages: [systemMsg, userMsg])
            let insight = CachedInsight(
                id: key,
                text: response,
                generatedAt: Date(),
                insightType: type,
                ttl: ttl
            )
            insightCache[key] = insight
            incrementQueryCount()
            return response
        } catch {
            AppLogger.api.error("AI insight generation failed for \(key): \(error.localizedDescription)")
            return nil
        }
    }

    /// Force regenerate (ignores cache)
    func regenerateInsight(
        key: String,
        type: InsightType,
        systemPrompt: String,
        userPrompt: String,
        tier: SubscriptionTier,
        ttl: TimeInterval = 14400,
        maxTokens: Int = 150
    ) async -> String? {
        insightCache.removeValue(forKey: key)
        return await generateInsight(
            key: key, type: type,
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            tier: tier, ttl: ttl, maxTokens: maxTokens
        )
    }

    // MARK: - Invalidation

    func invalidateInsights(ofType type: InsightType) {
        insightCache = insightCache.filter { $0.value.insightType != type }
    }

    func invalidateAll() {
        insightCache.removeAll()
    }
}
