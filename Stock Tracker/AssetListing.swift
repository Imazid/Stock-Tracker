import Foundation
import TradingCore

extension Asset {
    private static let knownETFs = Set(UniverseCatalog.all.filter { $0.assetClass == .etf }.map(\.id))
        .union(OnboardingCatalog.etfs.map { "\($0.exchange.lowercased()):\($0.symbol)" })
        .union(["asx:STW", "us:IVV"])

    var isListedETF: Bool {
        kind == .stock && (isETF == true || Self.knownETFs.contains(quoteIdentity))
    }

    nonisolated private static let exchanges: [String: Venue] = [
        "US": .us, "NYSE": .us, "XNYS": .us, "NASDAQ": .us, "XNAS": .us, "AMEX": .us,
        "NYSE AMERICAN": .us, "XASE": .us, "NYSE ARCA": .us, "NYSEARCA": .us, "ARCA": .us,
        "ARCX": .us, "BATS": .us, "BZX": .us, "OTC": .us,
        "ASX": .asx, "XASX": .asx, "AUSTRALIAN SECURITIES EXCHANGE": .asx,
        "LSE": .lse, "XLON": .lse, "XETRA": .xetra, "XETR": .xetra,
        "PARIS": .euronextParis, "XPAR": .euronextParis, "AMSTERDAM": .euronextAmsterdam, "XAMS": .euronextAmsterdam,
        "SIX": .six, "XSWX": .six, "TSE": .tse, "XTKS": .tse, "HKEX": .hkex, "XHKG": .hkex,
        "SGX": .sgx, "XSES": .sgx, "KRX": .krx, "XKRX": .krx, "NSE": .nse, "XNSE": .nse,
    ]

    /// Uses the recorded venue first. Unresolved stocks keep their original exchange identity.
    nonisolated var listedStock: (venue: Venue, symbol: String)? {
        guard kind == .stock else { return nil }
        let ticker = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !ticker.isEmpty, !ticker.hasPrefix("^") else { return nil }
        let exchange = exchange.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let venue = Self.exchanges[exchange]
        if let suffix = Venue.parse(yahooSymbol: ticker) {
            guard venue == suffix.venue || (venue == nil && ["", "MANUAL", "INTERNATIONAL"].contains(exchange)) else { return nil }
            return suffix
        }
        if let venue { return (venue, ticker) }
        guard exchange.isEmpty || exchange == "MANUAL" else { return nil }
        if QuoteService.popularASXSymbols.contains(ticker) { return (.asx, ticker) }
        let venues = Set(UniverseCatalog.all.filter { $0.symbol == ticker && $0.assetClass != .crypto }.map(\.venue))
        if venues.count == 1, let known = venues.first { return (known, ticker) }
        return nil
    }

    nonisolated var quoteIdentity: String {
        if kind == .crypto { return "crypto:\(symbol.uppercased())" }
        if let listedStock { return "\(listedStock.venue.rawValue):\(listedStock.symbol)" }
        return "\(kind.rawValue):\(exchange.uppercased()):\(symbol.uppercased())"
    }

    nonisolated var isUnresolvedUSQuote: Bool {
        kind == .stock && listedStock == nil && !symbol.hasPrefix("^") && (exchange.isEmpty || exchange == "Manual")
    }

    nonisolated var internationalQuoteSymbol: String? {
        if kind == .stock, exchange.caseInsensitiveCompare("International") == .orderedSame,
           Venue.parse(yahooSymbol: symbol) == nil { return symbol }
        guard let listedStock, let suffix = listedStock.venue.yahooSuffix, listedStock.venue != .asx else { return nil }
        return listedStock.symbol + suffix
    }
}
