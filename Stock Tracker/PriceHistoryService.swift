//
//  PriceHistoryService.swift
//  Stock Tracker
//
//  The single source of chart data. Everything here is real market data:
//  when a source fails we throw (the chart shows "unavailable"); we never
//  invent a line.
//
//  - `history(for:range:)`  — one asset, shaped so each range means what it
//    says: 1D = the latest *regular* session (exchange-local hours), 1W =
//    regular hours only, crypto 1D = the last 24h.
//  - `portfolioSeries(...)` — value of the *current* holdings over the range,
//    rebuilt from each holding's price history. It ends exactly at the live
//    portfolio value and, for 1D, starts from yesterday's close — so the chart
//    always agrees with the header's "today" number.
//
//  Prices are USD throughout (see FXRates).
//

import Foundation
import OSLog

// MARK: - Trading hours

/// Regular-session hours for an exchange, in its own time zone.
struct TradingHours: Sendable {
    let timeZone: TimeZone
    let openMinute: Int   // minutes after local midnight
    let closeMinute: Int

    static let us = TradingHours(timeZone: TimeZone(identifier: "America/New_York")!, openMinute: 9 * 60 + 30, closeMinute: 16 * 60)
    /// ASX continuous trading 10:00–16:00, closing auction to ~16:10.
    static let asx = TradingHours(timeZone: TimeZone(identifier: "Australia/Sydney")!, openMinute: 10 * 60, closeMinute: 16 * 60 + 12)

    /// nil = trades around the clock (crypto) or hours unknown.
    static func forAsset(_ asset: Asset) -> TradingHours? {
        if asset.kind == .crypto { return nil }
        if QuoteService.isASX(asset) { return .asx }
        if asset.exchange == "International" { return nil }
        return .us
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Whether a bar starting at `date` and lasting `barMinutes` overlaps the regular session.
    func overlapsSession(_ date: Date, barMinutes: Int) -> Bool {
        let start = minuteOfDay(date)
        return start < closeMinute && start + max(barMinutes, 1) > openMinute
    }

    func sameSessionDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    /// The full regular session on the trading day containing `date`.
    func session(containing date: Date) -> ClosedRange<Date> {
        let day = calendar.startOfDay(for: date)
        let open = day.addingTimeInterval(TimeInterval(openMinute * 60))
        let close = day.addingTimeInterval(TimeInterval(closeMinute * 60))
        return open...close
    }
}

// MARK: - Shaping

enum ChartShaper {
    static func shape(_ raw: [PricePoint], for asset: Asset, range: TimeRange) -> [PricePoint] {
        let points = raw.filter { $0.price > 0 && $0.price.isFinite }.sorted { $0.date < $1.date }
        guard let last = points.last else { return [] }

        guard let hours = TradingHours.forAsset(asset) else {
            // 24/7 markets: 1D is simply the trailing 24 hours.
            if range == .oneDay {
                let cutoff = last.date.addingTimeInterval(-24 * 3600)
                return points.filter { $0.date >= cutoff }
            }
            return points
        }

        switch range {
        case .oneDay:
            let bar = typicalBarMinutes(points)
            let regular = points.filter { hours.overlapsSession($0.date, barMinutes: bar) }
            guard let lastRegular = regular.last else { return [] }
            return regular.filter { hours.sameSessionDay($0.date, lastRegular.date) }
        case .oneWeek:
            let bar = typicalBarMinutes(points)
            return points.filter { hours.overlapsSession($0.date, barMinutes: bar) }
        default:
            return points
        }
    }

    /// Median spacing between points, in minutes (bar length of intraday data).
    static func typicalBarMinutes(_ points: [PricePoint]) -> Int {
        guard points.count > 2 else { return 15 }
        let gaps = zip(points.dropFirst(), points).map { $0.date.timeIntervalSince($1.date) / 60 }.sorted()
        let median = gaps[gaps.count / 2]
        return Int(min(max(median.rounded(), 1), 60))
    }

