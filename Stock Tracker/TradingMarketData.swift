//
//  TradingMarketData.swift
//  Stock Tracker
//
//  Real market data for the trading engine: daily bars and live quotes, each
//  stamped with where it came from and when the venue produced it.
//
//  This is separate from the chart code on purpose. Charts may show a stale
//  series rather than an empty one; trading may not. Every call here throws
//  when the source fails — nothing is cached past its use-by time and nothing
//  is ever made up. The engine refuses anything that isn't marked as market
//  data, so a failure means "no trade".
//
//  The Alpaca key is used to READ prices only. No request in this file can
//  place, change or cancel an order.
//

import Foundation
import OSLog
import TradingCore

nonisolated enum TradingDataError: LocalizedError {
    case notConfigured
    case unsupported(String)
    case http(Int, String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Market data isn't set up."
        case .unsupported(let what): return what
        case .http(let code, let source): return "\(source) answered with an error (\(code))."
        case .empty(let symbol): return "No prices came back for \(symbol)."
        }
    }
}

/// Bars and quotes from Alpaca (US stocks, ETFs and crypto) and Yahoo Finance (ASX).
nonisolated struct LiveMarketData: MarketDataProviding {
    private let alpacaKey: String
    private let alpacaSecret: String
    private let session: URLSession
    private let cache = BarCache()

    private static let alpaca = "https://data.alpaca.markets"
    private static let yahoo = "https://query1.finance.yahoo.com"
    /// The consolidated (all-exchange) tape is free once it is 15 minutes old.
    private static let consolidatedDelay: TimeInterval = 16 * 60

    init(alpacaKey: String, alpacaSecret: String) {
        self.alpacaKey = alpacaKey
        self.alpacaSecret = alpacaSecret
        self.session = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 15)
    }

    // MARK: MarketDataProviding

    func bars(for instrument: Instrument, timeframe: Timeframe, count: Int) async throws -> BarSeries {
        let key = "\(instrument.id)|\(timeframe.rawValue)|\(count)"
        if let hit = await cache.series(key) { return hit }
        let series: BarSeries
        switch instrument.venue {
        case .us:
            guard timeframe == .day else { throw TradingDataError.unsupported("Hourly bars aren't available for stocks yet.") }
            series = try await usDailyBars(instrument, count: count)
        case .crypto:
            series = try await cryptoBars(instrument, timeframe: timeframe, count: count)
        case .asx:
            guard timeframe == .day else { throw TradingDataError.unsupported("Hourly bars aren't available for ASX shares.") }
            series = try await asxDailyBars(instrument, count: count)
        }
        guard !series.bars.isEmpty else { throw TradingDataError.empty(instrument.symbol) }
        await cache.store(series, key: key)
        return series
    }

    func quote(for instrument: Instrument) async throws -> Quote {
        guard let quote = try await quotes(for: [instrument])[instrument.id] else {
            throw TradingDataError.empty(instrument.symbol)
        }
        return quote
    }

    /// Market-wide traded value for crypto. Alpaca's crypto bars only count its own small
    /// venue, so the figure comes from CoinGecko's 24-hour volume and is kept for a day.
    func averageDollarVolume(for instrument: Instrument) async -> Double? {
        guard instrument.assetClass == .crypto, let id = QuoteService.coinGeckoID(for: instrument.symbol) else { return nil }
        if let hit = await cache.dollarVolume(instrument.id) { return hit }
        guard let assets = try? await APIService.shared.fetchCryptoPricesBatch(ids: [id]), let asset = assets[id] else { return nil }
        // Only CoinGecko's answer is market-wide; the Alpaca fallback is one venue again.
        let volume = await MainActor.run { asset.exchange == "CoinGecko" ? asset.volume : 0 }
        guard volume > 0 else { return nil }
        await cache.storeDollarVolume(volume, id: instrument.id)
        return volume
    }

    // MARK: Quotes

    /// Live quotes for several instruments, one request per venue. Instruments with no
    /// usable price are simply absent from the result.
    func quotes(for instruments: [Instrument]) async throws -> [String: Quote] {
        var out: [String: Quote] = [:]
        let us = instruments.filter { $0.venue == .us }
        let crypto = instruments.filter { $0.venue == .crypto }
        let asx = instruments.filter { $0.venue == .asx }
        var firstError: Error?
        if !us.isEmpty {
            do { out.merge(try await usQuotes(us)) { a, _ in a } } catch { firstError = firstError ?? error }
        }
        if !crypto.isEmpty {
            do { out.merge(try await cryptoQuotes(crypto)) { a, _ in a } } catch { firstError = firstError ?? error }
        }
        for instrument in asx {
            do { out[instrument.id] = try await asxQuote(instrument) } catch { firstError = firstError ?? error }
        }
        if out.isEmpty, let firstError { throw firstError }
        return out
    }

    private func usQuotes(_ instruments: [Instrument]) async throws -> [String: Quote] {
        let symbols = instruments.map { Self.clean($0.symbol) }.joined(separator: ",")
        let json = try await alpacaJSON("/v2/stocks/snapshots", [("symbols", symbols), ("feed", "iex")])
        var out: [String: Quote] = [:]
        for instrument in instruments {
            guard let snapshot = json[Self.clean(instrument.symbol)] as? [String: Any],
                  let quote = Self.quote(from: snapshot, instrument: instrument, source: "Alpaca (IEX)") else { continue }
            out[instrument.id] = quote
        }
        return out
    }

    private func cryptoQuotes(_ instruments: [Instrument]) async throws -> [String: Quote] {
        let pairs = instruments.map { "\(Self.clean($0.symbol))/USD" }.joined(separator: ",")
        let json = try await alpacaJSON("/v1beta3/crypto/us/snapshots", [("symbols", pairs)])
        let snapshots = json["snapshots"] as? [String: Any] ?? [:]
        var out: [String: Quote] = [:]
        for instrument in instruments {
            guard let snapshot = snapshots["\(Self.clean(instrument.symbol))/USD"] as? [String: Any],
                  let quote = Self.quote(from: snapshot, instrument: instrument, source: "Alpaca crypto") else { continue }
            out[instrument.id] = quote
        }
        return out
    }

    /// Builds a quote from an Alpaca snapshot. The bid and ask are kept only when they make
    /// a believable market: IEX is one exchange, and outside busy hours its book can show a
    /// zero ask or a bid far from the last trade. Those are dropped, and the engine then
    /// says the spread couldn't be measured instead of trusting a wrong one.
    private static func quote(from snapshot: [String: Any], instrument: Instrument, source: String) -> Quote? {
        guard let trade = snapshot["latestTrade"] as? [String: Any], let last = trade["p"] as? Double, last > 0,
              let tradeTime = (trade["t"] as? String).flatMap(parseTime) else { return nil }
        var bid: Double?
        var ask: Double?
        var time = tradeTime
        if let q = snapshot["latestQuote"] as? [String: Any], let bp = q["bp"] as? Double, let ap = q["ap"] as? Double,
           bp > 0, ap >= bp, (ap - bp) / ((ap + bp) / 2) <= 0.01, abs((ap + bp) / 2 / last - 1) <= 0.01 {
            bid = bp
            ask = ap
            if let quoteTime = (q["t"] as? String).flatMap(parseTime) { time = max(time, quoteTime) }
        }
        // Volume here is one venue's, so it is not passed on as the day's volume.
        return Quote(instrumentID: instrument.id, last: last, bid: bid, ask: ask, time: time,
                     provenance: .market(source), dayVolume: nil)
    }

    // MARK: Bars

    private func usDailyBars(_ instrument: Instrument, count: Int) async throws -> BarSeries {
        let now = Date()
        let start = now.addingTimeInterval(-Double(count) * 86_400 * 1.5 - 12 * 86_400)
        let symbol = Self.clean(instrument.symbol)
        func fetch(feed: String, end: Date?) async throws -> [Bar] {
            var query = [("timeframe", "1Day"), ("start", Self.iso(start)), ("limit", "10000"),
                         ("feed", feed), ("adjustment", "all"), ("sort", "asc")]
            if let end { query.append(("end", Self.iso(end))) }
            return try await pagedBars("/v2/stocks/\(symbol)/bars", query) { ($0["bars"] as? [[String: Any]]) ?? [] }
        }
        do {
            // Consolidated tape: every exchange's trades, so prices match the official
            // open/close and the volume is the whole market's.
            let bars = try await fetch(feed: "sip", end: now.addingTimeInterval(-Self.consolidatedDelay))
            if !bars.isEmpty {
                return BarSeries(instrument: instrument, timeframe: .day, bars: Array(bars.suffix(count)),
                                 provenance: .market("Alpaca (consolidated)"), fetchedAt: now)
            }
        } catch TradingDataError.http(let code, _) where code == 403 || code == 422 {
            AppLogger.api.info("Consolidated bars not available on this plan; using IEX")
        }
        let bars = try await fetch(feed: "iex", end: nil)
        return BarSeries(instrument: instrument, timeframe: .day, bars: Array(bars.suffix(count)),
                         provenance: .market("Alpaca (IEX)"), fetchedAt: now, volumeIsMarketWide: false)
    }

    private func cryptoBars(_ instrument: Instrument, timeframe: Timeframe, count: Int) async throws -> BarSeries {
        let now = Date()
        let pair = "\(Self.clean(instrument.symbol))/USD"
        let span = timeframe == .day ? Double(count + 3) * 86_400 : Double(count + 3) * 3_600
        let query = [("symbols", pair), ("timeframe", timeframe == .day ? "1Day" : "1Hour"),
                     ("start", Self.iso(now.addingTimeInterval(-span))), ("limit", "10000"), ("sort", "asc")]
        let bars = try await pagedBars("/v1beta3/crypto/us/bars", query) {
            (($0["bars"] as? [String: Any])?[pair] as? [[String: Any]]) ?? []
        }
        return BarSeries(instrument: instrument, timeframe: timeframe, bars: Array(bars.suffix(count)),
                         provenance: .market("Alpaca crypto"), fetchedAt: now, volumeIsMarketWide: false)
    }

    private func pagedBars(_ path: String, _ query: [(String, String)],
                           extract: ([String: Any]) -> [[String: Any]]) async throws -> [Bar] {
        var bars: [Bar] = []
        var token: String?
        for _ in 0..<6 {
            var q = query
            if let token { q.append(("page_token", token)) }
            let json = try await alpacaJSON(path, q)
            for raw in extract(json) {
                guard let time = (raw["t"] as? String).flatMap(Self.parseTime),
                      let o = raw["o"] as? Double, let h = raw["h"] as? Double,
                      let l = raw["l"] as? Double, let c = raw["c"] as? Double else { continue }
                bars.append(Bar(time: time, open: o, high: h, low: l, close: c, volume: raw["v"] as? Double ?? 0))
            }
            token = json["next_page_token"] as? String
            if token == nil { break }
        }
        return bars
    }

    // MARK: ASX (Yahoo Finance, about 20 minutes delayed, prices in AUD)

    private static let asxProvenance = DataProvenance.market("Yahoo Finance (ASX, delayed)", delaySeconds: 20 * 60)

    private func asxChart(_ instrument: Instrument, range: String) async throws -> [String: Any] {
        let symbol = Self.clean(instrument.symbol) + ".AX"
        guard let url = URL(string: "\(Self.yahoo)/v8/finance/chart/\(symbol)?interval=1d&range=\(range)") else {
            throw TradingDataError.empty(instrument.symbol)
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        NetRequestLog.record(endpoint: "trading-yahoo", url: url)
        let (data, response) = try await session.rateLimitedData(for: request, endpoint: "yahoo", config: .yahoo)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw TradingDataError.http(status, "Yahoo Finance") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any], (meta["currency"] as? String) == "AUD" else {
            throw TradingDataError.empty(instrument.symbol)
        }
        return result
    }

    private func asxDailyBars(_ instrument: Instrument, count: Int) async throws -> BarSeries {
        let result = try await asxChart(instrument, range: count > 250 ? (count > 500 ? "5y" : "2y") : "1y")
        guard let stamps = result["timestamp"] as? [Double] ?? (result["timestamp"] as? [Int])?.map(Double.init),
              let q = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first else {
            throw TradingDataError.empty(instrument.symbol)
        }
        func column(_ name: String) -> [Double?] { (q[name] as? [Any])?.map { $0 as? Double } ?? [] }
        let o = column("open"), h = column("high"), l = column("low"), c = column("close"), v = column("volume")
        var bars: [Bar] = []
        for i in stamps.indices {
            guard i < o.count, i < h.count, i < l.count, i < c.count,
                  let open = o[i], let high = h[i], let low = l[i], let close = c[i] else { continue }
            bars.append(Bar(time: Date(timeIntervalSince1970: stamps[i]), open: open, high: high, low: low, close: close,
                            volume: i < v.count ? (v[i] ?? 0) : 0))
        }
        return BarSeries(instrument: instrument, timeframe: .day, bars: Array(bars.suffix(count)),
                         provenance: Self.asxProvenance, fetchedAt: Date())
    }

    private func asxQuote(_ instrument: Instrument) async throws -> Quote {
        let result = try await asxChart(instrument, range: "5d")
        guard let meta = result["meta"] as? [String: Any], let last = meta["regularMarketPrice"] as? Double, last > 0,
              let stamp = meta["regularMarketTime"] as? Double ?? (meta["regularMarketTime"] as? Int).map(Double.init) else {
            throw TradingDataError.empty(instrument.symbol)
        }
        return Quote(instrumentID: instrument.id, last: last, time: Date(timeIntervalSince1970: stamp),
                     provenance: Self.asxProvenance,
                     dayVolume: (meta["regularMarketVolume"] as? Double) ?? (meta["regularMarketVolume"] as? Int).map(Double.init))
    }

    // MARK: Plumbing

    private func alpacaJSON(_ path: String, _ query: [(String, String)]) async throws -> [String: Any] {
        guard !alpacaKey.isEmpty, !alpacaSecret.isEmpty else { throw TradingDataError.notConfigured }
        var components = URLComponents(string: Self.alpaca + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw TradingDataError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"      // read-only: this client has no other verb
        request.setValue(alpacaKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaSecret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        NetRequestLog.record(endpoint: "trading-alpaca", url: url)
        let (data, response) = try await session.rateLimitedData(for: request, endpoint: "alpaca", config: .alpaca)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw TradingDataError.http(status, "Alpaca") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Tickers go into URLs, so only ticker characters survive.
    private static func clean(_ symbol: String) -> String {
        String(symbol.uppercased().unicodeScalars.filter {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0)
        }.prefix(12))
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Alpaca sends up to nanosecond precision ("…59.611143703Z"); seconds are enough here.
    static func parseTime(_ text: String) -> Date? {
        guard text.count >= 19 else { return nil }
        return ISO8601DateFormatter().date(from: String(text.prefix(19)) + "Z")
    }
}

/// Short-lived memory of fetched bars, so a run that needs the same series twice (an agent
/// and the order ticket, say) asks once. Daily bars only change at the close.
private actor BarCache {
    private var series: [String: (BarSeries, Date)] = [:]
    private var volumes: [String: (Double, Date)] = [:]

    func series(_ key: String) -> BarSeries? {
        guard let (value, at) = series[key], Date().timeIntervalSince(at) < 300 else { return nil }
        return value
    }

    func store(_ value: BarSeries, key: String) {
        if series.count > 200 { series.removeAll() }
        series[key] = (value, Date())
    }

    func dollarVolume(_ id: String) -> Double? {
        guard let (value, at) = volumes[id], Date().timeIntervalSince(at) < 86_400 else { return nil }
        return value
    }

    func storeDollarVolume(_ value: Double, id: String) { volumes[id] = (value, Date()) }
}

// MARK: - App assets ↔ trading instruments

extension Instrument {
    /// The tradable instrument behind one of the app's assets, or nil when it can't be
    /// paper traded (an index level, or a market with no price feed for trading).
    nonisolated init?(asset: Asset) {
        let symbol = asset.symbol.uppercased().replacingOccurrences(of: ".AX", with: "")
        guard !symbol.hasPrefix("^"), !symbol.isEmpty else { return nil }
        switch asset.kind {
        case .crypto:
            guard QuoteService.coinGeckoID(for: symbol) != nil else { return nil }
            self = .crypto(symbol, name: asset.name)
        case .stock:
            if QuoteService.isASX(asset) {
                self = .asxStock(symbol, name: asset.name)
            } else if asset.exchange == "International" {
                return nil
            } else if let known = UniverseCatalog.instrument(symbol: symbol, preferring: .us), known.venue == .us {
                self = Instrument(symbol: symbol, name: asset.name, assetClass: known.assetClass, venue: .us)
            } else {
                self = .usStock(symbol, name: asset.name)
            }
        }
    }

    /// The app asset for this instrument, for logos, detail pages and search.
    nonisolated var asAsset: Asset {
        Asset(symbol: symbol, name: name, price: 0, change: 0, changePercent: 0, volume: 0,
              kind: assetClass == .crypto ? .crypto : .stock,
              exchange: venue == .asx ? "ASX" : (venue == .crypto ? "Crypto" : "US"))
    }
}

#if DEBUG
/// Deterministic prices for UI tests (`-UITestTradingFixture`). Marked as a fixture, so the
/// engine only accepts it while the test flag is on — never in a normal run.
nonisolated struct FixtureMarketData: MarketDataProviding {
    /// A gentle climb that sits above its 20-day average, so trend rules fire.
    private func closes(for instrument: Instrument, count: Int) -> [Double] {
        let base: Double = instrument.assetClass == .crypto ? 60_000 : (instrument.symbol == "MSFT" ? 400 : 200)
        let drift = Double(instrument.symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5) * 0.0002
        return (0..<count).map { i in base * (1 + Double(i) * (0.0015 + drift) + sin(Double(i) / 6) * 0.02) }
    }

    func bars(for instrument: Instrument, timeframe: Timeframe, count: Int) async throws -> BarSeries {
        let now = Date()
        var days: [Date] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instrument.venue == .asx ? "Australia/Sydney" : (instrument.venue == .crypto ? "UTC" : "America/New_York"))!
        var day = cal.startOfDay(for: now)
        while days.count < count {
            day = cal.date(byAdding: .day, value: -1, to: day)!
            if MarketCalendar.standard.isTradingDay(instrument.venue, day) { days.append(day) }
        }
        days.reverse()
        let values = closes(for: instrument, count: count)
        let bars = values.enumerated().map { i, close in
            let open = i == 0 ? close : values[i - 1]
            return Bar(time: days[i], open: open, high: max(open, close) * 1.004, low: min(open, close) * 0.996,
                       close: close, volume: 8_000_000)
        }
        return BarSeries(instrument: instrument, timeframe: timeframe, bars: bars, provenance: .fixture("ui-test"), fetchedAt: now)
    }

    func quote(for instrument: Instrument) async throws -> Quote {
        let last = closes(for: instrument, count: 260).last ?? 100
        return Quote(instrumentID: instrument.id, last: last, bid: last * 0.9999, ask: last * 1.0001, time: Date(),
                     provenance: .fixture("ui-test"), dayVolume: nil)
    }

    func quotes(for instruments: [Instrument]) async throws -> [String: Quote] {
        var out: [String: Quote] = [:]
        for instrument in instruments { out[instrument.id] = try await quote(for: instrument) }
        return out
    }
}
#endif
