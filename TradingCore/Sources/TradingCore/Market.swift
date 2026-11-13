import Foundation

// MARK: - Instruments

public enum AssetClass: String, Codable, CaseIterable, Sendable {
    case equity, etf, crypto
}

public enum MarketRegion: String, Codable, CaseIterable, Sendable {
    case americas, europe, asiaPacific, crypto

    public var displayName: String {
        switch self {
        case .americas: return "Americas"
        case .europe: return "Europe"
        case .asiaPacific: return "Asia-Pacific"
        case .crypto: return "Crypto"
        }
    }
}

/// Where an instrument trades. It decides the trading calendar and the currency.
public enum Venue: String, Codable, CaseIterable, Sendable {
    case us, asx, crypto
    case lse, xetra, euronextParis, euronextAmsterdam, six
    case tse, hkex, sgx, krx, nse

    public var currency: String {
        switch self {
        case .us, .crypto: return "USD"
        case .asx: return "AUD"
        case .lse: return "GBP"
        case .xetra, .euronextParis, .euronextAmsterdam: return "EUR"
        case .six: return "CHF"
        case .tse: return "JPY"
        case .hkex: return "HKD"
        case .sgx: return "SGD"
        case .krx: return "KRW"
        case .nse: return "INR"
        }
    }

    /// Reads after "The": "The London market is closed."
    public var displayName: String {
        switch self {
        case .us: return "US market"
        case .asx: return "ASX"
        case .crypto: return "Crypto"
        case .lse: return "London market"
        case .xetra: return "Frankfurt market (Xetra)"
        case .euronextParis: return "Paris market"
        case .euronextAmsterdam: return "Amsterdam market"
        case .six: return "Swiss market"
        case .tse: return "Tokyo market"
        case .hkex: return "Hong Kong market"
        case .sgx: return "Singapore market"
        case .krx: return "Korean market"
        case .nse: return "Indian market (NSE)"
        }
    }

    /// The badge shown next to a ticker.
    public var shortName: String {
        switch self {
        case .us: return "US"
        case .asx: return "ASX"
        case .crypto: return "Crypto"
        case .lse: return "LSE"
        case .xetra: return "XETRA"
        case .euronextParis: return "PARIS"
        case .euronextAmsterdam: return "AMS"
        case .six: return "SIX"
        case .tse: return "TSE"
        case .hkex: return "HKEX"
        case .sgx: return "SGX"
        case .krx: return "KRX"
        case .nse: return "NSE"
        }
    }

    public var country: String {
        switch self {
        case .us: return "United States"
        case .asx: return "Australia"
        case .crypto: return "Global"
        case .lse: return "United Kingdom"
        case .xetra: return "Germany"
        case .euronextParis: return "France"
        case .euronextAmsterdam: return "Netherlands"
        case .six: return "Switzerland"
        case .tse: return "Japan"
        case .hkex: return "Hong Kong"
        case .sgx: return "Singapore"
        case .krx: return "South Korea"
        case .nse: return "India"
        }
    }

    public var region: MarketRegion {
        switch self {
        case .us: return .americas
        case .crypto: return .crypto
        case .lse, .xetra, .euronextParis, .euronextAmsterdam, .six: return .europe
        case .asx, .tse, .hkex, .sgx, .krx, .nse: return .asiaPacific
        }
    }

    /// The suffix Yahoo Finance puts on a listing here ("VOD.L", "7203.T"); nil for venues
    /// priced elsewhere (US stocks and crypto come from Alpaca).
    public var yahooSuffix: String? {
        switch self {
        case .us, .crypto: return nil
        case .asx: return ".AX"
        case .lse: return ".L"
        case .xetra: return ".DE"
        case .euronextParis: return ".PA"
        case .euronextAmsterdam: return ".AS"
        case .six: return ".SW"
        case .tse: return ".T"
        case .hkex: return ".HK"
        case .sgx: return ".SI"
        case .krx: return ".KS"
        case .nse: return ".NS"
        }
    }

