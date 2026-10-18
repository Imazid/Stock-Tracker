//
//  NewsViewModel.swift
//  Stock Tracker
//
//  Owns news filter/search state and computes filteredNews via Combine.
//  Set intersection logic runs only when articles, filter, or search text change.
//

import Foundation
import Combine
import OSLog

@MainActor
final class NewsViewModel: ObservableObject {

    @Published var selectedFilter: NewsFilter = .all
    @Published var searchText: String = ""
    @Published private(set) var filteredNews: [NewsArticle] = []
    /// True while per-symbol news for the Watchlist/Holdings filter is loading.
    @Published private(set) var isLoadingCompanyNews = false

    /// Per-symbol articles for the Watchlist/Portfolio filters. Finnhub's general feed
    /// (`/news`) never sets `related`, so without these those filters were always empty.
    @Published private var companyArticles: [NewsArticle] = []
    private var companyNewsFetchedAt: [String: Date] = [:]
    private var companyNewsTask: Task<Void, Never>?

    private static let companyNewsTTL: TimeInterval = 15 * 60
    private static let maxCompanyNewsSymbols = 10

    private var cancellables = Set<AnyCancellable>()

    /// Call once from NewsView.onAppear to wire up reactive updates.
    func observe(_ marketData: MarketData) {
        guard cancellables.isEmpty else { return }   // idempotent

        Publishers.CombineLatest4(
            marketData.$newsArticles,
            marketData.$watchlist,
            marketData.$portfolio,
            $selectedFilter
        )
        .combineLatest($searchText, $companyArticles)
        .map { args, search, company -> [NewsArticle] in
            let (articles, watchlist, portfolio, filter) = args
            var news = articles

            switch filter {
            case .all:
                break
            case .watchlist:
                let symbols = Set(watchlist.map { $0.symbol })
                news = Self.merged(articles, company).filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
            case .portfolio:
                let symbols = Set(portfolio.map { $0.asset.symbol })
                news = Self.merged(articles, company).filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
            }

            if !search.isEmpty {
                let q = search.lowercased()
                news = news.filter {
                    $0.title.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q)
                    || $0.source.lowercased().contains(q)
                    || $0.relatedSymbols.contains { $0.lowercased() == q }
                }
            }

            // Feeds repeat stories (same headline, different link); show each once.
            var seenTitles = Set<String>()
            return news
                .sorted { $0.publishedAt > $1.publishedAt }
                .filter { article in
                    let key = article.title.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                    return seenTitles.insert(key.isEmpty ? article.url : key).inserted
                }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$filteredNews)

        // Load per-symbol news when a holdings-based filter is selected (or holdings change).
        Publishers.CombineLatest3($selectedFilter, marketData.$watchlist, marketData.$portfolio)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] filter, watchlist, portfolio in
                switch filter {
                case .all:       return
                case .watchlist: self?.loadCompanyNews(for: watchlist)
                case .portfolio: self?.loadCompanyNews(for: portfolio.map { $0.asset })
                }
            }
            .store(in: &cancellables)
    }

    /// De-duplicates by URL, preferring the general-feed copy.
    private static func merged(_ general: [NewsArticle], _ company: [NewsArticle]) -> [NewsArticle] {
        var seen = Set(general.map { $0.url })
        var result = general
        for article in company where seen.insert(article.url).inserted {
            result.append(article)
        }
        return result
    }

    /// Finnhub's free company-news covers US listings only (ASX → 403), and not crypto.
    static func hasCompanyNewsCoverage(_ asset: Asset) -> Bool {
        guard asset.kind == .stock, asset.exchange != "ASX", asset.exchange != "International",
              !asset.symbol.hasSuffix(".AX") else { return false }
        // Older assets with no exchange: fall back to the popular-ASX list.
        if asset.exchange.isEmpty { return !QuoteService.popularASXSymbols.contains(asset.symbol.uppercased()) }
        return true
    }

    func hasNewsCoverage(for assets: [Asset]) -> Bool {
        assets.contains(where: Self.hasCompanyNewsCoverage)
    }

    private func loadCompanyNews(for assets: [Asset]) {
        let now = Date()
        let symbols = assets
            .filter(Self.hasCompanyNewsCoverage)
            .map { $0.symbol.uppercased() }
            .filter { symbol in
                guard let last = companyNewsFetchedAt[symbol] else { return true }
                return now.timeIntervalSince(last) > Self.companyNewsTTL
            }
        let unique = Array(NSOrderedSet(array: symbols).compactMap { $0 as? String }
            .prefix(Self.maxCompanyNewsSymbols))
        guard !unique.isEmpty, companyNewsTask == nil else { return }

        isLoadingCompanyNews = true
        companyNewsTask = Task { [weak self] in
            for symbol in unique {
                do {
                    let articles = try await APIService.shared.fetchCompanyNews(symbol: symbol)
                    guard let self else { return }
                    self.companyNewsFetchedAt[symbol] = Date()
                    self.companyArticles.removeAll { $0.relatedSymbols == [symbol] }
                    self.companyArticles.append(contentsOf: articles)
                } catch {
                    AppLogger.news.warning("Company news failed for \(symbol): \(error.localizedDescription)")
                }
            }
            self?.companyNewsTask = nil
            self?.isLoadingCompanyNews = false
        }
    }
}