    /// Evenly thins a long series for rendering, always keeping the last point.
    static func downsample(_ points: [PricePoint], to maxCount: Int) -> [PricePoint] {
        guard points.count > maxCount, maxCount > 2 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { points[Int((Double($0) * step).rounded())] }
    }
}

// MARK: - Mini series (row sparklines)

struct MiniSeries: Sendable, Equatable {
    let values: [Double]
    let baseline: Double
    let sessionDate: Date?
}

// MARK: - Portfolio series

struct PortfolioSeries: Sendable {
    let points: [PricePoint]
    /// Value at the previous close (1D only); otherwise nil → compare with the first point.
    let baseline: Double?
    /// Holdings whose history couldn't be loaded (counted at today's price throughout).
    let missingSymbols: [String]
}

// MARK: - Service

@MainActor
final class PriceHistoryService {
    static let shared = PriceHistoryService()

    private let quotes: QuoteService
    private struct Key: Hashable {
        let symbol: String
        let kind: AssetKind
        let exchange: String
        let range: TimeRange
    }
    private var cache: [Key: (points: [PricePoint], fetchedAt: Date)] = [:]
    private var inFlight: [Key: Task<[PricePoint], Error>] = [:]

    init(quotes: QuoteService? = nil) {
        self.quotes = quotes ?? QuoteService()
    }

    enum HistoryError: LocalizedError {
        case noData
        var errorDescription: String? { "No price history is available right now." }
    }

    private func ttl(for range: TimeRange) -> TimeInterval {
        switch range {
        case .oneDay:                return 60
        case .oneWeek:               return 5 * 60
        case .oneMonth, .threeMonths: return 30 * 60
        default:                     return 2 * 3600
        }
    }

    /// Shaped, cached history for one asset. Throws when no source has data.
    func history(for asset: Asset, range: TimeRange, forceRefresh: Bool = false) async throws -> [PricePoint] {
        let key = Key(symbol: asset.symbol.uppercased(), kind: asset.kind, exchange: asset.exchange, range: range)
        if !forceRefresh, let hit = cache[key], Date().timeIntervalSince(hit.fetchedAt) < ttl(for: range) {
            return hit.points
        }
        if let running = inFlight[key] { return try await running.value }

        let task = Task { [quotes] () throws -> [PricePoint] in
            let raw = try await quotes.fetchPriceHistoryOrThrow(for: asset, range: range)
            let shaped = ChartShaper.shape(raw, for: asset, range: range)
            // Right after the open a session has a single bar; callers append the
            // live price (see `appendingLive`), so one real point is enough for 1D.
            guard shaped.count >= (range == .oneDay ? 1 : 2) else { throw HistoryError.noData }
            return shaped
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let points = try await task.value
            cache[key] = (points, Date())
            #if DEBUG
            if let f = points.first, let l = points.last {
                AppLogger.api.notice("HISTPROBE \(asset.symbol) ex=\(asset.exchange) \(range.rawValue) n=\(points.count) first=\(Int(f.date.timeIntervalSince1970)):\(f.price) last=\(Int(l.date.timeIntervalSince1970)):\(l.price)")
            }
            #endif
            return points
        } catch {
            // A stale series beats an empty chart — but only one we really fetched.
            if let stale = cache[key] { return stale.points }
            throw error
        }
    }