    /// The venue and bare ticker behind a Yahoo symbol: "VOD.L" → (.lse, "VOD").
    public static func parse(yahooSymbol: String) -> (venue: Venue, symbol: String)? {
        let upper = yahooSymbol.uppercased()
        for venue in Venue.allCases {
            guard let suffix = venue.yahooSuffix, upper.hasSuffix(suffix), upper.count > suffix.count else { continue }
            return (venue, String(upper.dropLast(suffix.count)))
        }
        return nil
    }
}

public struct Instrument: Codable, Hashable, Identifiable, Sendable {
    public var symbol: String
    public var name: String
    public var assetClass: AssetClass
    public var venue: Venue
    public var currency: String

    public var id: String { "\(venue.rawValue):\(symbol)" }

    public init(symbol: String, name: String = "", assetClass: AssetClass, venue: Venue, currency: String? = nil) {
        self.symbol = symbol.uppercased()
        self.name = name.isEmpty ? symbol.uppercased() : name
        self.assetClass = assetClass
        self.venue = venue
        self.currency = currency ?? venue.currency
    }

    /// Lenient decoding, so a hand-written or AI-drafted strategy can give just a symbol and
    /// an asset class. Anything left out is filled in from what was given.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let symbol = try c.decode(String.self, forKey: .symbol).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let assetClass = try c.decodeIfPresent(AssetClass.self, forKey: .assetClass)
        let venue = try c.decodeIfPresent(Venue.self, forKey: .venue)
        let known = UniverseCatalog.instrument(symbol: symbol, preferring: venue)
        let resolvedClass = assetClass ?? known?.assetClass ?? .equity
        let resolvedVenue = venue ?? known?.venue ?? (resolvedClass == .crypto ? .crypto : .us)
        self.init(symbol: symbol,
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? known?.name ?? "",
                  assetClass: resolvedClass, venue: resolvedVenue,
                  currency: try c.decodeIfPresent(String.self, forKey: .currency))
    }

    public static func usStock(_ symbol: String, name: String = "") -> Instrument {
        Instrument(symbol: symbol, name: name, assetClass: .equity, venue: .us)
    }

    public static func usETF(_ symbol: String, name: String = "") -> Instrument {
        Instrument(symbol: symbol, name: name, assetClass: .etf, venue: .us)
    }

    public static func asxStock(_ symbol: String, name: String = "") -> Instrument {
        Instrument(symbol: symbol, name: name, assetClass: .equity, venue: .asx)
    }

    public static func crypto(_ symbol: String, name: String = "") -> Instrument {
        Instrument(symbol: symbol, name: name, assetClass: .crypto, venue: .crypto)
    }

    /// A share or fund listed on an exchange outside the US.
    public static func listed(_ symbol: String, name: String = "", on venue: Venue, etf: Bool = false) -> Instrument {
        Instrument(symbol: symbol, name: name, assetClass: etf ? .etf : .equity, venue: venue)
    }

    /// The symbol Yahoo Finance knows this listing by ("VOD.L"); the bare symbol where Yahoo
    /// isn't the price source.
    public var yahooSymbol: String { symbol + (venue.yahooSuffix ?? "") }
}

/// What an execution venue will accept for one instrument. Advertised by the broker
/// adapter, never assumed by the caller.
public struct InstrumentRules: Codable, Hashable, Sendable {
    public var quantityIncrement: Double
    public var minQuantity: Double
    public var minNotional: Double
    public var priceIncrement: Double
    public var fractionable: Bool

    public init(quantityIncrement: Double, minQuantity: Double, minNotional: Double,
                priceIncrement: Double, fractionable: Bool) {
        self.quantityIncrement = quantityIncrement
        self.minQuantity = minQuantity
        self.minNotional = minNotional
        self.priceIncrement = priceIncrement
        self.fractionable = fractionable
    }
}

// MARK: - Market data

public enum Timeframe: String, Codable, CaseIterable, Sendable {
    case hour, day

    public var seconds: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .day: return 86_400
        }
    }

    public var barName: String { self == .day ? "daily" : "hourly" }
}

