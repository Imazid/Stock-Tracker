import Foundation
import TradingCore

struct PortfolioConcentration {
    struct Listing: Identifiable {
        let id: String
        let asset: Asset
        let value: Double
    }

    let listings: [Listing]
    let valuedPositions: Int
    let openPositions: Int
    let value: Double

    var coverage: String { "\(valuedPositions) of \(openPositions) positions priced" }
    var topThreeShare: Double { share(of: listings.prefix(3).reduce(0) { $0 + $1.value }) }

    init(holdings: [PortfolioHolding], unpriced: (Asset) -> Bool) {
        let open = holdings.filter { $0.shares.isFinite && $0.shares > 0 }
        openPositions = open.count
        let valued = open.filter { $0.currentValue.isFinite && $0.currentValue > 0 && !unpriced($0.asset) }
        let total = valued.reduce(0) { $0 + $1.currentValue }
        guard total.isFinite, total > 0 else {
            value = 0
            valuedPositions = 0
            listings = []
            return
        }
        value = total
        valuedPositions = valued.count
        listings = Dictionary(grouping: valued, by: \.asset.quoteIdentity)
            .compactMap { id, positions in
                positions.first.map { Listing(id: id, asset: $0.asset, value: positions.reduce(0) { $0 + $1.currentValue }) }
            }
            .sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
    }

    func share(of amount: Double) -> Double { value > 0 ? (amount / value) * 100 : 0 }

    func label(for listing: Listing) -> String {
        listing.asset.listedStock.map { "\(listing.asset.symbol) · \($0.venue.shortName)" } ?? listing.asset.symbol
    }
}

extension MarketData {
    var portfolioConcentration: PortfolioConcentration {
        PortfolioConcentration(holdings: portfolio) { asset in
            quoteFailed(for: asset) || (asset.priceMove == nil && asset.looksUnpriced)
        }
    }
}
