import SwiftUI
import TradingCore

struct PortfolioHoldingEvents: View {
    struct Listing: Identifiable, Equatable {
        let id: String
        let symbol: String
        let holdingID: UUID
        let earningsEligible: Bool
    }

    struct ListingEvents: Identifiable {
        let listing: Listing
        let earnings: EarningsEvent?
        let earningsCurrent: Bool
        let headlines: [NewsArticle]?
        var id: String { listing.id }
    }

    let owner: UUID?
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @State private var results: [ListingEvents] = []
    @State private var isLoading = false
    @State private var request = 0

    private struct LoadKey: Equatable {
        let listings: [Listing]
        let request: Int
    }

    private static let listingLimit = 6
    private var listings: [Listing] { Self.listings(for: marketData.portfolio) }
    private var queue: [Listing] { Array(listings.prefix(Self.listingLimit)) }

    static func listings(for holdings: [PortfolioHolding]) -> [Listing] {
        var byID: [String: Listing] = [:]
        for holding in holdings where holding.shares.isFinite && holding.shares > 0 {
            let asset = holding.asset
            guard let listing = asset.listedStock, listing.venue == .us, byID[asset.quoteIdentity] == nil else { continue }
            byID[asset.quoteIdentity] = Listing(id: asset.quoteIdentity, symbol: listing.symbol, holdingID: holding.id,
                                                earningsEligible: EarningsCalendar.covers(asset))
        }
        return byID.values.sorted { $0.symbol < $1.symbol }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if owner == nil {
                        Text("Sign in to check company news and earnings for your US holdings.")
                    } else if listings.isEmpty {
                        Text("This feed covers US listings. Add an eligible holding to see company events.")
                    } else {
                        Text("Upcoming reports are estimates. News links open the publisher’s story.")
                            .font(.footnote)
                        Text("Checks up to \(Self.listingLimit) US listings, in ticker order.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if isLoading { ProgressView("Checking holding events…") }
                    }
                }
                if owner != nil, !queue.isEmpty, !isLoading {
                    earningsSection
                    newsSection
                }
            }
            .navigationTitle("Earnings and news")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { HoldingDetailView(holdingID: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if owner != nil, !queue.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { request += 1 }
                            .disabled(isLoading)
                    }
                }
            }
            .task(id: LoadKey(listings: queue, request: request)) { await load(queue) }
            .onChange(of: auth.userId) { _, value in
                if value != owner { dismiss() }
            }
        }
    }

    private var earningsSection: some View {
        let eligible = listings.filter(\.earningsEligible).count
        let checked = results.filter { $0.listing.earningsEligible && $0.earningsCurrent }.count
        let rows = results.filter { $0.earnings != nil }.sorted {
            ($0.earnings?.day ?? "", $0.listing.symbol) < ($1.earnings?.day ?? "", $1.listing.symbol)
        }
        return Section("Expected earnings") {
            Text("\(checked) of \(eligible) eligible listings checked · Finnhub")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("portfolio.events.earnings.coverage")
            if eligible == 0 {
                Text("Earnings dates are available for eligible US companies.")
            } else if rows.isEmpty {
                Text(checked == 0 ? "Earnings feed unavailable" : "No upcoming reports in the listings checked")
            }
            ForEach(rows) { row in
                if let event = row.earnings {
                    NavigationLink(value: row.listing.holdingID) {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text("\(row.listing.symbol) · \(event.dateText)").font(.headline)
                            Text(row.earningsCurrent ? event.shortTimingText : "Earlier estimate · latest check unavailable")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("portfolio.events.earnings.\(row.listing.symbol)")
                }
            }
            if let source = URL(string: "https://finnhub.io/docs/api/earnings-calendar") {
                Link("About the earnings feed", destination: source)
            }
        }
    }

    private var newsSection: some View {
        let checked = results.filter { $0.headlines != nil }.count
        let sorted = results.flatMap { $0.headlines ?? [] }.sorted { $0.publishedAt > $1.publishedAt }
        var urls = Set<String>()
        let rows = sorted.filter { urls.insert($0.url).inserted }.prefix(12)
        return Section("Recent headlines") {
            Text("\(checked) of \(listings.count) eligible listings checked · Finnhub")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("portfolio.events.news.coverage")
            if rows.isEmpty {
                Text(checked == 0 ? "News feed unavailable" : "No recent stories in the listings checked")
            }
            ForEach(rows) { article in
                if let url = URL(string: article.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text(article.title).font(.subheadline.weight(.semibold))
                            Text("\(article.relatedSymbols.joined(separator: ", ")) · \(article.source) · \(article.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func load(_ queue: [Listing]) async {
        guard let owner, owner == auth.userId else { return }
        results = []
        isLoading = !queue.isEmpty
        defer { if !Task.isCancelled { isLoading = false } }
        var loaded: [ListingEvents] = []
        let calendar = EarningsCalendar.shared
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        for listing in queue {
            if Task.isCancelled || auth.userId != owner { return }
            async let news = try? APIService.shared.fetchCompanyNews(symbol: listing.symbol, limit: 4, requiresCoverage: true)
            let earnings = listing.earningsEligible ? await calendar.next(for: listing.symbol) : nil
            let headlines = await news
            loaded.append(ListingEvents(listing: listing, earnings: earnings,
                                        earningsCurrent: calendar.hasRecentLookup(for: listing.symbol),
                                        headlines: headlines?.filter { article in
                guard article.publishedAt >= cutoff, article.publishedAt <= now.addingTimeInterval(60),
                      !article.title.isEmpty, let url = URLComponents(string: article.url) else { return false }
                return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            }))
        }
        if !Task.isCancelled, auth.userId == owner { results = loaded }
    }
}