/// Where a number came from. Trading code only accepts `market`; fixtures exist for
/// tests and are refused everywhere else, and `synthetic` is refused always.
public struct DataProvenance: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case market, fixture, synthetic }

    public var kind: Kind
    public var source: String
    /// How far behind the exchange the feed runs (0 = real time).
    public var delaySeconds: Int

    public init(kind: Kind, source: String, delaySeconds: Int = 0) {
        self.kind = kind
        self.source = source
        self.delaySeconds = delaySeconds
    }

    public static func market(_ source: String, delaySeconds: Int = 0) -> DataProvenance {
        DataProvenance(kind: .market, source: source, delaySeconds: delaySeconds)
    }

    public static func fixture(_ name: String) -> DataProvenance {
        DataProvenance(kind: .fixture, source: name)
    }

    public static let synthetic = DataProvenance(kind: .synthetic, source: "synthetic")

    public var isRealMarketData: Bool { kind == .market }
}

public struct Bar: Codable, Hashable, Sendable {
    /// Start of the bar.
    public var time: Date
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double

    public init(time: Date, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    public var isValid: Bool {
        [open, high, low, close].allSatisfy { $0.isFinite && $0 > 0 }
            && high >= low && volume.isFinite && volume >= 0
    }
}

public struct BarSeries: Codable, Sendable {
    public var instrument: Instrument
    public var timeframe: Timeframe
    /// Oldest first.
    public var bars: [Bar]
    public var provenance: DataProvenance
    public var fetchedAt: Date
    /// False when the volumes cover one venue only (a single exchange's slice of the
    /// market). Such volumes say nothing about how liquid the asset is, so they are never
    /// used to measure liquidity.
    public var volumeIsMarketWide: Bool

    public init(instrument: Instrument, timeframe: Timeframe, bars: [Bar],
                provenance: DataProvenance, fetchedAt: Date, volumeIsMarketWide: Bool = true) {
        self.instrument = instrument
        self.timeframe = timeframe
        self.bars = bars.filter(\.isValid).sorted { $0.time < $1.time }
        self.provenance = provenance
        self.fetchedAt = fetchedAt
        self.volumeIsMarketWide = volumeIsMarketWide
    }
}

public struct Quote: Codable, Hashable, Sendable {
    public var instrumentID: String
    public var last: Double
    public var bid: Double?
    public var ask: Double?
    /// When the venue produced this price (not when we fetched it).
    public var time: Date
    public var provenance: DataProvenance
    /// A market-wide daily volume in units (today's, or a typical day's), when one is known.
    /// The simulator uses it to decide how much of a large order can fill at once. Leave it
    /// nil rather than pass one venue's slice of the market.
    public var dayVolume: Double?

    public init(instrumentID: String, last: Double, bid: Double? = nil, ask: Double? = nil,
                time: Date, provenance: DataProvenance, dayVolume: Double? = nil) {
        self.instrumentID = instrumentID
        self.last = last
        self.bid = bid
        self.ask = ask
        self.time = time
        self.provenance = provenance
        self.dayVolume = dayVolume
    }

    /// A usable bid and ask: both present, positive and not crossed.
    public var hasTwoSidedMarket: Bool {
        guard let bid, let ask else { return false }
        return bid > 0 && ask > 0 && ask >= bid
    }

    public var mid: Double {
        guard hasTwoSidedMarket, let bid, let ask else { return last }
        return (bid + ask) / 2
    }

    /// Spread in basis points of the mid; nil without a two-sided market.
    public var spreadBps: Double? {
        guard hasTwoSidedMarket, let bid, let ask, mid > 0 else { return nil }
        return (ask - bid) / mid * 10_000
    }

    public func age(at now: Date) -> TimeInterval { now.timeIntervalSince(time) }
}

/// Liquidity and volatility of an instrument, measured from real daily bars.
public struct InstrumentStats: Codable, Hashable, Sendable {
    public var averageDollarVolume: Double
    /// Standard deviation of daily returns, in percent.
    public var dailyVolatilityPct: Double

    public init(averageDollarVolume: Double, dailyVolatilityPct: Double) {
        self.averageDollarVolume = averageDollarVolume
        self.dailyVolatilityPct = dailyVolatilityPct
    }

