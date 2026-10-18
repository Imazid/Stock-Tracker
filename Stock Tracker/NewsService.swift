//
//  NewsService.swift
//  Stock Tracker
//
//  Domain service responsible for fetching financial news articles.
//  Pagination cursor lives in MarketData; this service is stateless.
//

import Foundation
import OSLog

// MARK: - Protocol

@MainActor
protocol NewsServiceProtocol: AnyObject {
    func fetchPage(_ page: Int) async throws -> [NewsArticle]
}

// MARK: - Implementation

@MainActor
final class NewsService: NewsServiceProtocol {

    private let api: APIService

    init(api: APIService? = nil) {
        self.api = api ?? .shared
    }

    func fetchPage(_ page: Int) async throws -> [NewsArticle] {
        AppLogger.news.debug("Fetching news page \(page)")
        return try await api.fetchNews(page: page)
    }

    /// Placeholder articles shown before the first network fetch completes.
}
