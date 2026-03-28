//
//  NewsView.swift
//  Stock Tracker
//

import SwiftUI

// MARK: - News Filter (moved out of NewsView so NewsViewModel can reference it)
enum NewsFilter: String, CaseIterable {
    case all = "All News"
    case watchlist = "Watchlist"
    case portfolio = "Portfolio"

    var icon: String {
        switch self {
        case .all:       return "flame.fill"
        case .watchlist: return "star.fill"
        case .portfolio: return "briefcase.fill"
        }
    }
}

struct NewsView: View {
    @EnvironmentObject var marketData: MarketData
    @StateObject private var viewModel = NewsViewModel()
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isRefreshing = false
    @EnvironmentObject var insightService: AIInsightService
    @State private var newsDigest: String?
    @State private var digestLoading = false

    private var compactArticles: [(offset: Int, element: NewsArticle)] {
        Array(viewModel.filteredNews.dropFirst().enumerated())
    }
    private var showAds: Bool { !SubscriptionManager.shared.currentTier.isAdFree }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Market News")
                            .font(.largeTitle.bold())
                            .foregroundColor(theme.primaryText)

                        Text("Stay ahead with real-time updates")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Button { Task { await refreshNews() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                            .font(.title3.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(theme.glassBackground)
                            .clipShape(Circle())
                            .rotationEffect(.degrees(isRefreshing && !reduceMotion ? 360 : 0))
                            .animation(isRefreshing && !reduceMotion ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // MARK: - Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(theme.secondaryText)

                    TextField("Search news, stocks, sources...", text: $viewModel.searchText)
                        .foregroundColor(theme.primaryText)
                        .tint(.blue)

                    if !viewModel.searchText.isEmpty {
                        Button { viewModel.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
                .padding(14)
                .background(theme.glassBackground)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
                .padding(.horizontal)

                // MARK: - Filter Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(NewsFilter.allCases, id: \.self) { filter in
                            Button {
                                motionSafeWithAnimation(.spring(response: 0.3)) {
                                    viewModel.selectedFilter = filter
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: filter.icon)
                                        .font(.caption)
                                    Text(filter.rawValue)
                                        .font(.subheadline.weight(.medium))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(viewModel.selectedFilter == filter ? Color.blue : theme.glassBackground)
                                .foregroundColor(viewModel.selectedFilter == filter ? .white : theme.primaryText)
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(viewModel.selectedFilter == filter ? Color.clear : theme.cardBorder, lineWidth: 1)
                                )
                            }
                            .accessibilityAddTraits(viewModel.selectedFilter == filter ? .isSelected : [])
                            .accessibilityLabel("\(filter.rawValue) filter")
                        }
                    }
                    .padding(.horizontal)
                }

                // AI News Digest (Pro/Black only)
                if SubscriptionManager.shared.currentTier != .free {
                    newsDigestCard
                        .padding(.horizontal)
                }

                // MARK: - Content
                if marketData.newsArticles.isEmpty && !isRefreshing {
                    // Initial skeleton load — articles haven't arrived yet
                    VStack(spacing: 16) {
                        NewsHeroSkeleton()
                            .padding(.horizontal)
                        HStack {
                            SkeletonBlock(width: 80, height: 22, cornerRadius: 7)
                            Spacer()
                            SkeletonBlock(width: 60, height: 13, cornerRadius: 6)
                        }
                        .padding(.horizontal)
                        StaggeredSkeletonList(count: 4) {
                            NewsCompactSkeleton().padding(.horizontal)
                        }
                    }
                } else if viewModel.filteredNews.isEmpty && !isRefreshing {
                    newsEmptyState
                } else {
                    VStack(spacing: 16) {
                        // Featured hero card for first article
                        if let featured = viewModel.filteredNews.first {
                            NewsHeroCard(article: featured)
                                .padding(.horizontal)
                        }

                        // Section header
                        if viewModel.filteredNews.count > 1 {
                            HStack {
                                Text("Latest")
                                    .font(.title3.bold())
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text("\(viewModel.filteredNews.count - 1) articles")
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                            }
                            .padding(.horizontal)
                        }

                        // Compact cards for remaining articles, with ad slots every 5 items
                        LazyVStack(spacing: 12) {
                            ForEach(compactArticles, id: \.offset) { item in
                                NewsCompactCard(article: item.element)
                                    .padding(.horizontal)
                                    .onAppear {
                                        if item.element.id == viewModel.filteredNews.last?.id {
                                            Task { await marketData.fetchNextNewsPage() }
                                        }
                                    }

                                // Ad slot: after 1st compact article, then every 6th
                                if showAds && (item.offset == 0 || (item.offset + 1) % 6 == 0) {
                                    NewsAdBannerCard()
                                        .padding(.horizontal)
                                }
                            }
                        }

                        // Load More / end indicator
                        if marketData.isFetchingNews {
                            ProgressView()
                                .padding()
                        } else if !marketData.newsHasMore && marketData.newsArticles.count > Constants.Pagination.newsPageSize {
                            Text("You've caught up!")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                                .padding()
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(theme.background.ignoresSafeArea())
        .refreshable { await refreshNews() }
        .onAppear { viewModel.observe(marketData) }
    }

    private var newsEmptyState: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(theme.glassBackground)
                    .frame(width: 100, height: 100)

                Image(systemName: "newspaper")
                    .font(.system(size: 40))
                    .foregroundColor(theme.secondaryText)
            }

            Text("No news found")
                .font(.title2.bold())
                .foregroundColor(theme.primaryText)

            Text(viewModel.selectedFilter == .all
                 ? "Try adjusting your search"
                 : "No news matching your \(viewModel.selectedFilter.rawValue.lowercased()) filter")
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)

            if viewModel.selectedFilter != .all {
                Button {
                    motionSafeWithAnimation { viewModel.selectedFilter = .all }
                } label: {

                    Text("Show All News")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(20)
                }
            }
        }
        .padding(.top, 80)
    }