    /// Value of the current holdings over `range`, rebuilt from real price history.
    /// - Parameters:
    ///   - liveValue: today's total (Σ shares × current price) — the series ends here.
    ///   - previousCloseValue: Σ shares × previous close — the 1D baseline.
    func portfolioSeries(
        holdings: [PortfolioHolding],
        range: TimeRange,
        liveValue: Double,
        previousCloseValue: Double,
        forceRefresh: Bool = false
    ) async throws -> PortfolioSeries {
        guard !holdings.isEmpty else { throw HistoryError.noData }

        // Fetch every holding's history concurrently (deduped + cached above).
        var histories: [UUID: [PricePoint]] = [:]
        await withTaskGroup(of: (UUID, [PricePoint]?).self) { group in
            for holding in holdings {
                group.addTask { @MainActor in
                    let points = try? await self.history(for: holding.asset, range: range, forceRefresh: forceRefresh)
                    return (holding.id, points)
                }
            }
            for await (id, points) in group {
                if let points { histories[id] = points }
            }
        }
        guard !histories.isEmpty else { throw HistoryError.noData }

        let missing = holdings.filter { histories[$0.id] == nil }.map(\.asset.symbol)

        // One time grid across all holdings (they trade at different hours/days).
        var gridSet = Set<TimeInterval>()
        for points in histories.values {
            for p in points { gridSet.insert((p.date.timeIntervalSince1970 / 60).rounded() * 60) }
        }
        var grid = gridSet.sorted().map { Date(timeIntervalSince1970: $0) }
        if grid.count > 360 {
            grid = ChartShaper.downsample(grid.map { PricePoint(date: $0, price: 1) }, to: 360).map(\.date)
        }

        // Price of a holding at time t: last real price at or before t. Before its
        // first point: previous close on 1D (so the day starts where it closed),
        // otherwise its first available price. No history at all: today's price,
        // flat for the whole range (reported in `missingSymbols`) — never a jump
        // from yesterday's close at the last point, which would draw a fake cliff.
        func price(of holding: PortfolioHolding, at t: Date) -> Double {
            let prevClose = holding.asset.price - holding.asset.change
            guard let points = histories[holding.id], let first = points.first else {
                return holding.asset.price
            }
            if t < first.date {
                return range == .oneDay && prevClose > 0 ? prevClose : first.price
            }
            var lo = 0, hi = points.count - 1
            while lo < hi {               // last index with date <= t
                let mid = (lo + hi + 1) / 2
                if points[mid].date <= t { lo = mid } else { hi = mid - 1 }
            }
            return points[lo].price
        }

        let raw = grid.map { t in
            PricePoint(date: t, price: holdings.reduce(0) { $0 + $1.shares * price(of: $1, at: t) })
        }
        // Where nothing traded for a while (between the ASX close and the US open,
        // overnight), hold the value flat and step at the next real point, instead
        // of drawing a diagonal that implies trading that never happened.
        // (1D only — daily series are sampled closes, where a line between them is the convention.)
        let bar = Double(ChartShaper.typicalBarMinutes(raw)) * 60
        let holdsGaps = range == .oneDay
        var series: [PricePoint] = []
        for p in raw {
            if holdsGaps, let prev = series.last, p.date.timeIntervalSince(prev.date) > max(bar * 3, 45 * 60) {
                series.append(PricePoint(date: p.date.addingTimeInterval(-1), price: prev.price))
            }
            series.append(p)
        }
        // End on the live value so the chart and the header always agree. While a market
        // the holdings trade on is in session, the line runs on to now (held flat if the
        // last bar is a while old). Once they're all closed it ends at the last trade, like
        // the stock page: running a flat line to now squeezed Friday's session into the left
        // sixth of the 1D chart all weekend. A market counts as trading only if now is in its
        // hours AND its latest bar is from today (session hours alone ignore weekends).
        let now = Date()
        let aMarketIsTrading = holdings.contains { holding in
            guard let hours = TradingHours.forAsset(holding.asset) else { return true }   // crypto: 24/7
            guard let lastBar = histories[holding.id]?.last else { return false }
            return hours.session(containing: now).contains(now) && hours.sameSessionDay(lastBar.date, now)
        }
        if let last = series.last, now > last.date, range != .oneDay || aMarketIsTrading {
            if holdsGaps, now.timeIntervalSince(last.date) > max(bar * 3, 45 * 60) {
                series.append(PricePoint(date: now.addingTimeInterval(-1), price: last.price))
            }
            series.append(PricePoint(date: now, price: liveValue))
        } else if !series.isEmpty {
            series[series.count - 1] = PricePoint(date: series[series.count - 1].date, price: liveValue)
        }
        guard series.count >= 2 else { throw HistoryError.noData }

        return PortfolioSeries(
            points: series,
            baseline: range == .oneDay && previousCloseValue > 0 ? previousCloseValue : nil,
            missingSymbols: missing
        )
    }

