import Foundation
import XCTest
@testable import TradingCore

/// Deterministic test data. Everything here is labelled as a fixture, so production code
/// refuses it unless a test switches `allowFixtureData` on.
enum Fx {
    /// Tuesday 10 November 2026, 10:00 in New York (US market open, ASX closed).
    static let now = date("2026-11-10T15:00:00Z")

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { fatalError("bad date \(iso)") }
        return date
    }

    static let aapl = Instrument.usStock("AAPL", name: "Apple")
    static let msft = Instrument.usStock("MSFT", name: "Microsoft")
    static let spy = Instrument.usETF("SPY", name: "S&P 500 ETF")
    static let btc = Instrument.crypto("BTC", name: "Bitcoin")
    static let bhp = Instrument.asxStock("BHP", name: "BHP Group")

    /// Midnight New York time on the US trading days before `end`, oldest first.
    static func usTradingDays(count: Int, before end: Date = now) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        var days: [Date] = []
        var day = cal.startOfDay(for: end)
        while days.count < count {
            day = cal.date(byAdding: .day, value: -1, to: day)!
            if MarketCalendar.standard.isTradingDay(.us, day) { days.append(day) }
        }
        return days.reversed()
    }

    /// Daily bars from a list of closes. Each bar opens at the previous close.
    static func dailyBars(closes: [Double], days: [Date]? = nil, volume: Double = 5_000_000) -> [Bar] {
        let times = days ?? usTradingDays(count: closes.count)
        precondition(times.count == closes.count)
        return closes.enumerated().map { i, close in
            let open = i == 0 ? close : closes[i - 1]
            return Bar(time: times[i], open: open, high: max(open, close) * 1.005, low: min(open, close) * 0.995,
                       close: close, volume: volume)
        }
    }

    /// Daily crypto bars stamped at midnight UTC on consecutive days before `end`.
    static func cryptoDays(count: Int, before end: Date = now) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: end)
        return (1...count).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
    }

    static func series(_ instrument: Instrument, closes: [Double], days: [Date]? = nil,
                       provenance: DataProvenance = .fixture("test"), volume: Double = 5_000_000) -> BarSeries {
        let times = days ?? (instrument.venue == .crypto ? cryptoDays(count: closes.count) : usTradingDays(count: closes.count))
        return BarSeries(instrument: instrument, timeframe: .day, bars: dailyBars(closes: closes, days: times, volume: volume),
                         provenance: provenance, fetchedAt: now)
    }

    static func quote(_ instrument: Instrument, last: Double, spreadBps: Double? = 2, time: Date = now,
                      provenance: DataProvenance = .fixture("test"), dayVolume: Double? = nil) -> Quote {
        var bid: Double?
        var ask: Double?
        if let spreadBps {
            bid = Rounding.round(last * (1 - spreadBps / 20_000), places: 4)
            ask = Rounding.round(last * (1 + spreadBps / 20_000), places: 4)
        }
        return Quote(instrumentID: instrument.id, last: last, bid: bid, ask: ask, time: time,
                     provenance: provenance, dayVolume: dayVolume)
    }

    static func engine() -> TradingEngine {
        var engine = TradingEngine()
        engine.state.accountPolicy.allowFixtureData = true
        return engine
    }

    /// A flat series that then climbs: the 5-bar average crosses above the 20-bar one near the end.
    static func risingCloses(count: Int = 60, base: Double = 100, climbFrom: Int = 45, step: Double = 1.5) -> [Double] {
        (0..<count).map { i in i < climbFrom ? base : base + Double(i - climbFrom + 1) * step }
    }

    /// A simple "close above the 20-day average" strategy for one instrument.
    static func aboveAverageSpec(_ universe: [Instrument], stopLossPct: Double? = 8) -> StrategySpec {
        StrategySpec(kind: .rules, title: "Above average", summary: "Test strategy", universe: universe,
                     entry: .above(.close, .sma(20)), exit: .below(.close, .sma(20)),
                     protections: Protections(stopLossPct: stopLossPct),
                     sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 0)
    }

    static func snapshot(_ items: [(Instrument, [Double], Double)], now: Date = now) -> MarketSnapshot {
        var snapshot = MarketSnapshot()
        for (instrument, closes, last) in items {
            snapshot.series[instrument.id] = series(instrument, closes: closes)
            snapshot.quotes[instrument.id] = quote(instrument, last: last, time: now)
        }
        return snapshot
    }
}

extension RiskReport {
    func status(_ id: RiskCheckID) -> RiskCheckStatus? { check(id)?.status }
}

func XCTAssertClose(_ a: Double, _ b: Double, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
}