    /// From the last `lookback` completed daily bars; nil when there are too few.
    public static func measure(_ bars: [Bar], lookback: Int = 20) -> InstrumentStats? {
        guard bars.count >= lookback + 1 else { return nil }
        let window = Array(bars.suffix(lookback + 1))
        let dollarVolume = window.suffix(lookback).map { $0.close * $0.volume }.reduce(0, +) / Double(lookback)
        var returns: [Double] = []
        for i in 1..<window.count where window[i - 1].close > 0 {
            returns.append(window[i].close / window[i - 1].close - 1)
        }
        guard returns.count >= 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1)
        return InstrumentStats(averageDollarVolume: dollarVolume, dailyVolatilityPct: variance.squareRoot() * 100)
    }
}

/// Everything an agent run or an order needs to know about the market, gathered up front
/// so the decision code itself never touches the network.
public struct MarketSnapshot: Sendable {
    public var series: [String: BarSeries]
    public var quotes: [String: Quote]
    /// Instruments whose data could not be loaded, with the reason. Nothing trades on these.
    public var failures: [String: String]
    /// Market-wide average daily traded value, for instruments whose bars carry only one
    /// venue's volume (crypto, mostly).
    public var dollarVolume: [String: Double]

    public init(series: [String: BarSeries] = [:], quotes: [String: Quote] = [:], failures: [String: String] = [:],
                dollarVolume: [String: Double] = [:]) {
        self.series = series
        self.quotes = quotes
        self.failures = failures
        self.dollarVolume = dollarVolume
    }

    /// Liquidity and volatility for each instrument with daily bars. An instrument whose
    /// volume can't be trusted and has no market-wide figure gets no stats at all — an
    /// unknown is reported as unknown, never as a small number.
    public func stats(calendar: MarketCalendar = .standard, now: Date) -> [String: InstrumentStats] {
        var out: [String: InstrumentStats] = [:]
        for (id, s) in series where s.timeframe == .day {
            guard let measured = InstrumentStats.measure(calendar.completedBars(s, now: now)) else { continue }
            if s.volumeIsMarketWide {
                out[id] = measured
            } else if let known = dollarVolume[id], known > 0 {
                out[id] = InstrumentStats(averageDollarVolume: known, dailyVolatilityPct: measured.dailyVolatilityPct)
            }
        }
        return out
    }
}

/// Supplies real market data. Implementations throw when a source fails — they never
/// substitute an invented series.
public protocol MarketDataProviding: Sendable {
    func bars(for instrument: Instrument, timeframe: Timeframe, count: Int) async throws -> BarSeries
    func quote(for instrument: Instrument) async throws -> Quote
    /// Market-wide average daily traded value, for instruments whose bars only carry one
    /// venue's volume. nil when it isn't known.
    func averageDollarVolume(for instrument: Instrument) async -> Double?
}

public extension MarketDataProviding {
    func averageDollarVolume(for instrument: Instrument) async -> Double? { nil }

    /// Bars and quotes for a set of instruments. Failures are recorded, not thrown, so one
    /// missing symbol doesn't stop the rest — it just can't be traded.
    func snapshot(for instruments: [Instrument], timeframe: Timeframe, barCount: Int) async -> MarketSnapshot {
        var snapshot = MarketSnapshot()
        await withTaskGroup(of: (Instrument, Result<BarSeries, Error>, Result<Quote, Error>, Double?).self) { group in
            for instrument in instruments {
                group.addTask {
                    async let bars = Result { try await self.bars(for: instrument, timeframe: timeframe, count: barCount) }
                    async let quote = Result { try await self.quote(for: instrument) }
                    let series = await bars
                    var known: Double?
                    if case .success(let s) = series, !s.volumeIsMarketWide {
                        known = await self.averageDollarVolume(for: instrument)
                    }
                    return (instrument, series, await quote, known)
                }
            }
            for await (instrument, bars, quote, known) in group {
                if let known { snapshot.dollarVolume[instrument.id] = known }
                switch bars {
                case .success(let series): snapshot.series[instrument.id] = series
                case .failure(let error): snapshot.failures[instrument.id] = "Price history unavailable: \(error.localizedDescription)"
                }
                switch quote {
                case .success(let q): snapshot.quotes[instrument.id] = q
                case .failure(let error):
                    if snapshot.failures[instrument.id] == nil {
                        snapshot.failures[instrument.id] = "Live quote unavailable: \(error.localizedDescription)"
                    }
                }
            }
        }
        return snapshot
    }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
