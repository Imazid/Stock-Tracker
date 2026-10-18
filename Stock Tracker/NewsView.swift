//
//  NewsView.swift
//  Stock Tracker
//
//  News, after Yahoo Finance / Public / Stake on Mobbin: "source · time",
//  headline, thumbnail, and the tickers it mentions with today's move.
//  Every article opens in Safari View; filters explain themselves when empty;
//  there's a real error state (never placeholder articles).
//

import SwiftUI
import SafariServices

// MARK: - Filter

enum NewsFilter: String, CaseIterable {
    case all = "Top stories"
    case watchlist = "Watchlist"
    case portfolio = "Holdings"

    var title: LocalizedStringKey {
        switch self {
        case .all:       return "Top stories"
        case .watchlist: return "Watchlist"
        case .portfolio: return "Holdings"
        }
    }

    var icon: String {
        switch self {
        case .all:       return "newspaper"
        case .watchlist: return "star"
        case .portfolio: return "briefcase"
        }
    }
}

// MARK: - News tab

struct NewsView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var insightService: AIInsightService
    @StateObject private var viewModel = NewsViewModel()
    @Environment(\.theme) private var theme
    @Environment(\.selectTab) private var selectTab

    @State private var reading: NewsLink?
    @State private var hasAttemptedLoad = false
    @State private var newsDigest: String?
    @State private var digestLoading = false

    private var showAds: Bool { !SubscriptionManager.shared.currentTier.isAdFree && NewsAds.isEnabled }
    private var articles: [NewsArticle] { viewModel.filteredNews }
    private var showHero: Bool { viewModel.selectedFilter == .all && viewModel.searchText.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    filterChips
                        .padding(.bottom, DS.Space.l)

                    if SubscriptionManager.shared.currentTier != .free && !marketData.newsArticles.isEmpty {
                        newsDigestCard
                            .padding(.horizontal, DS.Space.gutter)
                            .padding(.bottom, DS.Space.l)
                    }

                    content
                }
                .padding(.bottom, DS.Space.xxl)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("News")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $viewModel.searchText, prompt: "Search headlines or tickers")
            .refreshable { await refreshNews() }
            .task {
                viewModel.observe(marketData)
                if marketData.newsArticles.isEmpty { await refreshNews() }
                hasAttemptedLoad = true
            }
            .sheet(item: $reading) { link in
                ArticleSafariView(url: link.url) { reading = nil }
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                ForEach(NewsFilter.allCases, id: \.self) { filter in
                    let isOn = viewModel.selectedFilter == filter
                    Button {
                        Haptics.select()
                        dsAnimate(DS.quick) { viewModel.selectedFilter = filter }
                    } label: {
                        Label(filter.title, systemImage: filter.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? theme.invertedPrimaryText : theme.primaryText)
                            .padding(.horizontal, DS.Space.m)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(isOn ? theme.primaryText : theme.subtleFill))
                            .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(isOn ? 0 : 0.6), lineWidth: 0.5))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("news.filter.\(filter)")
                }
            }
            .padding(.horizontal, DS.Space.gutter)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if marketData.newsArticles.isEmpty {
            if marketData.isFetchingNews || !hasAttemptedLoad {
                loadingSkeleton
            } else {
                stateCard(icon: "wifi.exclamationmark",
                          title: "News isn't loading right now",
                          message: "Check your connection and try again.",
                          action: ("Try again", { Task { await refreshNews() } }),
                          id: "news.error")
            }
        } else if articles.isEmpty {
            emptyFilterState
        } else {
            articleList
        }
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                if index == 0 && showHero {
                    NewsHeroRow(article: article, onOpen: { open(article) })
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.bottom, DS.Space.l)
                    if articles.count > 1 {
                        SectionHeader(title: "Latest")
                            .padding(.horizontal, DS.Space.gutter)
                    }
                } else {
                    NewsArticleRow(article: article, onOpen: { open(article) })
                        .padding(.horizontal, DS.Space.gutter)
                        .onAppear {
                            if article.id == articles.last?.id {
                                Task { await marketData.fetchNextNewsPage() }
                            }
                        }
                    if index < articles.count - 1 {
                        Divider()
                            .overlay(theme.cardBorder.opacity(0.4))
                            .padding(.leading, DS.Space.gutter)
                    }
                    if showAds && (index == 3 || (index > 3 && (index - 3) % 8 == 0)) {
                        NewsAdBannerCard()
                            .padding(.horizontal, DS.Space.gutter)
                            .padding(.vertical, DS.Space.s)
                    }
                }
            }

            if marketData.isFetchingNews {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(DS.Space.l)
            } else if !marketData.newsHasMore && viewModel.selectedFilter == .all && viewModel.searchText.isEmpty {
                Text("You're all caught up")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(DS.Space.l)
            }
        }
    }

    private var loadingSkeleton: some View {
        VStack(spacing: DS.Space.l) {
            NewsHeroSkeleton()
            StaggeredSkeletonList(count: 4) { NewsCompactSkeleton() }
        }
        .padding(.horizontal, DS.Space.gutter)
        .accessibilityLabel("Loading news")
        .accessibilityIdentifier("news.loading")
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            stateCard(icon: "magnifyingglass",
                      title: "No headlines match “\(query)”",
                      message: "Try a company name or a ticker like NVDA.",
                      id: "news.noMatches")
        } else {
            switch viewModel.selectedFilter {
            case .watchlist:
                if marketData.watchlist.isEmpty {
                    stateCard(icon: "star", title: "Your watchlist is empty",
                              message: "Follow a few companies to see news about them here.",
                              action: ("Find stocks", { selectTab(.search) }), id: "news.empty.watchlist")
                } else if !viewModel.hasNewsCoverage(for: marketData.watchlist) {
                    stateCard(icon: "globe.asia.australia", title: "No news for these yet",
                              message: "Company news covers US-listed stocks. ASX shares and crypto aren't included yet.",
                              id: "news.empty.coverage")
                } else if viewModel.isLoadingCompanyNews {
                    loadingSkeleton
                } else {
                    stateCard(icon: "newspaper", title: "No recent news for your watchlist",
                              message: "Check back later, or browse Top stories.",
                              action: ("Show top stories", { viewModel.selectedFilter = .all }), id: "news.empty.watchlist")
                }
            case .portfolio:
                if marketData.portfolio.isEmpty {
                    stateCard(icon: "briefcase", title: "No holdings yet",
                              message: "Add what you own to see news about it here.",
                              action: ("Go to Portfolio", { selectTab(.portfolio) }), id: "news.empty.holdings")
                } else if !viewModel.hasNewsCoverage(for: marketData.portfolio.map(\.asset)) {
                    stateCard(icon: "globe.asia.australia", title: "No news for these yet",
                              message: "Company news covers US-listed stocks. ASX shares and crypto aren't included yet.",
                              id: "news.empty.coverage")
                } else if viewModel.isLoadingCompanyNews {
                    loadingSkeleton
                } else {
                    stateCard(icon: "newspaper", title: "No recent news for your holdings",
                              message: "Check back later, or browse Top stories.",
                              action: ("Show top stories", { viewModel.selectedFilter = .all }), id: "news.empty.holdings")
                }
            case .all:
                stateCard(icon: "newspaper", title: "No stories right now",
                          message: "Pull down to refresh.", id: "news.empty")
            }
        }
    }

    private func stateCard(icon: String, title: String, message: String,
                           action: (String, () -> Void)? = nil, id: String) -> some View {
        EmptyStateCard(
            systemImage: icon,
            title: LocalizedStringKey(title),
            message: LocalizedStringKey(message),
            primaryTitle: action.map { LocalizedStringKey($0.0) },
            primaryAction: action?.1
        )
        .padding(.horizontal, DS.Space.gutter)
        .accessibilityIdentifier(id)
    }

    // MARK: Actions

    private func open(_ article: NewsArticle) {
        guard let url = URL(string: article.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Haptics.tap()
        reading = NewsLink(url: url)
    }

    private func refreshNews() async {
        await marketData.refreshNewsFromAPI()
    }

    // MARK: AI digest (Pro / Black)

    private var newsDigestCard: some View {
        let tier = SubscriptionManager.shared.currentTier
        let cacheKey = "news_digest_\(insightService.todayString)"
        return AIInsightCard(
            title: "News Digest",
            icon: "newspaper",
            insightText: insightService.cached(cacheKey)?.text ?? newsDigest,
            isLoading: digestLoading,
            isLocked: tier == .free,
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
        let headlines = marketData.newsArticles.prefix(10).map { "'\($0.title)' (\($0.source))" }.joined(separator: "; ")
        let watchSymbols = marketData.watchlist.map(\.symbol).joined(separator: ", ")
        let portfolioSymbols = marketData.portfolio.map(\.asset.symbol).joined(separator: ", ")
        let systemPrompt = "Summarize the market news theme in 2 sentences. Highlight any symbols the user holds or watches. Be neutral."
        let userPrompt = """
        Recent headlines: \(headlines). \
        User watches: \(watchSymbols.isEmpty ? "none" : watchSymbols). \
        User holds: \(portfolioSymbols.isEmpty ? "none" : portfolioSymbols). \
        Summarize the key themes in 2 sentences.
        """
        let result = force
            ? await insightService.regenerateInsight(key: cacheKey, type: .newsDigest, systemPrompt: systemPrompt,
                                                     userPrompt: userPrompt, tier: tier, ttl: Constants.AI.defaultCacheTTL)
            : await insightService.generateInsight(key: cacheKey, type: .newsDigest, systemPrompt: systemPrompt,
                                                   userPrompt: userPrompt, tier: tier, ttl: Constants.AI.defaultCacheTTL)
        if let result { newsDigest = result }
    }
}

// MARK: - Rows

struct NewsLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

enum NewsTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "Just now" : formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Compact article row: source · time, headline, thumbnail, tickers.
struct NewsArticleRow: View {
    let article: NewsArticle
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(article.source) · \(NewsTime.ago(article.publishedAt))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    Text(article.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    if !article.relatedSymbols.isEmpty {
                        NewsTickerChips(symbols: Array(article.relatedSymbols.prefix(3)))
                    }
                }
                Spacer(minLength: 0)
                NewsThumbnail(urlString: article.pictureURL, source: article.source,
                              symbol: article.relatedSymbols.first, size: 72)
            }
            .padding(.vertical, DS.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .contextMenu { NewsArticleMenu(article: article) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(article.title). \(article.source), \(NewsTime.ago(article.publishedAt))")
        .accessibilityHint("Opens the article")
        .accessibilityIdentifier("news.article")
    }
}

/// The lead story: large image, serif headline, summary.
struct NewsHeroRow: View {
    let article: NewsArticle
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let url = article.pictureURL.flatMap({ URL(string: $0) }) {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            ZStack {
                                theme.secondaryBackground
                                AsyncImage(url: url, transaction: SwiftUI.Transaction(animation: DS.quick)) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    }
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text("\(article.source) · \(NewsTime.ago(article.publishedAt))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, DS.Space.xs)
                Text(article.title)
                    .font(DS.display(.title3, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                if !article.summary.isEmpty {
                    Text(article.summary)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                if !article.relatedSymbols.isEmpty {
                    NewsTickerChips(symbols: Array(article.relatedSymbols.prefix(4)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .contextMenu { NewsArticleMenu(article: article) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Top story. \(article.title). \(article.source), \(NewsTime.ago(article.publishedAt))")
        .accessibilityHint("Opens the article")
        .accessibilityIdentifier("news.article")
    }
}

/// Kept for screens that list related news (opens the article itself).
struct NewsCompactCard: View {
    let article: NewsArticle
    @State private var reading: NewsLink?

    var body: some View {
        NewsArticleRow(article: article) {
            if let url = URL(string: article.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                reading = NewsLink(url: url)
            }
        }
        .sheet(item: $reading) { link in
            ArticleSafariView(url: link.url) { reading = nil }
                .ignoresSafeArea()
        }
    }
}

private struct NewsArticleMenu: View {
    let article: NewsArticle

    var body: some View {
        if let url = URL(string: article.url) {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
        }
    }
}

/// Ticker chips with today's move when we have a quote ("NVDA ▲ 1.2%").
private struct NewsTickerChips: View {
    let symbols: [String]
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    private func quote(_ symbol: String) -> Asset? {
        (marketData.watchlist + marketData.portfolio.map(\.asset) + marketData.stocks)
            .first { $0.symbol == symbol && $0.price > 0 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                if let q = quote(symbol) {
                    let up = q.changePercent >= 0
                    let tint = abs(q.changePercent) < 0.005 ? theme.secondaryText : (up ? theme.positiveColor : theme.negativeColor)
                    HStack(spacing: 3) {
                        Text(symbol).foregroundStyle(theme.primaryText)
                        Text(String(format: "%@%.2f%%", up ? "▲" : "▼", abs(q.changePercent)))
                            .foregroundStyle(tint)
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.subtleFill))
                } else {
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.subtleFill))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Every row gets the same quiet square: the article's picture when it has one;
/// otherwise the company the story is about (its logo), or a muted publisher monogram.
/// Brand-coloured publisher tiles turned a mostly-Yahoo feed into a wall of identical
/// purple "Y!" squares, so the fallback stays neutral and the source is in the byline.
/// After Perplexity Finance / Public on Mobbin.
private struct NewsThumbnail: View {
    let urlString: String?
    let source: String
    var symbol: String? = nil
    let size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.secondaryBackground
            if let url = urlString.flatMap({ URL(string: $0) }) {
                AsyncImage(url: url, transaction: SwiftUI.Transaction(animation: DS.quick)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: fallback
                    default: Color.clear
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        if let symbol, !symbol.isEmpty {
            TickerLogo(symbol: symbol, size: size * 0.5)
        } else {
            let style = PublisherStyle.for(source)
            Text(style.monogram)
                .font(.system(size: size * (style.monogram.count <= 2 ? 0.32 : 0.22), weight: .bold,
                              design: style.serif ? .serif : .rounded))
                .foregroundStyle(theme.secondaryText)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(6)
        }
    }
}

extension NewsArticle {
    /// The article's own picture — nil when the feed only gave a publisher logo. Finnhub
    /// attaches the same wordmark to every story from some sources: Yahoo ("Y!f" when
    /// cropped square), Reuters (finnhub's own reuters_logo, read as "REUT") and Bloomberg
    /// (a white logo, invisible in light mode).
    var pictureURL: String? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        let placeholders = ["/rz/stage/p/yahoo_finance", "yahoo_finance_en-US_h_p_finance",
                            "finnhub.io/file/finnhub/logo/", "/logobbg-"]
        return placeholders.contains(where: imageURL.contains) ? nil : imageURL
    }
}

/// A news source's monogram ("R" for Reuters, "BZ" for Benzinga), drawn locally.
enum PublisherStyle {
    struct Style {
        let monogram: String
        let background: Color
        var foreground: Color = .white
        var serif = false
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Known sources by name, as Finnhub spells them.
    private static let known: [(match: String, style: Style)] = [
        ("reuters", Style(monogram: "R", background: rgb(0xF26722))),
        ("cnbc", Style(monogram: "CNBC", background: rgb(0x005594))),
        ("bloomberg", Style(monogram: "B", background: rgb(0x111111))),
        ("yahoo", Style(monogram: "Y!", background: rgb(0x6001D2))),
        ("benzinga", Style(monogram: "BZ", background: rgb(0x1F6FEB))),
        ("seekingalpha", Style(monogram: "SA", background: rgb(0xEC6D2A))),
        ("seeking alpha", Style(monogram: "SA", background: rgb(0xEC6D2A))),
        ("marketwatch", Style(monogram: "MW", background: rgb(0x2E8540))),
        ("wall street journal", Style(monogram: "WSJ", background: rgb(0x111111), serif: true)),
        ("wsj", Style(monogram: "WSJ", background: rgb(0x111111), serif: true)),
        ("financial times", Style(monogram: "FT", background: rgb(0xFCD0B1), foreground: rgb(0x262A33), serif: true)),
        ("barron", Style(monogram: "B", background: rgb(0x111111), serif: true)),
        ("forbes", Style(monogram: "F", background: rgb(0x111111), serif: true)),
        ("motley fool", Style(monogram: "MF", background: rgb(0x5B2C83))),
        ("fool", Style(monogram: "MF", background: rgb(0x5B2C83))),
        ("business insider", Style(monogram: "BI", background: rgb(0x1C2B4A))),
        ("cnn", Style(monogram: "CNN", background: rgb(0xCC0000))),
        ("chartmill", Style(monogram: "CM", background: rgb(0x3B4B5C))),
        ("zacks", Style(monogram: "Z", background: rgb(0x0B4D8C))),
        ("tipranks", Style(monogram: "TR", background: rgb(0x1E3A5F))),
        ("investopedia", Style(monogram: "I", background: rgb(0x0F3F4C), serif: true)),
        ("afr", Style(monogram: "AFR", background: rgb(0x0A1F44), serif: true)),
        ("financial review", Style(monogram: "AFR", background: rgb(0x0A1F44), serif: true)),
        ("abc", Style(monogram: "ABC", background: rgb(0x111111))),
    ]

    /// Muted colours for sources we don't know, picked by name so a source keeps its colour.
    private static let fallbacks: [Color] = [
        rgb(0x3D5A80), rgb(0x5C4D7D), rgb(0x2F6B5E), rgb(0x7A4E3B), rgb(0x445566), rgb(0x6B4A5E)
    ]

    static func `for`(_ source: String) -> Style {
        let name = source.lowercased().trimmingCharacters(in: .whitespaces)
        if let hit = known.first(where: { name.contains($0.match) }) { return hit.style }
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let monogram: String
        if words.count >= 2 {
            monogram = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        } else {
            monogram = String(source.prefix(2)).uppercased()
        }
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % fallbacks.count
        return Style(monogram: monogram.isEmpty ? "•" : monogram, background: fallbacks[index])
    }
}

// MARK: - Safari

struct ArticleSafariView: UIViewControllerRepresentable {
    let url: URL
    var onDone: () -> Void = {}

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}

// MARK: - Corner radius helper (used elsewhere)

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
