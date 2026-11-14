import Foundation
import TradingCore

struct PortfolioIssuerExposure {
    enum Dimension {
        case sector, incorporation
    }

    struct Filing: Decodable {
        struct Evidence: Decodable {
            let filedOn: String
            let url: URL
        }

        let issuer: String
        let sic: String
        let sector: String
        let country: String
        let evidence: Evidence
    }

    struct Source: Identifiable {
        let id: String
        let listing: String
        let filing: Filing
    }

    private static let filings: [String: Filing] = {
        guard let url = Bundle.main.url(forResource: "IssuerFilings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: Filing].self, from: data) else { return [:] }
        return catalog
    }()

    private static let etfs = Set(UniverseCatalog.all.filter { $0.assetClass == .etf }.map(\.id))
        .union(OnboardingCatalog.etfs.map { "\($0.exchange.lowercased()):\($0.symbol)" })

    var labels: [UUID: String] = [:]
    var classifiedValue: Double = 0
    var sources: [Source] = []

    init(holdings: [PortfolioHolding], dimension: Dimension) {
        var seen = Set<String>()
        for holding in holdings {
            let asset = holding.asset
            if asset.kind == .crypto {
                labels[holding.id] = "Crypto"
            } else if Self.etfs.contains(asset.quoteIdentity) {
                labels[holding.id] = "ETFs"
            } else if let filing = Self.filings[asset.quoteIdentity], let listing = asset.listedStock {
                labels[holding.id] = dimension == .sector ? filing.sector : filing.country
                classifiedValue += holding.currentValue
                if seen.insert(asset.quoteIdentity).inserted {
                    sources.append(Source(id: asset.quoteIdentity, listing: "\(listing.symbol) · \(listing.venue.shortName)", filing: filing))
                }
            } else {
                labels[holding.id] = "Unclassified shares"
            }
        }
        sources.sort { $0.listing < $1.listing }
    }
}