    private func refreshNews() async {
        isRefreshing = true
        await marketData.refreshNewsFromAPI()
        isRefreshing = false
    }

    // MARK: - AI News Digest

    private var newsDigestCard: some View {
        let tier = SubscriptionManager.shared.currentTier
        let isLocked = tier == .free
        let cacheKey = "news_digest_\(insightService.todayString)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? newsDigest
        return AIInsightCard(
            title: "News Digest",
            icon: "newspaper",
            insightText: cachedText,
            isLoading: digestLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadNewsDigest() },
            onRegenerate: { await loadNewsDigest(force: true) }
        )
    }

    private func loadNewsDigest(force: Bool = false) async {
        digestLoading = true
        defer { digestLoading = false }

        let tier = SubscriptionManager.shared.currentTier
        let cacheKey = "news_digest_\(insightService.todayString)"

        let headlines = marketData.newsArticles.prefix(10).map { article in
            "'\(article.title)' (\(article.source))"
        }.joined(separator: "; ")

        let watchSymbols = marketData.watchlist.map(\.symbol).joined(separator: ", ")
        let portfolioSymbols = marketData.portfolio.map(\.asset.symbol).joined(separator: ", ")

        let systemPrompt = "Summarize the market news theme in 2 sentences. Highlight any symbols the user holds or watches. Be neutral."
        let userPrompt = """
        Recent headlines: \(headlines). \
        User watches: \(watchSymbols.isEmpty ? "none" : watchSymbols). \
        User holds: \(portfolioSymbols.isEmpty ? "none" : portfolioSymbols). \
        Summarize the key themes in 2 sentences.
        """

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .newsDigest,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.defaultCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .newsDigest,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.defaultCacheTTL
            )
        }
        if let text = result { newsDigest = text }
    }
}

// MARK: - Hero Card (Featured Article)
struct NewsHeroCard: View {
    let article: NewsArticle
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            // Image area
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    if let url = article.imageURL, !url.isEmpty,
                       let imageUrl = URL(string: url) {
                        AsyncImage(url: imageUrl) { phase in
                            if case .success(let image) = phase {
                                image.resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: 200)
                                    .clipped()
                            } else {
                                heroPlaceholder
                                    .frame(width: geo.size.width, height: 200)
                            }
                        }
                    } else {
                        heroPlaceholder
                            .frame(width: geo.size.width, height: 200)
                    }
                }
                .frame(height: 200)

                // Gradient overlay
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Source badge
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(article.source)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(8)

                        Text(timeAgo(from: article.publishedAt))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(16)
            }
            .frame(height: 200)
            .clipShape(RoundedCorner(radius: 20, corners: [.topLeft, .topRight]))

            // Content area
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.title3.bold())
                    .foregroundColor(theme.primaryText)
                    .lineLimit(3)

                Text(article.summary)
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)

                if !article.relatedSymbols.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(article.relatedSymbols, id: \.self) { symbol in
                                Text(symbol)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(theme.glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.04), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(article.title). Source: \(article.source). \(timeAgo(from: article.publishedAt))")
        .accessibilityHint("Double tap to read full article")
    }

    private var heroPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "newspaper.fill")
                .font(.system(size: 50))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func timeAgo(from date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Compact News Card
struct NewsCompactCard: View {
    let article: NewsArticle
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 14) {
            // Thumbnail
            if let url = article.imageURL, !url.isEmpty,
               let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        compactPlaceholder
                    }
                }
                .frame(width: 90, height: 90)
                .clipped()
                .cornerRadius(14)
            } else {
                compactPlaceholder
                    .frame(width: 90, height: 90)
                    .cornerRadius(14)
            }

            // Text content
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.subheadline.bold())
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(article.source)
                        .font(.caption.bold())
                        .foregroundColor(.blue)

                    Text("·")
                        .foregroundColor(theme.secondaryText)

                    Text(timeAgo(from: article.publishedAt))
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                if !article.relatedSymbols.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(article.relatedSymbols.prefix(3), id: \.self) { symbol in
                            Text(symbol)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(article.title). Source: \(article.source). \(timeAgo(from: article.publishedAt))")
        .accessibilityHint("Double tap to read full article")
    }

    private var compactPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "photo")
                .font(.title3)
                .foregroundColor(.gray.opacity(0.5))
        }
    }

    private func timeAgo(from date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Corner Radius Extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    NewsView()
        .environmentObject(MarketData())
        .environmentObject(ThemeManager())
}
