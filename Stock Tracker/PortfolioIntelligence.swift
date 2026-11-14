import SwiftUI
import TradingCore

struct PortfolioMovementReport {
    struct Contribution: Identifiable {
        let id: String
        let asset: Asset
        let holdings: [PortfolioHolding]
        let quote: AssetPriceMove
        let units: Double
        let amount: Double
        let percent: Double

        var sourceURL: URL? {
            switch quote.source {
            case .alpacaEquity:
                URL(string: "https://docs.alpaca.markets/us/reference/stocksnapshotsingle")
            case .alpacaCrypto:
                URL(string: "https://docs.alpaca.markets/us/reference/cryptosnapshots-1")
            case .coinGecko:
                QuoteService.coinGeckoID(for: asset.symbol).flatMap { URL(string: "https://www.coingecko.com/en/coins/\($0)") }
            case .yahooEquity:
                asset.listedStock.flatMap { listing in
                    var url = URLComponents()
                    url.scheme = "https"
                    url.host = "finance.yahoo.com"
                    url.path = "/quote/\(listing.symbol)\(listing.venue.yahooSuffix ?? "")/"
                    return url.url
                }
            }
        }
    }

    let contributions: [Contribution]
    let unavailable: [String]
    let positionCount: Int

    var coveredCount: Int { contributions.reduce(0) { $0 + $1.holdings.count } }
    var coverage: String { "Price evidence for \(coveredCount) of \(positionCount) positions" }

    init(holdings: [PortfolioHolding], failedListings: Set<String>, at now: Date) {
        positionCount = holdings.count
        let grouped = Dictionary(grouping: holdings, by: \.asset.quoteIdentity)
        var included: [Contribution] = []
        var missing: [String] = []
        var sessions: [Venue: DateInterval] = [:]
        let market = MarketCalendar.standard

        for (id, positions) in grouped {
            guard let first = positions.first else { continue }
            let asset = first.asset
            let venue = asset.kind == .crypto ? .crypto : asset.listedStock?.venue
            let ordered = positions.sorted { $0.id.uuidString < $1.id.uuidString }
            let validPositions = ordered.filter { $0.shares.isFinite && $0.shares > 0 }
            let units = validPositions.reduce(0) { $0 + $1.shares }
            let candidates = validPositions.compactMap(\.asset.priceMove).sorted { $0.observedAt > $1.observedAt }
            guard let venue, units.isFinite, units > 0, !failedListings.contains(id),
                  let quote = candidates.first(where: { $0.currency == venue.currency }) else {
                missing.append(asset.symbol)
                continue
            }

            if venue != .crypto, sessions[venue] == nil {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = market.timeZone(venue)
                sessions[venue] = (0..<10).lazy
                    .compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
                    .compactMap { market.session(venue, containing: $0) }
                    .first { $0.start <= now }
            }
            let age = now.timeIntervalSince(quote.observedAt)
            let recent: Bool
            if venue == .crypto {
                recent = age <= 15 * 60
            } else if let session = sessions[venue] {
                recent = quote.observedAt >= session.start &&
                    (!market.isOpen(venue, at: now) || age <= 35 * 60)
            } else {
                recent = false
            }

            let delta = quote.last - quote.reference
            let amount = units * delta
            let percent = delta / quote.reference * 100
            guard age >= -60, recent, amount.isFinite, percent.isFinite else {
                missing.append(asset.symbol)
                continue
            }
            included.append(Contribution(id: id, asset: asset, holdings: validPositions,
                                         quote: quote, units: units, amount: amount, percent: percent))
            if validPositions.count < positions.count { missing.append(asset.symbol) }
        }

        contributions = included.sorted {
            if $0.quote.currency != $1.quote.currency { return $0.quote.currency < $1.quote.currency }
            if abs($0.amount) != abs($1.amount) { return abs($0.amount) > abs($1.amount) }
            return $0.id < $1.id
        }
        unavailable = missing.sorted()
    }
}

extension MarketData {
    func portfolioMovement(at now: Date = Date()) -> PortfolioMovementReport {
        let failed = Set(portfolio.lazy.filter { self.quoteFailed(for: $0.asset) }.map(\.asset.quoteIdentity))
        return PortfolioMovementReport(holdings: portfolio, failedListings: failed, at: now)
    }
}

