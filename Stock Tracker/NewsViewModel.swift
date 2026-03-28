//
//  NewsViewModel.swift
//  Stock Tracker
//
//  Owns news filter/search state and computes filteredNews via Combine.
//  Set intersection logic runs only when articles, filter, or search text change.
//

import Foundation
import Combine

@MainActor
final class NewsViewModel: ObservableObject {

    @Published var selectedFilter: NewsFilter = .all
    @Published var searchText: String = ""
    @Published private(set) var filteredNews: [NewsArticle] = []

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
        .combineLatest($searchText)
        .map { args, search -> [NewsArticle] in
            let (articles, watchlist, portfolio, filter) = args
            var news = articles

            switch filter {
            case .all:
                break
            case .watchlist:
                let symbols = Set(watchlist.map { $0.symbol })
                news = news.filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
            case .portfolio:
                let symbols = Set(portfolio.map { $0.asset.symbol })
                news = news.filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
            }

            if !search.isEmpty {
                let q = search.lowercased()
                news = news.filter {
                    $0.title.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q)
                    || $0.source.lowercased().contains(q)
                }
            }

            return news.sorted { $0.publishedAt > $1.publishedAt }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$filteredNews)
    }
}
