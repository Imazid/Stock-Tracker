//
//  NewsView.swift
//  Stock Tracker
//

import SwiftUI

struct NewsView: View {
    @EnvironmentObject var marketData: MarketData
    @State private var selectedFilter: NewsFilter = .all
    @State private var searchText = ""
    @State private var isRefreshing = false
    
    enum NewsFilter: String, CaseIterable {
        case all = "All News"
        case watchlist = "Watchlist"
        case portfolio = "Portfolio"
    }
    
    private var filteredNews: [NewsArticle] {
        var news = marketData.newsArticles
        
        switch selectedFilter {
        case .all: break
        case .watchlist:
            let symbols = Set(marketData.watchlist.map { $0.symbol })
            news = news.filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
        case .portfolio:
            let symbols = Set(marketData.portfolio.map { $0.asset.symbol })
            news = news.filter { !Set($0.relatedSymbols).isDisjoint(with: symbols) }
        }
        
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            news = news.filter {
                $0.title.lowercased().contains(q) ||
                $0.summary.lowercased().contains(q) ||
                $0.source.lowercased().contains(q)
            }
        }
        
        return news.sorted { $0.publishedAt > $1.publishedAt }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // MARK: - Welcome Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Good \(greeting()),")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("Latest Market News")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            
                            Text("Stay ahead with real-time updates")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 10)
                        
                        // MARK: - Search Bar (now below header!)
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            
                            TextField("Search news, stocks, sources...", text: $searchText)
                                .foregroundColor(.white)
                                .tint(.white)
                            
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        
                        // MARK: - Filter Tabs
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(NewsFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        
                        // MARK: - News List
                        if filteredNews.isEmpty && !isRefreshing {
                            emptyState
                        } else {
                            LazyVStack(spacing: 16) {
                                ForEach(filteredNews) { article in
                                    NewsCard(article: article)
                                        .padding(.horizontal)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .refreshable { await refreshNews() }
            }
            
            // MARK: - Navigation Bar (clean, no search here anymore)
            .navigationTitle("News")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await refreshNews() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.white)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "newspaper")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            Text("No news found")
                .font(.title2.bold())
                .foregroundColor(.white.opacity(0.8))
            Text("Try adjusting your search or filter")
                .foregroundColor(.gray)
        }
        .padding(.top, 80)
    }
    
    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Morning"
        case 12..<17: return "Afternoon"
        default:      return "Evening"
        }
    }
    
    private func refreshNews() async {
        isRefreshing = true
        try? await Task.sleep(for: .seconds(1))
        isRefreshing = false
    }
}

// MARK: - Premium News Card (unchanged)
struct NewsCard: View {
    let article: NewsArticle
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = article.imageURL, !url.isEmpty,
               let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderImage
                    }
                }
                .frame(height: 200)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom))
            } else {
                placeholderImage.frame(height: 200)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(article.source)
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                    Spacer()
                    Text(timeAgo(from: article.publishedAt))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Text(article.title)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                    .lineLimit(3)
                
                Text(article.summary)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
                
                if !article.relatedSymbols.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(article.relatedSymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.5), lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.white.opacity(0.08))
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
    }
    
    private var placeholderImage: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.gray.opacity(0.6))
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    NewsView()
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}