    func invalidate() {
        cache.removeAll()
    }

    /// Real OHLC candles for an asset, routed by listing (ASX → Yahoo, US → Alpaca,
    /// split-adjusted) and shaped like the line chart (1D = latest regular session,
    /// 1W = regular hours). Throws when there are none — never synthesised.
    func candles(for asset: Asset, range: TimeRange) async throws -> [Candle] {
        guard asset.kind == .stock else { throw HistoryError.noData }
        let raw = try await quotes.fetchHistoricalData(for: asset, range: range)
        let sorted = raw.filter { $0.close > 0 }.sorted { $0.date < $1.date }
        guard let hours = TradingHours.forAsset(asset), range == .oneDay || range == .oneWeek else {
            guard sorted.count >= 2 else { throw HistoryError.noData }
            return sorted
        }
        let bar = ChartShaper.typicalBarMinutes(sorted.map { PricePoint(date: $0.date, price: $0.close) })
        var shaped = sorted.filter { hours.overlapsSession($0.date, barMinutes: bar) }
        if range == .oneDay, let last = shaped.last {
            shaped = shaped.filter { hours.sameSessionDay($0.date, last.date) }
        }
        guard !shaped.isEmpty else { throw HistoryError.noData }
        return shaped
    }

    /// Row sparkline data: the latest session plus the live price, with the
    /// baseline the row's % pill uses (`price − change`), so the line's colour
    /// and the pill can never disagree. nil when no real history is available.
    func miniSeries(for asset: Asset) async -> MiniSeries? {
        guard let points = try? await history(for: asset, range: .oneDay), !points.isEmpty else { return nil }
        let live = Self.appendingLive(points, price: asset.price)
        guard live.count >= 2 else { return nil }
        let prevClose = asset.price - asset.change
        return MiniSeries(
            values: ChartShaper.downsample(live, to: 60).map(\.price),
            baseline: prevClose > 0 ? prevClose : live[0].price,
            sessionDate: points.last?.date
        )
    }

    /// Ends a series on the live price so a chart agrees with the quote above it.
    static func appendingLive(_ points: [PricePoint], price: Double, at now: Date = Date()) -> [PricePoint] {
        guard price > 0, let last = points.last else { return points }
        var out = points
        if now > last.date {
            out.append(PricePoint(date: now, price: price))
        } else {
            out[out.count - 1] = PricePoint(date: last.date, price: price)
        }
        return out
    }
}

// MARK: - Benchmarks

enum Benchmark: String, CaseIterable, Identifiable {
    case sp500, asx200
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sp500:  return "S&P 500"
        case .asx200: return "ASX 200"
        }
    }

    /// Tradable proxy whose price history we can fetch (indices themselves aren't served).
    var asset: Asset {
        switch self {
        case .sp500:
            return Asset(symbol: "SPY", name: "S&P 500 (SPY)", price: 0, change: 0, changePercent: 0,
                         volume: 0, kind: .stock, exchange: "NYSE")
        case .asx200:
            return Asset(symbol: "STW", name: "ASX 200 (STW)", price: 0, change: 0, changePercent: 0,
                         volume: 0, kind: .stock, exchange: "ASX")
        }
    }

    /// Default for the person's home market.
    static var preferred: Benchmark {
        UserDefaults.standard.string(forKey: "preferredMarket") == "AU" ? .asx200 : .sp500
    }
}
