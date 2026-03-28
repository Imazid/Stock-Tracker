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
    func mockArticles() -> [NewsArticle]
}

// MARK: - Implementation

@MainActor
final class NewsService: NewsServiceProtocol {

    private let api: APIService

    init(api: APIService = .shared) {
        self.api = api
    }

    func fetchPage(_ page: Int) async throws -> [NewsArticle] {
        AppLogger.news.debug("Fetching news page \(page)")
        return try await api.fetchNews(page: page)
    }

    /// Placeholder articles shown before the first network fetch completes.
    func mockArticles() -> [NewsArticle] {
        [
            NewsArticle(
                title: "Apple Announces New AI Features for iPhone",
                source: "Bloomberg",
                url: "https://example.com/aapl-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-3_600),
                summary: "Apple unveils a suite of new AI-powered features for the upcoming iOS release.",
                relatedSymbols: ["AAPL"]
            ),
            NewsArticle(
                title: "Bitcoin Breaks Above $60K",
                source: "CoinDesk",
                url: "https://example.com/btc-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-7_200),
                summary: "Bitcoin rallies past the $60,000 mark amid renewed institutional interest.",
                relatedSymbols: ["BTC"]
            ),
            NewsArticle(
                title: "Tesla Expands Production in Europe",
                source: "Reuters",
                url: "https://example.com/tsla-news-1",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(-10_800),
                summary: "Tesla announces a new Gigafactory in Eastern Europe to boost production capacity.",
                relatedSymbols: ["TSLA"]
            )
        ]
    }
}
