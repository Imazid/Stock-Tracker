import SwiftUI

struct NewsView: View {
    @EnvironmentObject var marketData: MarketData
    @State private var selectedFilter: NewsFilter = .all
    @State private var searchText: String = ""
    
    enum NewsFilter: String, CaseIterable {
        case all = "All"
        case watchlist = "Watchlist"
        case portfolio = "Portfolio"
    }
    
    private var filteredNews: [NewsArticle] {
        var news: [NewsArticle]
        
        switch selectedFilter {
        case .all:
            news = marketData.newsArticles
        case .watchlist:
            let watchlistSymbols = Set(marketData.watchlist.map { $0.symbol })
            news = marketData.newsArticles.filter { article in
                !Set(article.relatedSymbols).isDisjoint(with: watchlistSymbols)
            }
        case .portfolio:
            let portfolioSymbols = Set(marketData.portfolio.map { $0.asset.symbol })
            news = marketData.newsArticles.filter { article in
                !Set(article.relatedSymbols).isDisjoint(with: portfolioSymbols)
            }
        }
        
        // Apply search filter
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let lower = q.lowercased()
            news = news.filter {
                $0.title.lowercased().contains(lower) ||
                $0.summary.lowercased().contains(lower) ||
                $0.source.lowercased().contains(lower) ||
                $0.relatedSymbols.contains { $0.lowercased().contains(lower) }
            }
        }
        
        return news
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            filterSection
            
            if filteredNews.isEmpty {
                emptyState
            } else {
                newsList
            }
        }
    }
    
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(NewsFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                
                Spacer()
                
                Button {
                    // Refresh news
                    Task {
                        await marketData.refreshFromAPI()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.ultraThinMaterial)
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.15),
                                                Color.white.opacity(0.05)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            }
                        )
                }
                .buttonStyle(.plain)
            }
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search news…", text: $searchText)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                }
            )
        }
    }
    
    private var newsList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(filteredNews) { article in
                    NewsArticleCard(article: article)
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text("No news articles")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No articles match your search"
        }
        
        switch selectedFilter {
        case .all:
            return "No news available at the moment"
        case .watchlist:
            return "Add stocks to your watchlist to see related news"
        case .portfolio:
            return "Add holdings to your portfolio to see related news"
        }
    }
}

struct NewsArticleCard: View {
    let article: NewsArticle
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(3)
                    
                    Text(article.summary)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                    
                    HStack {
                        Text(article.source)
                            .font(.caption2.bold())
                            .foregroundColor(.blue)
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text(timeAgo(from: article.publishedAt))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
                
                if article.imageURL != nil {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                        )
                }
            }
            
            if !article.relatedSymbols.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(article.relatedSymbols, id: \.self) { symbol in
                            Text(symbol)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.2))
                                )
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }
    
    private func timeAgo(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.minute, .hour, .day], from: date, to: now)
        
        if let day = components.day, day > 0 {
            return "\(day)d ago"
        } else if let hour = components.hour, hour > 0 {
            return "\(hour)h ago"
        } else if let minute = components.minute, minute > 0 {
            return "\(minute)m ago"
        } else {
            return "Just now"
        }
    }
}