struct PortfolioIntelligenceEntry: View {
    @EnvironmentObject private var router: TradingRouter
    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    var visitSummary: String? = nil
    var onOpenVisitChanges: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Your Portfolio Intelligence")
            if let visitSummary, let onOpenVisitChanges {
                Button(action: onOpenVisitChanges) {
                    Label(visitSummary, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("portfolio.intelligence.visit")
            }

            if !marketData.portfolio.isEmpty {
                movementActions
            }
            let count = trading.pendingProposals.count
            if count > 0 {
                Button {
                    router.requestedTab = .agents
                    if let first = trading.pendingProposals.first, count == 1 {
                        router.proposal = TradingRouter.Ref(id: first.id)
                    }
                } label: {
                    Label(count == 1 ? "1 proposal awaiting approval" : "\(count) proposals awaiting approval",
                          systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("portfolio.intelligence.approvals")
            }
        }
        .dsCard()
    }

    @ViewBuilder
    private var movementActions: some View {
        Button {
            router.askCopilot(CopilotEngine.portfolioMovementPrompt)
        } label: {
            Label("Why did my portfolio move?", systemImage: "chart.line.uptrend.xyaxis")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.intelligenceTint)
        .accessibilityIdentifier("portfolio.intelligence.movement")

        Button {
            router.askCopilot(CopilotEngine.concentrationPrompt)
        } label: {
            Label("Review portfolio concentration", systemImage: "chart.pie")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("portfolio.intelligence.concentration")
    }
}

struct PortfolioMovementEvidence: View {
    let report: PortfolioMovementReport
    let onOpenHolding: (UUID) -> Void

    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @Environment(\.theme) private var theme

    private var contributions: [PortfolioMovementReport.Contribution] {
        guard valueHidden else { return report.contributions }
        // Value order would reveal which positions contributed the most.
        return report.contributions.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Portfolio price movement").font(.headline).accessibilityAddTraits(.isHeader)
            Text(report.coverage)
                .font(.subheadline)
                .accessibilityIdentifier("copilot.movement.coverage")
            if !report.contributions.isEmpty {
                Text("Current units × (latest price − reference price). Each contribution uses its own currency and quote period.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            if !report.unavailable.isEmpty {
                Text("Price evidence unavailable for \(report.unavailable.joined(separator: ", ")).")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("copilot.movement.unavailable")
            }
            ForEach(contributions) { item in
                Divider()
                evidence(item)
            }
        }
        .dsCard()
    }

    private func evidence(_ item: PortfolioMovementReport.Contribution) -> some View {
        let quote = item.quote
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack { title(item); Spacer(); change(item) }
                VStack(alignment: .leading, spacing: DS.Space.xs) { title(item); change(item) }
            }
            Text("\(quote.source.label) · \(quote.observedAt.formatted(.dateTime.year().month().day().hour().minute().timeZone()))")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("copilot.movement.source.\(item.id)")
            Text("Latest \(TradingFormat.price(quote.last, quote.currency)) · \(quote.source.reference) \(TradingFormat.price(quote.reference, quote.currency))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("copilot.movement.prices.\(item.id)")
            if !valueHidden {
                Text(item.asset.unitsText(item.units))
                    .font(.footnote.monospacedDigit())
                    .accessibilityIdentifier("copilot.movement.units.\(item.id)")
            }
            if let source = item.sourceURL {
                Link(destination: source) {
                    Label(quote.source == .alpacaEquity || quote.source == .alpacaCrypto
                          ? "About this market data feed" : "Open market source", systemImage: "arrow.up.right")
                }
                .font(.footnote)
                .accessibilityIdentifier("copilot.movement.link.\(item.id)")
            }
            ForEach(item.holdings) { holding in
                Button {
                    onOpenHolding(holding.id)
                } label: {
                    Label(item.holdings.count == 1 ? "Open \(item.asset.symbol) holding" :
                            "Open \(item.asset.symbol) · \(holding.brokerAccount?.label ?? "Manual holding")",
                          systemImage: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.intelligenceTint)
                .padding(.vertical, DS.Space.xs)
                .accessibilityIdentifier("copilot.movement.holding.\(holding.id.uuidString)")
            }
        }
    }

    private func title(_ item: PortfolioMovementReport.Contribution) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(item.asset.symbol).font(.subheadline.weight(.semibold))
            if abs(item.percent) >= 5 {
                Text("Price moved 5% or more").font(.caption).foregroundStyle(theme.warningColor)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func change(_ item: PortfolioMovementReport.Contribution) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            Text(TradingFormat.percent(item.percent))
            if !valueHidden {
                Text(TradingFormat.signedMoney(item.amount, item.quote.currency))
                    .accessibilityIdentifier("copilot.movement.amount.\(item.id)")
            }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(item.percent == 0 ? theme.secondaryText : (item.percent > 0 ? theme.positiveColor : theme.negativeColor))
        .fixedSize()
    }
}
