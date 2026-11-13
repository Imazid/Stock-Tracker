import XCTest
@testable import TradingCore

// Shared test vectors for the phone (this package) and the server
// (supabase/functions/_shared/trading, TypeScript).
//
// Each test builds a set of cases from the Swift implementation and compares them with
// the JSON committed under Tests/Vectors. The server's Deno test loads the same files and
// must reproduce every case, which is how the two engines are kept in step.
//
// The committed files can't go stale silently: if this implementation changes, these
// tests fail until the vectors are regenerated with
//
//     UPDATE_VECTORS=1 swift test --filter ParityVectorTests
//
// and the server port is brought back into line.
//
// Format notes: dates are milliseconds since 1970 (as `TradingCodec` writes them), keys
// are sorted, absent optionals are left out, and nothing random reaches the output
// (fixed UUIDs here; engine scenarios replace generated UUIDs with labels).

// MARK: - Plumbing

private func J<T: Encodable>(_ value: T) -> Any {
    // Wrapped in an array so plain numbers and strings encode on every Foundation version.
    let data = try! TradingCodec.encoder().encode([value])
    return (try! JSONSerialization.jsonObject(with: data) as! [Any])[0]
}

private func ms(_ date: Date) -> Any { J(date) }

private func U(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

private enum Vectors {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vectors", isDirectory: true)

    static var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_VECTORS"] == "1" }

    static func line(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value,
                                               options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// One case per line, so a changed case shows up as one changed line in a diff.
    static func render(_ root: [String: Any]) -> Data {
        var out = "{\n"
        let keys = root.keys.sorted()
        for (i, key) in keys.enumerated() {
            out += "  \(line(key)): "
            if let array = root[key] as? [Any], !array.isEmpty {
                out += "[\n" + array.map { "    " + line($0) }.joined(separator: ",\n") + "\n  ]"
            } else {
                out += line(root[key]!)
            }
            out += i == keys.count - 1 ? "\n" : ",\n"
        }
        out += "}\n"
        return Data(out.utf8)
    }

    static func firstDifference(_ a: Any, _ b: Any, path: String = "$") -> String? {
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            for key in Set(x.keys).union(y.keys).sorted() {
                guard let l = x[key] else { return "\(path).\(key) is new" }
                guard let r = y[key] else { return "\(path).\(key) is gone" }
                if let found = firstDifference(l, r, path: "\(path).\(key)") { return found }
            }
            return nil
        }
        if let x = a as? [Any], let y = b as? [Any] {
            if x.count != y.count { return "\(path) has \(y.count) items, the file has \(x.count)" }
            for i in x.indices {
                if let found = firstDifference(x[i], y[i], path: "\(path)[\(i)]") { return found }
            }
            return nil
        }
        return (a as AnyObject).isEqual(b) ? nil : "\(path): file \(line(a)) vs now \(line(b))"
    }

    static func check(_ name: String, _ root: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let url = directory.appendingPathComponent("\(name).json")
        let data = render(root)
        if updating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        guard let existing = try? Data(contentsOf: url) else {
            XCTFail("\(name).json is missing. Run: UPDATE_VECTORS=1 swift test --filter ParityVectorTests", file: file, line: line)
            return
        }
        let committed = try JSONSerialization.jsonObject(with: existing)
        let current = try JSONSerialization.jsonObject(with: data)
        if let difference = firstDifference(committed, current) {
            XCTFail("\(name).json no longer matches the implementation (\(difference)). If the change is intended, run UPDATE_VECTORS=1 swift test --filter ParityVectorTests and update the server port to match.",
                    file: file, line: line)
        }
    }
}

/// A small repeatable generator (the same one the indicator tests use).
private struct LCG {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31)
    }
}

private enum Series {
    /// A wandering price series with real highs, lows and changing volume.
    static func walk(count: Int, seed: UInt64 = 7, start: Double = 100, days: [Date]? = nil) -> [Bar] {
        var rng = LCG(seed: seed)
        let times = days ?? Fx.usTradingDays(count: count)
        var bars: [Bar] = []
        var previous = start
        for i in 0..<count {
            let open = previous
            let close = max(open * (1 + (rng.next() - 0.5) * 0.06), 1)
            let high = max(open, close) * (1 + rng.next() * 0.01)
            let low = min(open, close) * (1 - rng.next() * 0.01)
            let volume = (1_000_000 + rng.next() * 4_000_000).rounded()
            bars.append(Bar(time: times[i], open: open, high: high, low: low, close: close, volume: volume))
            previous = close
        }
        return bars
    }
}

// MARK: - Tests

final class ParityVectorTests: XCTestCase {

    // MARK: Rounding

    func testRoundingVectors() throws {
        let xs: [Double] = [0, 1, -1, 0.5, -0.5, 1.5, 2.5, -2.5, 1.005, 2.675, -2.675, 0.125, 0.135, 10, 99.995,
                            100.004999, 123_456.789, 0.1 + 0.2, 1e-7, 4.35, 4.45, 1.000_000_000_1, 0.3, 7.9,
                            1.234_567_89, 0.123_456_789, 64_000.02, 1_234_567.891, 0.000_000_015, 0.000_000_01,
                            9.999, 250, 0.012_345_678_9, 1e15, 0.049_999_999_999_999_996, 0.499_999_999_999_999_94,
                            -0.001, -0.004, 101.25, 101.255, 44.995, 45.005, 0.07, 0.035, 2.5e-9, 33.333_333_333_333_336]
        let places = [0, 1, 2, 4, 6, 8, 9]
        let increments: [Double] = [1, 0.5, 0.25, 0.1, 0.01, 0.005, 0.001, 0.000_001, 0.000_000_01, 5, 0.05, 2]
        var round: [Any] = [], money: [Any] = [], decimals: [Any] = [], floor: [Any] = []
        var nearest: [Any] = [], isMultiple: [Any] = [], string: [Any] = []
        for x in xs {
            money.append([x, Rounding.money(x)])
            for p in places { round.append([x, p, Rounding.round(x, places: p)] as [Any]) }
            for increment in increments {
                floor.append([x, increment, Rounding.floor(x, increment: increment)])
                nearest.append([x, increment, Rounding.nearest(x, increment: increment)])
                isMultiple.append([x, increment, Rounding.isMultiple(x, of: increment)] as [Any])
                string.append([x, increment, Rounding.string(x, increment: increment)] as [Any])
            }
        }
        for increment in increments + [0.3, 0.125, 0.007, 1e-10, 1e-12, 0, -1, 10, 0.999_999_999_9, 0.000_25] {
            decimals.append([increment, Rounding.decimals(for: increment)] as [Any])
        }
        try Vectors.check("rounding", ["round": round, "money": money, "decimals": decimals, "floor": floor,
                                       "nearest": nearest, "isMultiple": isMultiple, "string": string])
    }

    // MARK: Text

    /// The number-to-text rules behind every evidence line, risk detail and audit detail.
    func testTextVectors() throws {
        let description: [Double] = [0, -0.0, 1, -1, 0.5, 5_000, 64_000, 100.01, 0.1, 0.1 + 0.2, 1.0 / 3, 4.081_299,
                                     0.012_345_67, 0.001, 0.000_1, 0.000_12, 0.000_01, 0.000_012_5, 1e-7, 5e-324,
                                     123_456_789.123, 1e15, 1e16, 9_007_199_254_740_992, 9_007_199_254_740_994,
                                     1.234_567_890_123_456_7e17, 1e21, 1e22, 1.5e300, 1.797_693_134_862_315_7e308,
                                     -12.5, 499.999_999, 2_500, 0.25, 1e-4, 9.999_999_999_999_999e-5, 1_000_000,
                                     123_456_789_012_345_680, 0.000_099_9, 250.000_000_000_000_03]
        let xs: [Double] = [0, -0.0, 1, -1, 0.5, 1.5, 2.5, 3.5, 0.05, 0.15, 0.25, 0.35, 0.125, 0.375, 0.005, 0.015,
                            0.045, 1.005, 2.675, 99.95, 99.995, 100, 100.004, 999.999, 1_000, 1_234.567_8, 5_000,
                            64_000, 64_012.8, 0.999_9, 0.999_95, 0.000_12, 0.000_1, 0.000_05, 0.000_01, 1e-7,
                            123_456.789, 999_999.5, 1_000_000, 1_500_000.4, 2_500_000.5, 1e9, 2.5e9, 1e12,
                            0.1 + 0.2, 1.0 / 3, 4.081_299, 0.012_345_67, 12.5, -12.5, -0.04, -0.05, -0.06, -99.95,
                            37.5, 8, 10, 0.45, 0.55, 14.999, 15.000_1, 999.5, 1_499.5, 999_499, 999_500,
                            999_999_999, 1_250_000_000, 49.95, 0.949_999, 0.95, -1_234.567]
        let durations: [Double] = [0, 0.4, 0.5, 1, 45.5, 59.5, 89, 89.4, 89.5, 90, 90.4, 149, 150, 151, 300, 900,
                                   1_200, 3_600, 5_399, 5_399.5, 5_400, 9_000, 12_600, 172_799, 172_800, 216_000,
                                   1_000_000, 240, 239.6]
        var quantityText: [Any] = []
        for instrument in [Fx.aapl, Fx.btc, Fx.bhp] {
            let rules = PaperBroker.rules(for: instrument)
            for x in [0, 1, 2.5, 10, 250, 0.5, 0.012_345_67, 0.000_000_01, 4.081_299, 9.999, 100.000_000_4, 1_000_000, 0.1 + 0.2] as [Double] {
                quantityText.append([x, J(rules), RiskEngine.quantityText(x, rules)] as [Any])
            }
        }
        var money: [Any] = []
        var compactMoney: [Any] = []
        let codes = Currencies.supported + ["XYZ"]
        for currency in codes {
            for x in xs + [1e12, 2.55e12, -3.2e9] {
                money.append([x, currency, NumberText.money(x, currency: currency)] as [Any])
                compactMoney.append([x, currency, NumberText.compactMoney(x, currency: currency)] as [Any])
            }
        }
        let currencies: [Any] = codes.map { code in
            ["code": code, "supported": Currencies.isSupported(code), "symbol": Currencies.symbol(code),
             "decimals": Currencies.decimals(code), "timeZone": Currencies.timeZone(code).identifier,
             "roughUnitsPerUSD": Currencies.roughUnitsPerUSD(code),
             "budgetRange": [Currencies.budgetRange(code).lowerBound, Currencies.budgetRange(code).upperBound],
             "defaultBudget": Currencies.defaultBudget(code), "balanceChoices": Currencies.balanceChoices(code),
             "liquidityFloor": Currencies.liquidityFloor(code)] as [String: Any]
        }
        try Vectors.check("text", [
            "currencies": currencies,
            "supportedCurrencies": Currencies.supported,
            "compactMoney": compactMoney,
            "doubleDescription": description.map { [$0, String($0)] as [Any] },
            "price": xs.map { [$0, NumberText.price($0)] as [Any] },
            "number": xs.map { [$0, NumberText.number($0)] as [Any] },
            "signedPercent": xs.map { [$0, NumberText.signedPercent($0)] as [Any] },
            "money": money,
            "trim": xs.map { [$0, Operand.trim($0)] as [Any] },
            "percentText": xs.map { [$0, RiskEngine.percentText($0)] as [Any] },
            "compactText": xs.map { [$0, RiskEngine.compactText($0)] as [Any] },
            "durationText": durations.map { [$0, RiskEngine.durationText($0)] as [Any] },
            "quantityText": quantityText,
            "capitalized": ["buy", "sell", "hold", "open", "high", "low", "close"].map { [$0, $0.capitalized] }
        ])
    }

    // MARK: Market calendar

    func testCalendarVectors() throws {
        let calendar = MarketCalendar.standard
        // Every venue: a sweep across two years, and the edges of each region's day.
        var everywhere: [Date] = []
        var t = Fx.date("2025-12-28T00:00:00Z")
        let end = Fx.date("2028-01-05T00:00:00Z")
        let strideDays: TimeInterval = 9 * 86_400
        let strideHours: TimeInterval = 7 * 3_600
        let strideMinutes: TimeInterval = 13 * 60
        while t < end {
            everywhere.append(t)
            t = t.addingTimeInterval(strideDays + strideHours + strideMinutes)
        }
        everywhere += [
            // Tuesday 10 November 2026 hour by hour (opens, lunches and closes from Tokyo to New York).
            "2026-11-09T23:59:59Z", "2026-11-10T00:00:00Z", "2026-11-10T00:30:00Z", "2026-11-10T01:00:00Z", "2026-11-10T01:29:59Z",
            "2026-11-10T01:30:00Z", "2026-11-10T02:29:59Z", "2026-11-10T02:30:00Z", "2026-11-10T03:00:00Z", "2026-11-10T03:29:59Z",
            "2026-11-10T03:30:00Z", "2026-11-10T03:44:59Z", "2026-11-10T03:45:00Z", "2026-11-10T03:59:59Z", "2026-11-10T04:00:00Z",
            "2026-11-10T04:30:00Z", "2026-11-10T05:00:00Z", "2026-11-10T05:30:00Z", "2026-11-10T06:29:59Z", "2026-11-10T06:30:00Z",
            "2026-11-10T06:40:00Z", "2026-11-10T07:59:00Z", "2026-11-10T08:00:00Z", "2026-11-10T08:01:00Z", "2026-11-10T08:09:59Z",
            "2026-11-10T08:10:00Z", "2026-11-10T09:05:59Z", "2026-11-10T09:06:00Z", "2026-11-10T09:59:59Z", "2026-11-10T10:00:00Z",
            "2026-11-10T11:00:00Z", "2026-11-10T16:29:59Z", "2026-11-10T16:30:00Z", "2026-11-10T16:34:59Z", "2026-11-10T16:35:00Z",
            "2026-11-10T16:40:00Z", "2026-11-10T15:00:00Z", "2026-11-10T21:00:00Z",
            // A weekend, and a summer day (London and the continent on summer time).
            "2026-11-14T10:00:00Z", "2026-11-15T23:30:00Z", "2026-07-14T07:01:00Z", "2026-07-14T06:59:00Z", "2026-07-14T15:35:00Z",
            "2026-07-14T15:34:59Z", "2026-07-14T02:30:00Z",
            // European clocks change: 29 March and 25 October 2026.
            "2026-03-27T16:00:00Z", "2026-03-29T00:59:59Z", "2026-03-29T01:00:00Z", "2026-03-30T06:59:59Z", "2026-03-30T07:00:00Z",
            "2026-03-30T08:00:00Z", "2026-10-23T15:35:00Z", "2026-10-25T00:59:59Z", "2026-10-25T01:00:00Z", "2026-10-26T07:59:59Z",
            "2026-10-26T08:00:00Z", "2026-10-26T09:00:00Z",
            // New Year, when the venues without holiday tables simply follow the week.
            "2025-12-31T23:00:00Z", "2026-01-01T02:00:00Z", "2026-01-01T09:00:00Z", "2027-12-31T15:00:00Z", "2028-01-03T02:00:00Z"
        ].map(Fx.date)
        // The US and ASX in detail (their holiday tables, half days and clock changes).
        var instants: [Date] = []
        instants += [
            // US session edges, a weekend, summer time.
            "2026-11-10T15:00:00Z", "2026-11-10T14:29:00Z", "2026-11-10T14:29:59Z", "2026-11-10T14:30:00Z",
            "2026-11-10T20:59:59Z", "2026-11-10T21:00:00Z", "2026-11-14T16:00:00Z", "2026-11-15T23:00:00Z",
            "2026-07-14T13:31:00Z", "2026-07-14T13:29:00Z", "2026-07-14T13:30:00Z", "2026-07-14T19:59:59Z", "2026-07-14T20:00:00Z",
            // US holidays and half days.
            "2026-11-26T16:00:00Z", "2026-11-27T14:30:00Z", "2026-11-27T17:30:00Z", "2026-11-27T17:59:59Z",
            "2026-11-27T18:00:00Z", "2026-11-27T18:30:00Z", "2026-11-25T22:00:00Z", "2026-11-13T22:00:00Z",
            "2026-12-24T17:59:00Z", "2026-12-24T18:00:00Z", "2026-12-25T15:00:00Z", "2026-07-03T15:00:00Z",
            "2026-06-19T15:00:00Z", "2027-11-25T16:00:00Z", "2027-11-26T17:59:00Z", "2027-11-26T18:00:00Z",
            "2027-12-24T16:00:00Z", "2027-07-05T15:00:00Z", "2027-07-02T15:00:00Z",
            // US clocks change: 8 March and 1 November 2026.
            "2026-03-06T20:59:00Z", "2026-03-06T21:00:00Z", "2026-03-08T06:59:59Z", "2026-03-08T07:00:00Z",
            "2026-03-08T07:30:00Z", "2026-03-09T03:59:59Z", "2026-03-09T04:00:00Z", "2026-03-09T13:29:59Z",
            "2026-03-09T13:30:00Z", "2026-03-09T14:30:00Z", "2026-10-30T13:30:00Z", "2026-11-01T03:59:59Z",
            "2026-11-01T04:00:00Z", "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-11-02T04:59:59Z",
            "2026-11-02T05:00:00Z", "2026-11-02T14:29:59Z", "2026-11-02T14:30:00Z",
            // ASX sessions, holidays, half days.
            "2026-11-10T00:30:00Z", "2026-11-09T22:59:59Z", "2026-11-09T23:00:00Z", "2026-11-10T04:59:59Z",
            "2026-11-10T05:00:00Z", "2026-11-10T06:00:00Z", "2026-01-26T01:00:00Z", "2026-06-08T01:00:00Z",
            "2026-12-24T02:00:00Z", "2026-12-24T03:09:59Z", "2026-12-24T03:10:00Z", "2026-12-24T04:00:00Z",
            "2026-12-25T01:00:00Z", "2026-12-28T01:00:00Z", "2026-12-31T03:09:59Z", "2026-12-31T03:10:00Z",
            "2027-12-27T01:00:00Z", "2027-12-31T03:10:00Z",
            // Sydney clocks change: 5 April and 4 October 2026.
            "2026-04-02T23:00:00Z", "2026-04-04T12:59:59Z", "2026-04-04T13:00:00Z", "2026-04-04T15:59:59Z",
            "2026-04-04T16:00:00Z", "2026-04-05T13:59:59Z", "2026-04-05T14:00:00Z", "2026-04-06T23:59:59Z",
            "2026-04-07T00:00:00Z", "2026-04-07T05:59:59Z", "2026-04-07T06:00:00Z", "2026-10-02T06:00:00Z",
            "2026-10-03T13:59:59Z", "2026-10-03T14:00:00Z", "2026-10-03T15:59:59Z", "2026-10-03T16:00:00Z",
            "2026-10-04T12:59:59Z", "2026-10-04T13:00:00Z", "2026-10-04T22:59:59Z", "2026-10-04T23:00:00Z",
            "2026-10-05T05:00:00Z",
            // The edges of the holiday tables.
            "2025-12-31T12:59:59Z", "2025-12-31T13:00:00Z", "2025-12-31T23:59:59Z", "2026-01-01T00:00:00Z",
            "2026-01-01T04:59:59Z", "2026-01-01T05:00:00Z", "2026-01-02T15:00:00Z", "2027-12-31T12:59:59Z",
            "2027-12-31T13:00:00Z", "2027-12-31T20:00:00Z", "2028-01-01T04:59:59Z", "2028-01-01T05:00:00Z",
            "2028-01-03T15:00:00Z", "2028-01-03T01:00:00Z"
        ].map(Fx.date)

        var cases: [Any] = []
        for venue in Venue.allCases {
            let detailed = venue == .us || venue == .asx || venue == .crypto
            for instant in everywhere + (detailed ? instants : []) {
                let session = calendar.session(venue, containing: instant)
                cases.append([
                    "venue": venue.rawValue, "t": ms(instant),
                    "dayKey": calendar.dayKey(venue, instant),
                    "coversDate": calendar.coversDate(venue, instant),
                    "isTradingDay": calendar.isTradingDay(venue, instant),
                    "segments": calendar.segments(venue, on: instant).map { [ms($0.start), ms($0.end)] },
                    "sessionStart": session.map { ms($0.start) } ?? NSNull(),
                    "sessionEnd": session.map { ms($0.end) } ?? NSNull(),
                    "isOpen": calendar.isOpen(venue, at: instant),
                    "nextOpen": calendar.nextOpen(venue, after: instant).map(ms) ?? NSNull(),
                    "nextClose": calendar.nextClose(venue, after: instant).map(ms) ?? NSNull()
                ] as [String: Any])
            }
        }
        let venues: [Any] = Venue.allCases.map { venue in
            var facts: [String: Any] = ["venue": venue.rawValue, "timeZone": calendar.timeZone(venue).identifier,
                                        "hasLunchBreak": calendar.hasLunchBreak(venue)]
            if let regular = calendar.regularHours(venue) {
                facts["regularHours"] = ["timeZone": regular.timeZone.identifier, "open": regular.open, "close": regular.close] as [String: Any]
            }
            if let covered = calendar.coveredYears(for: venue) { facts["coveredYears"] = [covered.lowerBound, covered.upperBound] }
            return facts
        }

        var barComplete: [Any] = []
        let barTimes = ["2026-11-10T05:00:00Z", "2026-11-10T14:30:00Z", "2026-11-09T05:00:00Z", "2026-11-07T05:00:00Z",
                        "2026-11-26T05:00:00Z", "2026-11-10T00:00:00Z", "2026-11-09T15:00:00Z", "2026-11-10T08:00:00Z"].map(Fx.date)
        let nows = ["2026-11-10T15:00:00Z", "2026-11-10T20:59:59Z", "2026-11-10T21:00:00Z", "2026-11-11T00:00:00Z",
                    "2026-11-10T03:00:00Z", "2026-11-10T06:29:59Z", "2026-11-10T06:31:00Z", "2026-11-10T16:35:00Z",
                    "2026-11-08T05:00:00Z", "2026-11-27T18:00:00Z", "2026-11-09T21:00:00Z"].map(Fx.date)
        for venue in Venue.allCases {
            for timeframe in Timeframe.allCases {
                for barTime in barTimes {
                    for now in nows {
                        let bar = Bar(time: barTime, open: 1, high: 1, low: 1, close: 1, volume: 1)
                        barComplete.append([venue.rawValue, timeframe.rawValue, ms(barTime), ms(now),
                                            calendar.isBarComplete(bar, timeframe: timeframe, venue: venue, now: now)] as [Any])
                    }
                }
            }
        }

        var tradingDays: [Any] = []
        let spans: [(String, String)] = [
            ("2026-11-09T05:00:00Z", "2026-11-10T15:00:00Z"), ("2026-11-06T05:00:00Z", "2026-11-10T15:00:00Z"),
            ("2026-11-10T15:00:00Z", "2026-11-10T20:00:00Z"), ("2026-11-10T15:00:00Z", "2026-11-09T15:00:00Z"),
            ("2026-10-20T04:00:00Z", "2026-11-10T15:00:00Z"), ("2026-11-20T05:00:00Z", "2026-12-01T15:00:00Z"),
            ("2026-01-02T05:00:00Z", "2027-12-30T15:00:00Z"), ("2025-06-01T04:00:00Z", "2028-01-03T15:00:00Z"),
            ("2026-03-06T05:00:00Z", "2026-03-10T04:00:00Z"), ("2026-10-30T04:00:00Z", "2026-11-03T05:00:00Z"),
            ("2026-04-02T13:00:00Z", "2026-04-08T14:00:00Z"), ("2026-10-01T14:00:00Z", "2026-10-06T13:00:00Z"),
            ("2026-11-10T03:59:59Z", "2026-11-10T04:00:01Z"), ("2026-11-10T04:59:59Z", "2026-11-10T05:00:01Z"),
            ("2026-11-09T12:59:59Z", "2026-11-09T13:00:01Z"), ("2026-11-08T00:00:00Z", "2026-11-10T23:59:59Z"),
            ("2026-11-08T00:00:00Z", "2026-11-11T00:00:00Z"), ("2026-12-23T05:00:00Z", "2027-01-04T15:00:00Z")
        ]
        for venue in Venue.allCases {
            for (from, to) in spans {
                tradingDays.append([venue.rawValue, ms(Fx.date(from)), ms(Fx.date(to)),
                                    calendar.tradingDays(venue, from: Fx.date(from), to: Fx.date(to))] as [Any])
            }
        }

        var completedBars: [Any] = []
        var days = Fx.usTradingDays(count: 3)
        days.append(Fx.date("2026-11-10T05:00:00Z"))
        let us = Fx.series(Fx.aapl, closes: [1, 2, 3, 4], days: days)
        let crypto = Fx.series(Fx.btc, closes: [5, 6, 7], days: ["2026-11-08T00:00:00Z", "2026-11-09T00:00:00Z", "2026-11-10T00:00:00Z"].map(Fx.date))
        for (series, nowText) in [(us, "2026-11-10T15:00:00Z"), (us, "2026-11-10T21:00:00Z"), (us, "2026-11-06T12:00:00Z"),
                                  (crypto, "2026-11-10T15:00:00Z"), (crypto, "2026-11-11T00:00:00Z"), (crypto, "2026-11-08T00:00:00Z")] {
            let now = Fx.date(nowText)
            completedBars.append(["series": J(series), "now": ms(now),
                                  "closes": calendar.completedBars(series, now: now).map(\.close)] as [String: Any])
        }
        // Unsorted and invalid bars are tidied when a series is built.
        let messy = BarSeries(instrument: Fx.aapl, timeframe: .day, bars: [
            Bar(time: days[2], open: 3, high: 3, low: 3, close: 3, volume: 1),
            Bar(time: days[0], open: 1, high: 1, low: 1, close: 1, volume: 1),
            Bar(time: days[1], open: 2, high: 1, low: 2, close: 2, volume: 1),      // high below low
            Bar(time: days[1], open: 2, high: 2, low: 2, close: 0, volume: 1),      // zero close
            Bar(time: days[1], open: 2, high: 2, low: 2, close: 2, volume: -1)      // negative volume
        ], provenance: .fixture("messy"), fetchedAt: Fx.now)

        var ledgerDayKey: [Any] = []
        for currency in Currencies.supported + ["XYZ"] {
            for text in ["2026-11-10T15:00:00Z", "2026-11-10T04:59:59Z", "2026-11-10T05:00:00Z", "2026-11-09T12:59:59Z",
                         "2026-11-09T13:00:00Z", "2026-07-01T03:59:59Z", "2026-07-01T04:00:00Z", "2026-07-01T13:59:59Z",
                         "2026-07-01T14:00:00Z", "2026-03-08T07:00:00Z", "2026-12-31T23:00:00Z"] {
                ledgerDayKey.append([ms(Fx.date(text)), currency, Ledger.dayKey(for: Fx.date(text), currency: currency)] as [Any])
            }
        }

        try Vectors.check("calendar", ["cases": cases, "venues": venues, "barComplete": barComplete, "tradingDays": tradingDays,
                                       "completedBars": completedBars, "ledgerDayKey": ledgerDayKey,
                                       "tidiedSeries": ["times": messy.bars.map { ms($0.time) }, "closes": messy.bars.map(\.close)],
                                       "coveredYears": [MarketCalendar.coveredYears.lowerBound, MarketCalendar.coveredYears.upperBound]])
    }

    // MARK: Markets

    func testMarketVectors() throws {
        let venues: [Any] = Venue.allCases.map { venue in
            var facts: [String: Any] = ["venue": venue.rawValue, "currency": venue.currency, "displayName": venue.displayName,
                                        "shortName": venue.shortName, "country": venue.country, "region": venue.region.rawValue,
                                        "regionName": venue.region.displayName]
            if let suffix = venue.yahooSuffix { facts["yahooSuffix"] = suffix }
            return facts
        }
        let symbols = ["VOD.L", "7203.T", "sap.de", "AAPL", "BHP.AX", "0700.HK", ".L", "MC.PA", "ASML.AS", "NESN.SW", "D05.SI",
                       "005930.KS", "RELIANCE.NS", "BTC", "X.AXL", "BRK.B"]
        let parsed: [Any] = symbols.map { symbol in
            var entry: [String: Any] = ["input": symbol]
            if let hit = Venue.parse(yahooSymbol: symbol) { entry["venue"] = hit.venue.rawValue; entry["symbol"] = hit.symbol }
            return entry
        }
        let listings: [Any] = [Instrument.listed("vod", name: "Vodafone", on: .lse), .listed("7203", on: .tse), .listed("ISF", on: .lse, etf: true),
                               Fx.aapl, Fx.btc, Fx.bhp].map { ["instrument": J($0), "id": $0.id, "yahooSymbol": $0.yahooSymbol] as [String: Any] }

        // Liquidity and volatility from a snapshot: one venue's volume is never read as the market's.
        var stats: [Any] = []
        let closes = Fx.risingCloses().map { $0 * 500 }
        func add(_ name: String, _ snapshot: MarketSnapshot, now: Date = Fx.now) {
            stats.append(["name": name, "series": J(snapshot.series), "dollarVolume": snapshot.dollarVolume, "now": ms(now),
                          "out": J(snapshot.stats(now: now))] as [String: Any])
        }
        var snapshot = MarketSnapshot()
        snapshot.series[Fx.aapl.id] = Fx.series(Fx.aapl, closes: Fx.risingCloses())
        snapshot.series[Fx.btc.id] = BarSeries(instrument: Fx.btc, timeframe: .day,
                                               bars: Fx.dailyBars(closes: closes, days: Fx.cryptoDays(count: closes.count), volume: 0.09),
                                               provenance: .fixture("test"), fetchedAt: Fx.now, volumeIsMarketWide: false)
        add("market-wide stock, venue-only crypto with no figure", snapshot)
        snapshot.dollarVolume[Fx.btc.id] = 25_000_000_000
        snapshot.dollarVolume[Fx.aapl.id] = 1
        add("a market-wide figure for the crypto", snapshot)
        snapshot.dollarVolume[Fx.btc.id] = 0
        add("a zero figure is no figure", snapshot)
        snapshot.series[Fx.msft.id] = BarSeries(instrument: Fx.msft, timeframe: .hour, bars: Fx.dailyBars(closes: Fx.risingCloses()),
                                                provenance: .fixture("test"), fetchedAt: Fx.now)
        snapshot.series[Fx.spy.id] = Fx.series(Fx.spy, closes: [Double](repeating: 400, count: 12))
        add("hourly bars and short histories give nothing", snapshot)
        add("before the last bar has closed", snapshot, now: Fx.date("2026-11-09T20:00:00Z"))

        try Vectors.check("market", ["venues": venues, "yahooSymbols": parsed, "listings": listings, "stats": stats,
                                     "regions": MarketRegion.allCases.map { [$0.rawValue, $0.displayName] }])
    }

    // MARK: Indicators

    private static let indicatorSeries: [(String, [Bar])] = [
        ("walk", Series.walk(count: 130)),
        ("flat", Fx.dailyBars(closes: [Double](repeating: 50, count: 30))),
        ("rising", Fx.dailyBars(closes: (0..<40).map { 100 + Double($0) * 1.25 })),
        ("falling", Fx.dailyBars(closes: (0..<40).map { 200 - Double($0) * 2.5 })),
        ("short", Fx.dailyBars(closes: [10, 11, 10.5, 12, 11.75])),
        ("wave", Fx.dailyBars(closes: (0..<90).map { 100 + sin(Double($0) / 6) * 12 }, volume: 2_500_000))
    ]

    func testIndicatorVectors() throws {
        let operands: [Operand] = [
            .close, .price(.open), .price(.high), .price(.low), Operand(kind: .price), .volume,
            .volumeAverage(10), .volumeAverage(20).scaled(by: 1.2), Operand(kind: .volumeAverage),
            .sma(1), .sma(5), .sma(20), .sma(50), .sma(20).scaled(by: 0.97), Operand(kind: .sma), .sma(500),
            .ema(5), .ema(12), .ema(21), .ema(55), Operand(kind: .ema),
            .rsi(2), .rsi(14), Operand(kind: .rsi),
            .macdLine(), .macdSignal(), .macdHistogram(), Operand(kind: .macdLine), Operand(kind: .macdSignal),
            .macdLine(fast: 5, slow: 13, signal: 4), .macdSignal(fast: 5, slow: 13, signal: 4),
            .macdHistogram(fast: 5, slow: 13, signal: 4), .macdLine(fast: 26, slow: 12, signal: 9),
            .bollingerUpper(), .bollingerMiddle(), .bollingerLower(), Operand(kind: .bollingerUpper),
            .bollingerUpper(10, deviations: 1.5), .bollingerLower(10, deviations: 2.5), .bollingerMiddle(10),
            .atr(), .atr(5), Operand(kind: .atr),
            .highest(20), .highest(10), Operand(kind: .highest), .lowest(10), .lowest(20), Operand(kind: .lowest),
            .rateOfChange(1), .rateOfChange(20), Operand(kind: .rateOfChange),
            .constant(42.5), .constant(30).scaled(by: 2), Operand(kind: .constant)
        ]
        XCTAssertEqual(Set(operands.map(\.kind)), Set(OperandKind.allCases), "every operand kind needs a vector")

        var values: [Any] = []
        var series: [String: Any] = [:]
        for (name, bars) in Self.indicatorSeries {
            series[name] = J(bars)
            let prepared = PreparedSeries(bars: bars)
            for operand in operands {
                let out: [Any] = bars.indices.map { prepared.value(operand, at: $0).map { $0 as Any } ?? NSNull() }
                values.append(["series": name, "operand": J(operand), "warmup": operand.warmup, "values": out] as [String: Any])
            }
        }

        var stats: [Any] = []
        let walk = Self.indicatorSeries[0].1
        for count in [0, 5, 20, 21, 22, 60, 130] {
            for lookback in [5, 20] {
                let measured = InstrumentStats.measure(Array(walk.prefix(count)), lookback: lookback)
                stats.append(["series": "walk", "count": count, "lookback": lookback,
                              "stats": measured.map { J($0) } ?? NSNull()] as [String: Any])
            }
        }
        var indexOf: [Any] = []
        for offset in [-86_400, 0, 1, 36_000, 86_400, 5 * 86_400, 400 * 86_400] as [TimeInterval] {
            for base in [0, 1, 64, 129] {
                let date = walk[base].time.addingTimeInterval(offset)
                indexOf.append(["series": "walk", "t": ms(date),
                                "index": PreparedSeries(bars: walk).index(containing: date).map { $0 as Any } ?? NSNull()] as [String: Any])
            }
        }
        try Vectors.check("indicators", ["series": series, "values": values, "stats": stats, "indexContaining": indexOf])
    }

    // MARK: Strategy rules

    private func decisionJSON(_ decision: SignalDecision) -> [String: Any] {
        var out: [String: Any] = ["action": decision.action.rawValue, "headline": decision.headline,
                                  "evidence": J(decision.evidence), "barTime": ms(decision.barTime), "close": decision.close]
        if let reason = decision.exitReason { out["exitReason"] = reason.rawValue }
        if let margin = decision.ruleMargin { out["ruleMargin"] = margin }
        return out
    }

    private static func strategySpecs() -> [(String, StrategySpec)] {
        var protections = StrategySpec(kind: .rules, title: "Every protection", summary: "Test strategy", universe: [Fx.aapl],
                                       entry: .above(.close, .sma(10)), exit: .crossesBelow(.close, .ema(10)),
                                       protections: Protections(stopLossPct: 5, takeProfitPct: 6, trailingStopPct: 4, maxHoldingBars: 6),
                                       sizing: Sizing(mode: .fixedNotional, value: 750), reentryCooldownBars: 2)
        protections.summary = "Buys above the 10-day average and leaves on any protective exit."
        let groups = StrategySpec(kind: .rules, title: "Groups", summary: "Nested groups", universe: [Fx.aapl],
                                  entry: .any([.above(.macdHistogram(), .constant(0)),
                                               .all([.below(.close, .bollingerLower()), .below(.rsi(14), .constant(35))])]),
                                  exit: .all([.below(.macdLine(), .macdSignal()), .above(.rsi(14), .constant(50))]),
                                  protections: Protections(stopLossPct: 12), reentryCooldownBars: 0)
        var hourly = Fx.aboveAverageSpec([Fx.btc])
        hourly.timeframe = .hour
        hourly.title = "Hourly"
        hourly.protections = Protections(stopLossPct: 3, maxHoldingBars: 4)
        var unknown = Fx.aboveAverageSpec([Fx.aapl])
        unknown.title = "Missing number"
        unknown.entry = .above(.close, Operand(kind: .constant))
        return [
            ("aboveAverage", Fx.aboveAverageSpec([Fx.aapl])),
            ("momentum", AgentTemplates.momentum([Fx.aapl])),
            ("trend", AgentTemplates.trendFollowing([Fx.aapl])),
            ("crossover", AgentTemplates.movingAverageCrossover([Fx.aapl], fast: 5, slow: 20)),
            ("crossoverEMA", AgentTemplates.movingAverageCrossover([Fx.aapl], fast: 5, slow: 20, exponential: true)),
            ("meanReversion", AgentTemplates.meanReversion([Fx.aapl])),
            ("breakout", AgentTemplates.breakout([Fx.aapl])),
            ("cryptoMonitor", AgentTemplates.cryptoMonitor([Fx.btc])),
            ("riskManager", AgentTemplates.riskManager()),
            ("protections", protections),
            ("groups", groups),
            ("hourly", hourly),
            ("missingNumber", unknown)
        ]
    }

    func testStrategyVectors() throws {
        var series: [String: Any] = [:]
        var bars: [String: [Bar]] = [:]
        for (name, value) in Self.indicatorSeries where name == "walk" || name == "wave" {
            series[name] = J(value)
            bars[name] = value
        }
        func register(_ name: String, _ closes: [Double]) {
            let value = Fx.dailyBars(closes: closes)
            series[name] = J(value)
            bars[name] = value
        }
        register("cross", [Double](repeating: 100, count: 30) + [102, 104, 106])
        register("protect", [Double](repeating: 100, count: 30) + [100, 110, 120, 107])
        register("flat40", [Double](repeating: 100, count: 40))
        register("cooldown", [Double](repeating: 100, count: 30) + [110, 111, 112, 113])
        register("tiny", [Double](repeating: 100, count: 10))

        var decide: [Any] = []
        func add(_ name: String, _ specName: String, _ spec: StrategySpec, _ seriesName: String, _ index: Int,
                 position: PositionContext? = nil, lastExit: Date? = nil) {
            let prepared = PreparedSeries(bars: bars[seriesName]!)
            let decision = StrategyEvaluator.decide(spec: spec, prepared: prepared, index: index, position: position, lastExitTime: lastExit)
            var entry: [String: Any] = ["name": name, "spec": specName, "series": seriesName, "index": index, "out": decisionJSON(decision)]
            if let position {
                entry["position"] = ["quantity": position.quantity, "averageCost": position.averageCost, "openedAt": ms(position.openedAt)] as [String: Any]
            }
            if let lastExit { entry["lastExitTime"] = ms(lastExit) }
            decide.append(entry)
        }

        var specs: [String: Any] = [:]
        var warmup: [Any] = []
        let all = Self.strategySpecs()
        for (name, spec) in all {
            specs[name] = J(spec)
            warmup.append(["spec": name, "warmupBars": spec.warmupBars, "barsToFetch": spec.barsToFetch,
                           "ruleLines": spec.ruleLines] as [String: Any])
        }
        // A sweep: every strategy, along a wandering series, with and without a position.
        let walk = bars["walk"]!
        for (name, spec) in all {
            for index in Array(stride(from: 0, to: walk.count, by: 8)) + [walk.count - 1] {
                add("\(name)@\(index)", name, spec, "walk", index)
                let entry = max(index - 6, 0)
                add("\(name)@\(index) held", name, spec, "walk", index,
                    position: PositionContext(quantity: 10, averageCost: walk[entry].close, openedAt: walk[entry].time.addingTimeInterval(36_000)))
                if name == "aboveAverage" || name == "protections" || name == "momentum" {
                    add("\(name)@\(index) after exit", name, spec, "walk", index, lastExit: walk[max(index - 1, 0)].time)
                }
            }
        }
        // The targeted cases from the strategy tests.
        func custom(_ name: String, _ spec: StrategySpec) { specs[name] = J(spec) }
        let crossover = StrategySpec(kind: .rules, title: "Cross", summary: "", universe: [Fx.aapl],
                                     entry: .crossesAbove(.sma(5), .sma(20)), exit: .crossesBelow(.sma(5), .sma(20)),
                                     protections: Protections(stopLossPct: 8), reentryCooldownBars: 0)
        custom("cross5x20", crossover)
        for index in [29, 30, 31] { add("cross@\(index)", "cross5x20", crossover, "cross", index) }
        add("tooShort", "cross5x20", crossover, "tiny", 9)

        let protect = bars["protect"]!
        let position = PositionContext(quantity: 10, averageCost: 100, openedAt: protect[30].time)
        var spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil)
        spec.exit = nil
        spec.protections = Protections(trailingStopPct: 10)
        custom("trailing10", spec)
        add("trailing hit", "trailing10", spec, "protect", 33, position: position)
        add("trailing not hit", "trailing10", spec, "protect", 32, position: position)
        spec.protections = Protections(takeProfitPct: 15)
        custom("takeProfit15", spec)
        add("take profit hit", "takeProfit15", spec, "protect", 32, position: position)
        add("take profit not hit", "takeProfit15", spec, "protect", 31, position: position)
        spec.protections = Protections(stopLossPct: 8)
        custom("stop8", spec)
        add("stop hit", "stop8", spec, "protect", 33, position: PositionContext(quantity: 10, averageCost: 118, openedAt: protect[32].time))
        add("stop not hit", "stop8", spec, "protect", 33, position: position)
        add("zero cost", "stop8", spec, "protect", 33, position: PositionContext(quantity: 10, averageCost: 0, openedAt: protect[32].time))
        add("opened before the series", "stop8", spec, "protect", 33,
            position: PositionContext(quantity: 10, averageCost: 100, openedAt: protect[0].time.addingTimeInterval(-86_400)))
        add("zero quantity is no position", "stop8", spec, "protect", 33,
            position: PositionContext(quantity: 0, averageCost: 100, openedAt: protect[32].time))
        spec.protections = Protections(maxHoldingBars: 5)
        custom("timeLimit5", spec)
        let flat = bars["flat40"]!
        let timed = PositionContext(quantity: 1, averageCost: 100, openedAt: flat[30].time.addingTimeInterval(36_000))
        add("time limit not yet", "timeLimit5", spec, "flat40", 34, position: timed)
        add("time limit hit", "timeLimit5", spec, "flat40", 35, position: timed)

        var waiting = Fx.aboveAverageSpec([Fx.aapl])
        waiting.reentryCooldownBars = 3
        custom("cooldown3", waiting)
        let cooldown = bars["cooldown"]!
        add("cooldown 1 bar", "cooldown3", waiting, "cooldown", 32, lastExit: cooldown[31].time)
        add("cooldown 2 bars", "cooldown3", waiting, "cooldown", 33, lastExit: cooldown[31].time)
        add("cooldown over", "cooldown3", waiting, "cooldown", 33, lastExit: cooldown[30].time)
        add("exit before the series", "cooldown3", waiting, "cooldown", 33, lastExit: cooldown[0].time.addingTimeInterval(-86_400))

        // Scheduled buys.
        var dca: [Any] = []
        let dcaBars = Fx.dailyBars(closes: [Double](repeating: 50, count: 12))
        series["dca"] = J(dcaBars)
        let dcaSpec = AgentTemplates.dollarCostAveraging([Fx.spy], amountPerBuy: 100, intervalBars: 5)
        custom("dca5", dcaSpec)
        custom("dcaMissing", Fx.aboveAverageSpec([Fx.spy]))
        let dcaCases: [(String, String, Date?, Int)] = [
            ("first buy", "dca5", nil, 12), ("3 bars ago", "dca5", dcaBars[8].time, 12), ("5 bars ago", "dca5", dcaBars[6].time, 12),
            ("4 bars ago", "dca5", dcaBars[7].time, 12), ("before the series", "dca5", dcaBars[0].time.addingTimeInterval(-86_400), 12),
            ("same bar", "dca5", dcaBars[11].time.addingTimeInterval(3_600), 12), ("no schedule", "dcaMissing", nil, 12),
            ("no bars", "dca5", nil, 0)
        ]
        for (name, specName, lastBuy, count) in dcaCases {
            let chosen = specName == "dca5" ? dcaSpec : Fx.aboveAverageSpec([Fx.spy])
            let decision = StrategyEvaluator.decideDCA(spec: chosen, bars: Array(dcaBars.prefix(count)), lastBuyTime: lastBuy)
            var entry: [String: Any] = ["name": name, "spec": specName, "series": "dca", "count": count,
                                        "out": decision.map { decisionJSON($0) as Any } ?? NSNull()]
            if let lastBuy { entry["lastBuyTime"] = ms(lastBuy) }
            dca.append(entry)
        }

        // Rebalancing.
        var rebalance: [Any] = []
        let mixes: [(RebalanceConfig, [String: Double], Double)] = [
            (RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 5), ["us:A": 7_000, "us:B": 3_000], 10_000),
            (RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 15), ["us:A": 7_000, "us:B": 3_000], 10_000),
            (RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 5), [:], 10_000),
            (RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 5), ["us:A": 7_000], 0),
            (RebalanceConfig(targets: ["us:VTI": 60, "us:VXUS": 20, "us:BND": 20], driftThresholdPct: 5),
             ["us:VTI": 6_612.37, "us:VXUS": 1_411.18, "us:BND": 2_702.5], 10_726.05),
            (RebalanceConfig(targets: ["us:Z": 33.33, "us:M": 33.33, "us:A": 33.33], driftThresholdPct: 0.5),
             ["us:Z": 5_000, "us:M": 1_000.004, "us:A": 3_333.3], 10_000),
            (RebalanceConfig(targets: ["us:A": 50, "us:B": 50], driftThresholdPct: 10), ["us:A": 6_000, "us:B": 4_000], 10_000),
            (RebalanceConfig(targets: ["us:A": 50, "us:B": 50], driftThresholdPct: 10), ["us:A": 5_999.99, "us:B": 4_000.01], 10_000)
        ]
        for (config, values, equity) in mixes {
            let trades = StrategyEvaluator.rebalanceTrades(config: config, values: values, equity: equity)
            rebalance.append(["config": J(config), "values": values, "equity": equity,
                              "out": trades.map { ["instrumentID": $0.instrumentID, "side": $0.side.rawValue, "notional": $0.notional,
                                                   "currentPct": $0.currentPct, "targetPct": $0.targetPct] as [String: Any] }] as [String: Any])
        }

        // Research facts.
        var research: [Any] = []
        series["rising260"] = J(Fx.dailyBars(closes: Fx.risingCloses(count: 260)))
        bars["rising260"] = Fx.dailyBars(closes: Fx.risingCloses(count: 260))
        for (name, timeframe, count) in [("walk", Timeframe.day, 130), ("walk", .hour, 130), ("walk", .day, 3), ("walk", .day, 21),
                                         ("rising260", .day, 260), ("walk", .day, 0)] {
            research.append(["series": name, "timeframe": timeframe.rawValue, "count": count,
                             "out": J(StrategyEvaluator.researchFacts(bars: Array(bars[name]!.prefix(count)), timeframe: timeframe))] as [String: Any])
        }

        try Vectors.check("strategy", ["series": series, "specs": specs, "warmup": warmup, "decide": decide, "dca": dca,
                                       "rebalance": rebalance, "research": research])
    }

    func testValidatorVectors() throws {
        var cases: [Any] = []
        func add(_ name: String, _ spec: StrategySpec) {
            cases.append(["name": name, "spec": J(spec), "issues": J(StrategyValidator.validate(spec)),
                          "isValid": StrategyValidator.isValid(spec)] as [String: Any])
        }
        for template in AgentTemplates.all { add("template \(template.id)", template.build(template.defaultUniverse)) }
        for (name, spec) in Self.strategySpecs() { add("spec \(name)", spec) }

        var spec = Fx.aboveAverageSpec([])
        add("no assets", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl, Fx.bhp]); add("two currencies", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl, Fx.aapl]); add("listed twice", spec)
        spec = Fx.aboveAverageSpec((0..<26).map { Instrument.usStock("T\($0)") }); add("too many assets", spec)
        spec = Fx.aboveAverageSpec([Instrument.usStock("BRK B"), Instrument.usStock("ABCDEFGHIJKLM"), Instrument.usStock("BRK.B"), Instrument.usStock("é")])
        add("bad symbols", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl]); spec.title = "  \n"; add("no name", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil); spec.exit = nil; add("never sells", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil); spec.entry = nil; spec.exit = nil; add("no rules at all", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl]); spec.entry = nil; add("no buy rule", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl]); spec.entry = .above(.close, .sma(0)); add("period zero", spec)
        spec.entry = .above(.close, .sma(401)); add("period too long", spec)
        spec.entry = .above(.close, Operand(kind: .sma)); add("period missing", spec)
        spec.entry = .above(.macdLine(fast: 26, slow: 12, signal: 9), .constant(0)); add("macd fast above slow", spec)
        spec.entry = .above(Operand(kind: .macdSignal), .constant(0)); add("macd periods missing", spec)
        spec.entry = .above(.constant(1), .constant(2)); add("two constants", spec)
        spec.entry = .above(.close, Operand(kind: .constant)); add("constant missing", spec)
        spec.entry = .all([]); add("empty group", spec)
        spec.entry = Condition(op: .any); add("group without a list", spec)
        spec.entry = Condition(op: .above, left: .close); add("one-sided comparison", spec)
        spec.entry = .all((0..<9).map { .above(.close, .sma($0 + 2)) }); add("nine rules in a group", spec)
        spec.entry = .all([.any([.all([.any([.all([.any([.above(.close, .sma(5))])])])])])]); add("nested too deep", spec)
        spec.entry = .all([.any([.all([.any([.above(.close, .sma(5))])])])]); add("nested just enough", spec)
        spec.entry = .above(.close, .sma(20).scaled(by: 11)); add("multiplier too big", spec)
        spec.entry = .above(.close, .sma(20).scaled(by: 0)); add("multiplier zero", spec)
        spec.entry = .below(.close, Operand(kind: .bollingerLower, period: 20)); add("band without width", spec)
        spec.entry = .below(.close, .bollingerLower(20, deviations: 6)); add("band too wide", spec)
        spec.entry = .below(.close, Operand(kind: .bollingerMiddle, period: 20)); add("middle band needs no width", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl])
        spec.protections = Protections(stopLossPct: 100, takeProfitPct: 1_001, trailingStopPct: 0, maxHoldingBars: 0); add("protections out of range", spec)
        spec.protections = Protections(stopLossPct: 99.9, takeProfitPct: 1_000, trailingStopPct: 0.1, maxHoldingBars: 2_000); add("protections at the edges", spec)
        spec = Fx.aboveAverageSpec([Fx.aapl]); spec.sizing = Sizing(mode: .fixedNotional, value: 0); add("fixed size zero", spec)
        spec.sizing = Sizing(mode: .percentOfEquity, value: 101); add("percent size over 100", spec)
        spec.sizing = Sizing(mode: .percentOfEquity, value: 100); spec.reentryCooldownBars = 501; add("cooldown too long", spec)
        spec.reentryCooldownBars = -1; add("cooldown negative", spec)

        var dca = AgentTemplates.dollarCostAveraging([Fx.spy])
        dca.dca = nil; add("dca without a schedule", dca)
        dca.dca = DCAConfig(amountPerBuy: 0, intervalBars: 0); add("dca zero amount and interval", dca)
        dca.dca = DCAConfig(amountPerBuy: 50, intervalBars: 251); add("dca interval too long", dca)
        dca.dca = DCAConfig(amountPerBuy: 50, intervalBars: 250); dca.followsLedgerPositions = true; add("dca can't follow a portfolio", dca)

        var rebalance = AgentTemplates.etfRebalancing(UniverseCatalog.balancedETFs)
        rebalance.rebalance?.targets["us:VTI"] = 90; add("weights over 100", rebalance)
        rebalance.rebalance?.targets = ["us:NOPE": 50]; add("unknown target", rebalance)
        rebalance.rebalance?.targets = [:]; add("no targets", rebalance)
        rebalance.rebalance?.targets = ["us:VTI": 0]; add("zero weight", rebalance)
        rebalance.rebalance?.targets = ["us:VTI": 50]; rebalance.rebalance?.driftThresholdPct = 0.4; add("drift too small", rebalance)
        rebalance.rebalance?.driftThresholdPct = 51; add("drift too big", rebalance)
        rebalance.rebalance = nil; add("rebalance without targets", rebalance)
        add("even split of four", AgentTemplates.etfRebalancing(UniverseCatalog.broadETFs))
        add("even split of three", AgentTemplates.etfRebalancing(UniverseCatalog.cryptoMajors))

        var research = AgentTemplates.portfolioResearch([Fx.aapl])
        research.entry = .above(.close, .sma(20)); add("research with a rule", research)
        var guardian = AgentTemplates.riskManager()
        guardian.protections = Protections(); add("guardian with nothing to do", guardian)

        // A hand-written or AI-drafted strategy may give just a symbol.
        let lenient = #"[{"symbol":"btc"},{"symbol":"nvda"},{"symbol":"ZZZ","assetClass":"etf"},{"symbol":" bhp ","venue":"asx"},{"symbol":"bhp"},{"symbol":"eth","name":"Ether","currency":"AUD"},{"symbol":"NEW","assetClass":"crypto"},{"symbol":"spy","venue":"us"},{"symbol":"vod","venue":"lse"},{"symbol":"7203"},{"symbol":"hsba"},{"symbol":"hsba","venue":"hkex"},{"symbol":"sap","venue":"euronextParis"},{"symbol":"asml"}]"#
        let decoded = try JSONDecoder().decode([Instrument].self, from: Data(lenient.utf8))
        try Vectors.check("validator", ["cases": cases,
                                        "lenientInstruments": ["input": try JSONSerialization.jsonObject(with: Data(lenient.utf8)), "out": J(decoded)],
                                        "catalog": J(UniverseCatalog.all),
                                        "limits": ["maxUniverse": StrategyValidator.maxUniverse, "maxPeriod": StrategyValidator.maxPeriod]])
    }

    // MARK: Risk engine

    private struct RiskSetup {
        var ledger = Ledger(id: U(1), name: "Agent book", kind: .agentPaper, startingCash: 10_000, createdAt: Fx.now.addingTimeInterval(-86_400))
        var agent: TradingAgent? = TradingAgent(id: U(2), name: "Tester", mode: .paper, spec: Fx.aboveAverageSpec([Fx.aapl]),
                                                riskPolicy: .standard(budget: 10_000), budget: 10_000,
                                                createdAt: Fx.now.addingTimeInterval(-86_400))
        var policy = RiskPolicy.standard(budget: 10_000)
        var account = AccountPolicy(allowFixtureData: true)
        var quote: Quote? = Fx.quote(Fx.aapl, last: 100)
        var instrument = Fx.aapl
        var marketOpen = true
        var stats: InstrumentStats? = InstrumentStats(averageDollarVolume: 500_000_000, dailyVolatilityPct: 2)
        var openOrders: [Order] = []
        var otherOpenOrders: [Order] = []
        var knownIDs: Set<String> = []
        var accountExposure: Double?
        var accountEquity: Double?
        var accountNotionalToday: Double?
        var capabilities = PaperBroker.capabilities
        var granted: [BrokerPermission] = [.read, .trade]
        var now = Fx.now

        var context: RiskContext {
            RiskContext(now: now, policy: policy, accountPolicy: account, agent: agent.map(AgentRiskView.init), ledger: ledger,
                        openOrders: openOrders, otherOpenOrders: otherOpenOrders, knownClientOrderIDs: knownIDs,
                        accountExposure: accountExposure ?? (ledger.position(instrument.id)?.marketValue ?? 0),
                        accountEquity: accountEquity ?? ledger.equity,
                        accountNotionalToday: accountNotionalToday ?? ledger.notionalToday,
                        quote: quote, rules: PaperBroker.rules(for: instrument), capabilities: capabilities,
                        grantedPermissions: granted, marketOpen: marketOpen, stats: stats)
        }

        func intent(_ side: OrderSide = .buy, quantity: Double = 5, price: Double = 100, type: OrderType = .market,
                    tif: TimeInForce = .day, limit: Double? = nil, stop: Double? = nil, id: String = "order-1",
                    mode: ExecutionMode = .paper, fee: Double = 0) -> OrderIntent {
            OrderIntent(clientOrderID: id, instrument: instrument, side: side, type: type, timeInForce: tif,
                        quantity: quantity, price: price, limitPrice: limit, stopPrice: stop, estimatedFee: fee,
                        source: agent.map { .agent($0.id) } ?? .manual, mode: mode)
        }

        mutating func hold(_ quantity: Double, at price: Double, instrument: Instrument? = nil) {
            let target = instrument ?? self.instrument
            ledger.apply(Fill(id: U(900), orderID: U(901), ledgerID: ledger.id, instrument: target, side: .buy, quantity: quantity,
                              price: price, fee: 0, time: Fx.now.addingTimeInterval(-7_200), source: .manual, mode: .paper))
            ledger.notionalToday = 0
            ledger.lastFillAt = [:]
        }

        func openOrder(_ side: OrderSide, quantity: Double, agentID: UUID? = nil, instrument: Instrument? = nil,
                       ledgerID: UUID? = nil, number: Int = 500) -> Order {
            Order(id: U(number), clientOrderID: "open-\(number)", ledgerID: ledgerID ?? ledger.id, instrument: instrument ?? self.instrument,
                  side: side, type: .limit, quantity: quantity, limitPrice: 100, timeInForce: .gtc,
                  source: agentID.map { .agent($0) } ?? .manual, mode: .paper, status: .accepted,
                  referencePrice: 100, createdAt: Fx.now)
        }
    }

    private func intentJSON(_ intent: OrderIntent) -> [String: Any] {
        var out: [String: Any] = [
            "clientOrderID": intent.clientOrderID, "instrument": J(intent.instrument), "side": intent.side.rawValue,
            "type": intent.type.rawValue, "timeInForce": intent.timeInForce.rawValue, "quantity": intent.quantity,
            "price": intent.price, "estimatedFee": intent.estimatedFee, "source": J(intent.source), "mode": intent.mode.rawValue,
            "notional": intent.notional
        ]
        if let limit = intent.limitPrice { out["limitPrice"] = limit }
        if let stop = intent.stopPrice { out["stopPrice"] = stop }
        return out
    }

    private func contextJSON(_ c: RiskContext) -> [String: Any] {
        var out: [String: Any] = [
            "now": ms(c.now), "policy": J(c.policy), "accountPolicy": J(c.accountPolicy), "ledger": J(c.ledger),
            "openOrders": J(c.openOrders), "otherOpenOrders": J(c.otherOpenOrders),
            "knownClientOrderIDs": c.knownClientOrderIDs.sorted(), "accountExposure": c.accountExposure,
            "accountEquity": c.accountEquity, "accountNotionalToday": c.accountNotionalToday, "rules": J(c.rules),
            "capabilities": J(c.capabilities), "grantedPermissions": J(c.grantedPermissions), "marketOpen": c.marketOpen
        ]
        if let agent = c.agent {
            out["agent"] = ["id": agent.id.uuidString, "name": agent.name, "mode": agent.mode.rawValue,
                            "status": agent.status.rawValue, "universe": agent.universe.sorted(),
                            "followsLedgerPositions": agent.followsLedgerPositions] as [String: Any]
        }
        if let quote = c.quote { out["quote"] = J(quote) }
        if let stats = c.stats { out["stats"] = J(stats) }
        return out
    }

    func testRiskVectors() throws {
        var cases: [Any] = []
        var failed = Set<RiskCheckID>()
        func add(_ name: String, _ setup: RiskSetup, _ intent: OrderIntent? = nil) {
            let intent = intent ?? setup.intent()
            let context = setup.context
            let report = RiskEngine.evaluate(intent, context: context)
            report.failures.forEach { failed.insert($0.id) }
            cases.append(["name": name, "intent": intentJSON(intent), "context": contextJSON(context), "report": J(report),
                          "summary": report.summary, "isApproved": report.isApproved] as [String: Any])
        }

        var s = RiskSetup()
        add("ordinary agent buy", s)
        s.hold(5, at: 100); add("ordinary agent sell", s, s.intent(.sell))

        // 1. Kill switch.
        s = RiskSetup(); s.account.killSwitchEngaged = true; s.account.killSwitchAt = Fx.now.addingTimeInterval(-60)
        add("kill switch stops an agent", s)
        s.hold(5, at: 100); add("kill switch stops an agent's sell too", s, s.intent(.sell))
        s = RiskSetup(); s.account.killSwitchEngaged = true; s.agent = nil; add("kill switch warns a person", s)

        // 2. Trading mode.
        for mode in [AgentMode.signals, .researchOnly, .autonomousLive, .approvalRequired] {
            s = RiskSetup(); s.agent?.mode = mode; add("paper order from a \(mode.rawValue) agent", s)
        }
        s = RiskSetup(); s.ledger.mode = .live; add("paper order to a live account", s)
        s = RiskSetup(); s.agent = nil; add("live manual order, paper account", s, s.intent(mode: .live))
        s.ledger.mode = .live; add("live manual order, flag off", s, s.intent(mode: .live))
        s.account.live.manualOrdersEnabled = true; add("live manual order, flag on", s, s.intent(mode: .live))
        s = RiskSetup(); s.ledger.mode = .live; add("live order from a paper agent", s, s.intent(mode: .live))
        s.agent?.mode = .approvalRequired; add("live approval agent, flag off", s, s.intent(mode: .live))
        s.account.live.approvalAgentsEnabled = true; add("live approval agent, flag on", s, s.intent(mode: .live))
        s.agent?.mode = .autonomousLive; add("live autonomous agent, wrong flag", s, s.intent(mode: .live))
        s.account.live.autonomousAgentsEnabled = true; add("live autonomous agent, flag on", s, s.intent(mode: .live))

        // 3. Agent status.
        s = RiskSetup(); s.agent?.status = .paused; add("paused agent", s)
        s.agent?.status = .stopped; add("stopped agent", s)

        // 4. Broker permission.
        s = RiskSetup(); s.granted = [.read]; add("read-only grant", s)
        s = RiskSetup(); s.capabilities = LiveVenues.snapTrade; add("described-only venue", s)
        s = RiskSetup(); s.capabilities = LiveVenues.alpaca; s.capabilities.disabledReason = nil; add("disabled venue without a reason", s)
        s = RiskSetup(); s.capabilities.permissions = [.read]; add("adapter can't trade", s)
        s = RiskSetup(); s.capabilities.venues = [.crypto]; add("venue not offered", s)
        s = RiskSetup(); s.capabilities.assetClasses = [.etf]; add("asset class not offered", s)
        s = RiskSetup(); s.capabilities.orderTypes = [.market]; add("order type not offered", s, s.intent(type: .limit, limit: 100))
        s = RiskSetup(); s.capabilities.orderTypes = [.market, .limit, .stop]; add("stop limit not offered", s, s.intent(type: .stopLimit, limit: 100, stop: 99))
        s = RiskSetup(); s.capabilities.timeInForce = [.day]; add("time in force not offered", s, s.intent(tif: .fok))

        // 5. Approved assets.
        s = RiskSetup(); s.instrument = Fx.msft; s.quote = Fx.quote(Fx.msft, last: 100); add("outside the approved list", s)
        s = RiskSetup()
        s.agent = TradingAgent(id: U(3), name: "Guard", mode: .paper, spec: AgentTemplates.riskManager(),
                               riskPolicy: .standard(budget: 10_000), budget: 10_000, createdAt: Fx.now)
        add("guardian can't buy", s)
        s.hold(5, at: 100); add("guardian may sell", s, s.intent(.sell))

        // 6. Currency.
        s = RiskSetup(); s.agent = nil; s.instrument = Fx.bhp; s.quote = Fx.quote(Fx.bhp, last: 45); s.marketOpen = false
        add("AUD asset in a USD portfolio", s, s.intent(quantity: 10, price: 45))

        // 7. Market data.
        s = RiskSetup(); s.quote = nil; add("no quote", s)
        s.quote = Fx.quote(Fx.aapl, last: 0); add("zero price quote", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, provenance: .synthetic); add("synthetic quote", s)
        s.quote = Fx.quote(Fx.aapl, last: 100); s.account.allowFixtureData = false; add("fixture quote in production", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, provenance: .market("Alpaca (IEX)")); add("real quote", s)

        // 8. Market hours.
        s = RiskSetup(); s.marketOpen = false; add("closed market queues", s)
        add("closed market, immediate order", s, s.intent(tif: .ioc))
        add("closed market, fill or kill", s, s.intent(tif: .fok))
        s.policy.allowQueueOutsideHours = false; add("closed market, queueing off", s)
        s = RiskSetup(); s.agent?.versions[0].spec = Fx.aboveAverageSpec([Fx.btc]); s.instrument = Fx.btc
        s.quote = Fx.quote(Fx.btc, last: 60_000); s.marketOpen = false
        add("crypto ignores market hours", s, s.intent(quantity: 0.01, price: 60_000))

        // 9. Quote freshness.
        s = RiskSetup(); s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-3_600)); add("stale quote", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-900)); add("quote exactly at the limit", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-901)); add("quote one second past the limit", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-1_500), provenance: .fixture("delayed"))
        s.quote?.provenance.delaySeconds = 1_200; add("delayed feed inside its delay", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(600)); add("quote from the future", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(90)); add("quote slightly ahead", s)
        s.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-7_200)); s.marketOpen = false
        add("stale quote while queued", s)

        // 10. Exchange rules.
        s = RiskSetup(); s.agent?.versions[0].spec = Fx.aboveAverageSpec([Fx.btc]); s.instrument = Fx.btc; s.quote = Fx.quote(Fx.btc, last: 60_000)
        add("ten decimal places of crypto", s, s.intent(quantity: 0.012_345_678_9, price: 60_000))
        add("eight decimal places of crypto", s, s.intent(quantity: 0.012_345_67, price: 60_000))
        add("crypto below the minimum value", s, s.intent(quantity: 0.000_000_01, price: 60_000))
        s = RiskSetup()
        add("limit off the tick", s, s.intent(type: .limit, limit: 100.005))
        add("limit missing", s, s.intent(type: .limit))
        add("stop missing", s, s.intent(type: .stop))
        add("stop off the tick", s, s.intent(type: .stop, stop: 99.999))
        add("stop limit both missing", s, s.intent(type: .stopLimit))
        add("stop limit fine", s, s.intent(type: .stopLimit, limit: 101, stop: 100.5))
        add("zero quantity", s, s.intent(quantity: 0))
        add("negative quantity and zero price", s, s.intent(quantity: -1, price: 0))
        add("seven decimal places of a share", s, s.intent(quantity: 1.000_000_4))
        add("below the minimum value", s, s.intent(quantity: 0.005))
        s = RiskSetup(); s.agent = nil
        s.ledger = Ledger(id: U(4), name: "AUD", kind: .manualPaper, currency: "AUD", startingCash: 10_000, createdAt: Fx.now)
        s.instrument = Fx.bhp; s.quote = Fx.quote(Fx.bhp, last: 45)
        add("ASX fractional share", s, s.intent(quantity: 1.5, price: 45))
        add("ASX whole shares", s, s.intent(quantity: 2, price: 45))
        add("ASX half-cent limit", s, s.intent(quantity: 2, price: 45.005, type: .limit, limit: 45.005))
        add("ASX off-tick limit", s, s.intent(quantity: 2, price: 45.003, type: .limit, limit: 45.003))
        // Markets outside the US: whole shares, and lots of 100 in Tokyo and Singapore.
        let toyota = Instrument.listed("7203", name: "Toyota Motor", on: .tse)
        s = RiskSetup(); s.agent = nil
        s.ledger = Ledger(id: U(20), name: "Japan", kind: .manualPaper, currency: "JPY", startingCash: 5_000_000, createdAt: Fx.now)
        s.instrument = toyota; s.quote = Fx.quote(toyota, last: 2_800)
        s.stats = InstrumentStats(averageDollarVolume: 1e11, dailyVolatilityPct: 1.5)
        add("Tokyo odd lot", s, s.intent(quantity: 150, price: 2_800))
        add("Tokyo whole lot", s, s.intent(quantity: 200, price: 2_800))
        add("Tokyo fraction", s, s.intent(quantity: 100.5, price: 2_800))
        add("Tokyo tenth-yen limit", s, s.intent(quantity: 100, price: 2_800.1, type: .limit, limit: 2_800.1))
        s.stats = InstrumentStats(averageDollarVolume: 150_000_000, dailyVolatilityPct: 1.5)
        s.policy = RiskPolicy.standard(budget: 5_000_000, currency: "JPY")
        add("yen liquidity below the floor", s, s.intent(quantity: 100, price: 2_800))
        let shell = Instrument.listed("SHEL", name: "Shell", on: .lse)
        s = RiskSetup()
        s.ledger = Ledger(id: U(21), name: "UK", kind: .agentPaper, currency: "GBP", startingCash: 10_000, createdAt: Fx.now.addingTimeInterval(-86_400))
        s.agent = TradingAgent(id: U(22), name: "UK trend", mode: .paper, spec: Fx.aboveAverageSpec([shell]),
                               riskPolicy: .standard(budget: 10_000, currency: "GBP"), budget: 10_000, createdAt: Fx.now.addingTimeInterval(-86_400))
        s.policy = .standard(budget: 10_000, currency: "GBP")
        s.instrument = shell; s.quote = Fx.quote(shell, last: 27.5)
        add("a pound agent buys a London share", s, s.intent(quantity: 30, price: 27.5))
        add("London fraction", s, s.intent(quantity: 30.5, price: 27.5))
        s.stats = InstrumentStats(averageDollarVolume: 640_000, dailyVolatilityPct: 2); add("pound liquidity below the floor", s, s.intent(quantity: 30, price: 27.5))
        s.stats = InstrumentStats(averageDollarVolume: 3_400_000_000_000, dailyVolatilityPct: 2); add("very liquid in pounds", s, s.intent(quantity: 30, price: 27.5))
        s.marketOpen = false; add("London closed queues", s, s.intent(quantity: 30, price: 27.5))

        // 11. Order size.
        s = RiskSetup(); s.policy.maxPositionPct = 50
        add("over the order limit", s, s.intent(quantity: 10.5))
        add("at the order limit", s, s.intent(quantity: 10))
        add("a cent over the order limit", s, s.intent(quantity: 10.000_1))

        // 12. Buying power.
        s = RiskSetup(); s.ledger = Ledger(id: U(5), name: "Small", kind: .agentPaper, startingCash: 300, createdAt: Fx.now)
        s.policy.maxPositionPct = 100; s.account.maxSymbolExposurePct = 100; add("not enough cash", s)
        s = RiskSetup(); s.ledger = Ledger(id: U(6), name: "Committed", kind: .agentPaper, startingCash: 1_000, createdAt: Fx.now)
        s.policy.maxPositionPct = 100; s.account.maxSymbolExposurePct = 100; add("enough cash", s)
        s.openOrders = [s.openOrder(.buy, quantity: 6, instrument: Fx.msft)]; add("cash already committed", s)
        s = RiskSetup(); s.ledger = Ledger(id: U(7), name: "Exact", kind: .agentPaper, startingCash: 500, createdAt: Fx.now)
        s.policy.maxPositionPct = 100; s.account.maxSymbolExposurePct = 100; add("exactly enough cash", s)
        add("fee tips it over", s, s.intent(fee: 1.25))

        // 13. Holdings.
        s = RiskSetup(); add("selling with nothing held", s, s.intent(.sell))
        s.hold(3, at: 100); add("selling more than held", s, s.intent(.sell, quantity: 5))
        add("selling exactly what is held", s, s.intent(.sell, quantity: 3))
        s.openOrders = [s.openOrder(.sell, quantity: 2)]; add("units promised to another sell", s, s.intent(.sell, quantity: 3))
        s.openOrders = [s.openOrder(.sell, quantity: 3)]; add("everything promised to another sell", s, s.intent(.sell, quantity: 1))

        // 14. Position limit.
        s = RiskSetup(); s.hold(8, at: 100); add("over the position limit", s)
        add("inside the position limit", s, s.intent(quantity: 2))
        s = RiskSetup(); s.ledger = Ledger(id: U(8), name: "Empty", kind: .agentPaper, startingCash: 0, createdAt: Fx.now)
        add("no equity at all", s, s.intent(quantity: 1))

        // 15. Concentration.
        s = RiskSetup(); s.accountExposure = 3_400; s.accountEquity = 10_000; add("concentrated across portfolios", s)
        s.agent = nil; add("concentration warns a person", s)
        s = RiskSetup(); s.accountExposure = 0; s.accountEquity = 0; add("no account equity", s)

        // 16. Open positions.
        s = RiskSetup(); s.policy.maxOpenPositions = 1; s.hold(1, at: 50, instrument: Fx.msft); add("too many positions", s)
        s.hold(1, at: 100); add("adding to a position", s)

        // 17. Daily trading limit.
        s = RiskSetup(); s.ledger.notionalToday = 4_800; add("over the daily limit", s)
        s = RiskSetup(); s.account.maxTotalDailyNotional = 400; add("over the account daily limit", s)
        s = RiskSetup(); s.accountNotionalToday = 249_900; add("other portfolios used the account limit", s)

        // 18–19. Daily loss and drawdown.
        s = RiskSetup(); s.hold(5, at: 100); s.ledger.realizedToday = -400; add("daily loss reached", s, s.intent(quantity: 1))
        s.ledger.realizedToday = -299.99; add("daily loss just under", s, s.intent(quantity: 1))
        s.ledger.realizedToday = -400; s.ledger.peakEquity = 20_000; s.ledger.notionalToday = 1_000_000
        add("an exit on the worst day", s, s.intent(.sell, quantity: 5))
        s = RiskSetup(); s.hold(5, at: 100); s.ledger.peakEquity = 12_000; add("drawdown reached", s, s.intent(quantity: 1))
        s = RiskSetup(); s.ledger.dayStartEquity = 0; s.ledger.realizedToday = -50; add("no day-start equity", s)

        // 20. Spread.
        s = RiskSetup(); s.quote = Fx.quote(Fx.aapl, last: 100, spreadBps: 80); add("wide spread blocks a buy", s)
        s.hold(5, at: 100); add("wide spread warns a sell", s, s.intent(.sell))
        s = RiskSetup(); s.quote = Fx.quote(Fx.aapl, last: 100, spreadBps: nil); add("no bid and ask", s)
        s = RiskSetup(); s.quote = Quote(instrumentID: Fx.aapl.id, last: 100, bid: 100.2, ask: 100.1, time: Fx.now, provenance: .fixture("test"))
        add("crossed quote", s)
        s = RiskSetup(); s.quote = Fx.quote(Fx.aapl, last: 100, spreadBps: 50); add("spread exactly at the limit", s)

        // 21–22. Liquidity and volatility.
        s = RiskSetup(); s.stats = InstrumentStats(averageDollarVolume: 100_000, dailyVolatilityPct: 2); add("thinly traded", s)
        s.hold(5, at: 100); add("thinly traded sell", s, s.intent(.sell))
        s = RiskSetup(); s.stats = InstrumentStats(averageDollarVolume: 500_000_000, dailyVolatilityPct: 12); add("too volatile", s)
        s.stats = InstrumentStats(averageDollarVolume: 2_500_000_000, dailyVolatilityPct: 8); add("volatility at the limit", s)
        s.stats = InstrumentStats(averageDollarVolume: 999, dailyVolatilityPct: 12); s.agent = nil; add("thin and volatile for a person", s)
        s = RiskSetup(); s.stats = nil; add("no history for an agent", s)
        s.hold(5, at: 100); add("no history, agent sell", s, s.intent(.sell))
        s = RiskSetup(); s.stats = nil; s.agent = nil; add("no history for a person", s)

        // 23. Duplicates.
        s = RiskSetup(); s.knownIDs = ["order-1", "older"]; add("same client order id", s)
        s = RiskSetup(); s.openOrders = [s.openOrder(.buy, quantity: 1, agentID: s.agent?.id)]
        add("agent already working this order", s, s.intent(quantity: 1))
        s = RiskSetup(); s.openOrders = [s.openOrder(.buy, quantity: 1, agentID: U(77))]
        add("another agent's order in the same book", s, s.intent(quantity: 1))
        s = RiskSetup(); s.otherOpenOrders = [s.openOrder(.sell, quantity: 1, agentID: U(78), ledgerID: U(79))]
        add("agents trading against each other", s)
        s = RiskSetup(); s.otherOpenOrders = [s.openOrder(.sell, quantity: 1, ledgerID: U(79))]
        add("a person's opposing order elsewhere", s)
        s = RiskSetup(); s.agent = nil; s.knownIDs = ["order-1"]; add("a person repeats an order", s)

        // 24. Cooldown.
        s = RiskSetup(); s.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(-60); add("inside the cooldown", s)
        s.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(-400); add("after the cooldown", s)
        s.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(-300); add("cooldown just over", s)
        s.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(30); add("fill dated ahead", s)
        s.policy.cooldownSeconds = 0; add("cooldown switched off", s)

        // A person trading by hand.
        s = RiskSetup(); s.agent = nil; s.policy = TradingEngine.manualPolicy(equity: 10_000)
        add("a person's large order", s, s.intent(quantity: 60))
        add("a person without the cash", s, s.intent(quantity: 150))
        add("a person selling nothing", s, s.intent(.sell, quantity: 1))
        s.marketOpen = false; add("a person's order while shut", s, s.intent(quantity: 60))
        s.quote = nil; s.stats = nil; add("a person with no data", s)

        // Several things wrong at once.
        s = RiskSetup(); s.account.killSwitchEngaged = true; s.agent?.status = .paused; s.quote = nil; s.stats = nil
        add("everything wrong", s, s.intent(quantity: 500))

        XCTAssertEqual(failed, Set(RiskCheckID.allCases), "every check needs a failing case")
        var policies: [Any] = [
            ["budget": 10_000, "maxPositionPct": 10, "crypto": false, "currency": "USD", "out": J(RiskPolicy.standard(budget: 10_000))],
            ["budget": 5_000, "maxPositionPct": 10, "crypto": true, "currency": "USD", "out": J(RiskPolicy.standard(budget: 5_000, crypto: true))],
            ["budget": 333.33, "maxPositionPct": 0.2, "crypto": false, "currency": "USD", "out": J(RiskPolicy.standard(budget: 333.33, maxPositionPct: 0.2))],
            ["budget": 1, "maxPositionPct": 250, "crypto": false, "currency": "USD", "out": J(RiskPolicy.standard(budget: 1, maxPositionPct: 250))]
        ]
        for currency in Currencies.supported + ["XYZ"] {
            policies.append(["budget": Currencies.defaultBudget(currency), "maxPositionPct": 20, "crypto": false, "currency": currency,
                             "out": J(RiskPolicy.standard(budget: Currencies.defaultBudget(currency), maxPositionPct: 20, currency: currency))] as [String: Any])
        }
        var bad = RiskPolicy.standard(budget: 5_000)
        bad.maxOrderNotional = 0; bad.maxPositionPct = 0; bad.maxDailyNotional = -1; bad.maxDailyLossPct = 101
        bad.maxDrawdownPct = 150; bad.maxOpenPositions = 0; bad.maxSpreadBps = 0; bad.maxQuoteAgeSeconds = 4
        bad.cooldownSeconds = -1; bad.maxPriceGapPct = 51
        let issues: [Any] = [["policy": J(RiskPolicy.standard(budget: 5_000)), "issues": RiskPolicy.standard(budget: 5_000).issues],
                             ["policy": J(bad), "issues": bad.issues],
                             ["policy": J(TradingEngine.manualPolicy(equity: 0)), "issues": TradingEngine.manualPolicy(equity: 0).issues]]
        try Vectors.check("risk", ["cases": cases, "standardPolicy": policies, "policyIssues": issues,
                                   "manualPolicy": [["equity": 10_000, "out": J(TradingEngine.manualPolicy(equity: 10_000))],
                                                    ["equity": 0.5, "out": J(TradingEngine.manualPolicy(equity: 0.5))]],
                                   "titles": RiskCheckID.allCases.map { [$0.rawValue, $0.title] }])
    }

    // MARK: Paper broker

    func testBrokerVectors() throws {
        let standard = PaperBrokerConfig()
        let charged = PaperBrokerConfig(equityFeePerOrder: 1, equityFeeBps: 5, cryptoFeeBps: 40, modelledHalfSpreadBpsEquity: 3,
                                        modelledHalfSpreadBpsCrypto: 12, maxParticipation: 0.1, maxMatchQuoteAgeSeconds: 60)
        var instruments = [Fx.aapl, Fx.spy, Fx.btc, Fx.bhp, Instrument(symbol: "IOZ", assetClass: .etf, venue: .asx)]
        // One listing on every other venue, and the odd pairings the rules must still answer for.
        for venue in Venue.allCases where venue != .us && venue != .asx && venue != .crypto {
            instruments.append(.listed("TEST", on: venue))
        }
        instruments += [.listed("ISF", on: .lse, etf: true), Instrument(symbol: "ODD", assetClass: .equity, venue: .crypto),
                        Instrument(symbol: "COIN", assetClass: .crypto, venue: .tse)]

        var fee: [Any] = []
        for instrument in instruments {
            for notional in [0, 0.5, 1, 99.99, 100, 1_000.01, 12_345.67, 790.12] as [Double] {
                for first in [true, false] {
                    for (name, config) in [("standard", standard), ("charged", charged)] {
                        for side in [OrderSide.buy, .sell] {
                            fee.append([J(instrument), notional, first, name, side.rawValue,
                                        PaperBroker.fee(for: instrument, side: side, notional: notional, isFirstFillOfOrder: first, config: config)] as [Any])
                        }
                    }
                }
            }
        }

        var price: [Any] = []
        let quotes: [Quote] = [
            Fx.quote(Fx.aapl, last: 100), Fx.quote(Fx.aapl, last: 100, spreadBps: nil), Fx.quote(Fx.aapl, last: 123.456, spreadBps: nil),
            Fx.quote(Fx.aapl, last: 0.004, spreadBps: nil), Fx.quote(Fx.aapl, last: 100, spreadBps: 80),
            Quote(instrumentID: Fx.aapl.id, last: 100, bid: 0, ask: 100.1, time: Fx.now, provenance: .fixture("test")),
            Quote(instrumentID: Fx.aapl.id, last: 100, bid: 100.2, ask: 100.1, time: Fx.now, provenance: .fixture("test")),
            Quote(instrumentID: Fx.aapl.id, last: 100, bid: 100, ask: 100, time: Fx.now, provenance: .fixture("test")),
            Quote(instrumentID: Fx.aapl.id, last: 100, bid: 99.9, ask: nil, time: Fx.now, provenance: .fixture("test"))
        ]
        for instrument in [Fx.aapl, Fx.btc, Fx.bhp] {
            for quote in quotes {
                for side in OrderSide.allCases {
                    for (name, config) in [("standard", standard), ("charged", charged)] {
                        let result = PaperBroker.executionPrice(side: side, quote: quote, instrument: instrument, config: config)
                        price.append(["side": side.rawValue, "quote": J(quote), "instrument": J(instrument), "config": name,
                                      "price": result.price, "modelled": result.modelled, "mid": quote.mid,
                                      "spreadBps": quote.spreadBps.map { $0 as Any } ?? NSNull(),
                                      "hasTwoSidedMarket": quote.hasTwoSidedMarket] as [String: Any])
                    }
                }
            }
        }

        var match: [Any] = []
        var number = 100
        func order(_ side: OrderSide = .buy, type: OrderType = .market, quantity: Double = 10, limit: Double? = nil,
                   stop: Double? = nil, tif: TimeInForce = .day, instrument: Instrument = Fx.aapl,
                   status: OrderStatus = .accepted, filled: Double = 0, triggered: Bool = false) -> Order {
            number += 1
            var order = Order(id: U(number), clientOrderID: "c-\(number)", ledgerID: U(1), instrument: instrument, side: side, type: type,
                              quantity: quantity, limitPrice: limit, stopPrice: stop, timeInForce: tif, source: .manual, mode: .paper,
                              status: status, referencePrice: 100, createdAt: Fx.now)
            order.filledQuantity = filled
            if filled > 0 { order.averageFillPrice = 100 }
            if triggered { order.stopTriggeredAt = Fx.now.addingTimeInterval(-30) }
            return order
        }
        func add(_ name: String, _ order: Order, last: Double = 100, spreadBps: Double? = 2, open: Bool = true,
                 quoteTime: Date = Fx.now, dayVolume: Double? = nil, config: String = "standard", delay: Int = 0) {
            var quote = Fx.quote(order.instrument, last: last, spreadBps: spreadBps, time: quoteTime, dayVolume: dayVolume)
            quote.provenance.delaySeconds = delay
            let result = PaperBroker.match(order: order, quote: quote, marketOpen: open, now: Fx.now, config: config == "standard" ? standard : charged)
            var out: Any = NSNull()
            if let result {
                var value: [String: Any] = ["fillQuantity": result.fillQuantity, "fillPrice": result.fillPrice, "fee": result.fee,
                                            "newStatus": result.newStatus.rawValue, "stopTriggered": result.stopTriggered]
                if let note = result.note { value["note"] = note }
                out = value
            }
            match.append(["name": name, "order": J(order), "quote": J(quote), "marketOpen": open, "now": ms(Fx.now),
                          "config": config, "out": out] as [String: Any])
        }

        // Every order type, side and time in force against an ordinary quote.
        for type in OrderType.allCases {
            for side in OrderSide.allCases {
                for tif in TimeInForce.allCases {
                    // Limits and stops set so that some are marketable and some are not.
                    for (label, limit, stop) in [("near", 100.5, 99.5), ("far", 99.0, 101.0)] {
                        let needsLimit = type.needsLimitPrice, needsStop = type.needsStopPrice
                        if !needsLimit && !needsStop && label == "far" { continue }
                        let limitPrice: Double? = needsLimit ? (side == .buy ? limit : 200 - limit) : nil
                        let stopPrice: Double? = needsStop ? (side == .buy ? stop : 200 - stop) : nil
                        add("\(type.rawValue) \(side.rawValue) \(tif.rawValue) \(label)",
                            order(side, type: type, limit: limitPrice, stop: stopPrice, tif: tif))
                    }
                }
            }
        }
        add("one-sided feed buy", order(.buy), spreadBps: nil)
        add("one-sided feed sell", order(.sell), spreadBps: nil)
        add("one-sided feed, charged config", order(.buy), spreadBps: nil, config: "charged")
        add("limit buy above the ask", order(.buy, type: .limit, limit: 100.5))
        add("limit buy below the ask", order(.buy, type: .limit, limit: 99))
        add("limit sell below the bid", order(.sell, type: .limit, limit: 99.5))
        add("limit sell above the bid", order(.sell, type: .limit, limit: 101))
        add("limit without a price", order(.buy, type: .limit))
        add("stop without a price", order(.sell, type: .stop))
        add("sell stop waiting", order(.sell, type: .stop, stop: 95), last: 100)
        add("sell stop reached", order(.sell, type: .stop, stop: 95), last: 94)
        add("buy stop reached", order(.buy, type: .stop, stop: 105), last: 105)
        add("stop limit waiting for the stop", order(.buy, type: .stopLimit, limit: 105.2, stop: 105), last: 104)
        add("stop limit triggered, limit unavailable", order(.buy, type: .stopLimit, limit: 105.2, stop: 105), last: 105.5)
        add("stop limit triggered and filled", order(.buy, type: .stopLimit, limit: 106, stop: 105), last: 105.5)
        add("stop limit already triggered, still waiting", order(.buy, type: .stopLimit, limit: 105.2, stop: 105, triggered: true), last: 105.5)
        add("stop limit already triggered, now fills", order(.buy, type: .stopLimit, limit: 105.2, stop: 105, triggered: true), last: 105)
        add("stop limit triggered, immediate", order(.buy, type: .stopLimit, limit: 105.2, stop: 105, tif: .ioc), last: 105.5)
        add("stop not reached, immediate", order(.sell, type: .stop, stop: 95, tif: .fok), last: 100)
        add("part fill, day", order(.buy, quantity: 250), dayVolume: 10_000)
        add("part fill, good till cancelled", order(.buy, quantity: 250, tif: .gtc), dayVolume: 10_000)
        add("part fill, immediate or cancel", order(.buy, quantity: 250, tif: .ioc), dayVolume: 10_000)
        add("part fill, fill or kill", order(.buy, quantity: 250, tif: .fok), dayVolume: 10_000)
        add("fill or kill that fits", order(.buy, quantity: 50, tif: .fok), dayVolume: 10_000)
        add("the rest of a part-filled order", order(.buy, quantity: 250, status: .partiallyFilled, filled: 200), dayVolume: 10_000)
        add("second part of a part-filled order", order(.buy, quantity: 250, status: .partiallyFilled, filled: 100), dayVolume: 10_000, config: "charged")
        add("first part, charged config", order(.buy, quantity: 2_500), dayVolume: 10_000, config: "charged")
        add("tiny volume fills one step", order(.buy, quantity: 1), dayVolume: 0.000_01)
        add("zero volume is ignored", order(.buy, quantity: 1_000_000), dayVolume: 0)
        add("volume cap floors to the step", order(.buy, quantity: 10), dayVolume: 333.333_333_3)
        add("one-sided part fill", order(.buy, quantity: 250), spreadBps: nil, dayVolume: 10_000)
        add("one-sided immediate part fill", order(.sell, quantity: 250, tif: .ioc), spreadBps: nil, dayVolume: 10_000)
        add("market shut, day order", order(.buy), open: false)
        add("market shut, immediate", order(.buy, tif: .ioc), open: false)
        add("market shut, fill or kill", order(.sell, tif: .fok), open: false)
        add("stale quote, day order", order(.buy), quoteTime: Fx.now.addingTimeInterval(-7_200))
        add("stale quote, fill or kill", order(.buy, tif: .fok), quoteTime: Fx.now.addingTimeInterval(-7_200))
        add("quote exactly at the age limit", order(.buy), quoteTime: Fx.now.addingTimeInterval(-1_200))
        add("quote a second past the age limit", order(.buy), quoteTime: Fx.now.addingTimeInterval(-1_201))
        add("delayed feed inside its delay", order(.buy), quoteTime: Fx.now.addingTimeInterval(-2_000), delay: 900)
        add("short age limit", order(.buy), quoteTime: Fx.now.addingTimeInterval(-61), config: "charged")
        add("zero price quote", order(.buy), last: 0)
        add("zero price quote, immediate", order(.buy, tif: .ioc), last: 0)
        add("filled order", order(.buy, status: .filled))
        add("cancelled order", order(.buy, status: .canceled))
        add("rejected order", order(.buy, status: .rejected))
        add("expired order", order(.buy, status: .expired))
        add("pending order", order(.buy, status: .pendingSubmit))
        add("nothing left to fill", order(.buy, quantity: 10, status: .partiallyFilled, filled: 10))
        add("crypto fraction", order(.buy, quantity: 0.012_345_67, instrument: Fx.btc), last: 64_000, spreadBps: 4)
        add("crypto sell, charged", order(.sell, quantity: 0.5, instrument: Fx.btc), last: 64_000, spreadBps: 4, config: "charged")
        add("crypto one-sided", order(.buy, quantity: 0.25, instrument: Fx.btc), last: 64_123.456, spreadBps: nil)
        add("crypto volume cap", order(.buy, quantity: 3, instrument: Fx.btc), last: 64_000, spreadBps: 4, dayVolume: 123.456_789_123)
        add("ASX whole shares", order(.buy, quantity: 200, instrument: Fx.bhp), last: 45.12, spreadBps: nil)
        add("ASX volume cap", order(.sell, quantity: 200, instrument: Fx.bhp), last: 45.12, spreadBps: 10, dayVolume: 12_345)

        var expiry: [Any] = []
        for venue in Venue.allCases {
            for tif in TimeInForce.allCases {
                for text in ["2026-11-10T15:00:00Z", "2026-11-14T16:00:00Z", "2026-11-10T21:00:00Z", "2026-11-10T22:30:00Z",
                             "2026-11-25T22:00:00Z", "2026-11-27T17:00:00Z", "2026-12-24T02:00:00Z", "2028-01-01T10:00:00Z"] {
                    let placed = Fx.date(text)
                    expiry.append([tif.rawValue, venue.rawValue, ms(placed),
                                   PaperBroker.expiry(for: tif, venue: venue, placedAt: placed).map(ms) ?? NSNull()] as [Any])
                }
            }
        }

        var transitions: [Any] = []
        for from in OrderStatus.allCases {
            for to in OrderStatus.allCases {
                transitions.append([from.rawValue, to.rawValue, from.canTransition(to: to)] as [Any])
            }
        }

        try Vectors.check("broker", [
            "configs": ["standard": J(standard), "charged": J(charged)],
            "rules": instruments.map { instrument -> [String: Any] in
                let amounts: [Double] = [0.5, 1, 100, 250.25, 1_234_567, 0.012_345_67]
                return ["instrument": J(instrument), "rules": J(PaperBroker.rules(for: instrument)),
                        "quantityText": amounts.map { [$0, PaperBroker.quantityText($0, for: instrument)] as [Any] }]
            },
            "capabilities": ["paper": J(PaperBroker.capabilities), "live": J(LiveVenues.all)],
            "fee": fee, "executionPrice": price, "match": match, "expiry": expiry, "transitions": transitions,
            "statuses": OrderStatus.allCases.map { [$0.rawValue, $0.isOpen, $0.isTerminal, $0.displayName] as [Any] },
            "modes": AgentMode.allCases.map { [$0.rawValue, $0.displayName, $0.isLive, $0.placesOrders, $0.producesSignals] as [Any] },
            "schedules": [5, 15, 59, 60, 61, 90, 120, 1_440, 10_080].map { [$0, AgentSchedule(intervalMinutes: $0).displayName] as [Any] }
        ])
    }

    // MARK: Ledger

    func testLedgerVectors() throws {
        var sequences: [Any] = []
        var fillNumber = 2_000

        func state(_ ledger: Ledger) -> [String: Any] {
            ["ledger": J(ledger), "equity": ledger.equity, "positionsValue": ledger.positionsValue,
             "unrealizedPnL": ledger.unrealizedPnL, "totalReturn": ledger.totalReturn, "totalReturnPct": ledger.totalReturnPct,
             "drawdownPct": ledger.drawdownPct, "dayChangePct": ledger.dayChangePct,
             "positions": ledger.positions.map { ["id": $0.id, "averageCost": $0.averageCost, "marketValue": $0.marketValue,
                                                  "unrealizedPnL": $0.unrealizedPnL, "unrealizedPct": $0.unrealizedPct] as [String: Any] }]
        }

        func sequence(_ name: String, _ ledger: Ledger, _ body: (inout Ledger, inout [Any]) -> Void) {
            var ledger = ledger
            var steps: [Any] = []
            let start = state(ledger)
            body(&ledger, &steps)
            sequences.append(["name": name, "start": start, "steps": steps] as [String: Any])
        }
        func apply(_ ledger: inout Ledger, _ steps: inout [Any], _ side: OrderSide, _ quantity: Double, _ price: Double,
                   fee: Double = 0, at time: Date = Fx.now, instrument: Instrument = Fx.aapl) {
            fillNumber += 1
            let fill = Fill(id: U(fillNumber), orderID: U(fillNumber + 10_000), ledgerID: ledger.id, instrument: instrument, side: side,
                            quantity: quantity, price: price, fee: fee, time: time, source: .manual, mode: .paper)
            let booked = ledger.apply(fill)
            steps.append(["op": "apply", "fill": J(fill), "gross": fill.gross, "booked": J(booked), "after": state(ledger)] as [String: Any])
        }
        func mark(_ ledger: inout Ledger, _ steps: inout [Any], _ quotes: [Quote], at now: Date) {
            let map = Dictionary(uniqueKeysWithValues: quotes.map { ($0.instrumentID, $0) })
            ledger.mark(quotes: map, now: now)
            steps.append(["op": "mark", "quotes": J(map), "now": ms(now), "after": state(ledger)] as [String: Any])
        }
        func roll(_ ledger: inout Ledger, _ steps: inout [Any], at now: Date) {
            ledger.rollDayIfNeeded(now: now)
            steps.append(["op": "roll", "now": ms(now), "after": state(ledger)] as [String: Any])
        }

        sequence("average cost, fees and a partial sell",
                 Ledger(id: U(11), name: "Test", kind: .manualPaper, startingCash: 10_000, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .buy, 10, 100, fee: 1)
            apply(&ledger, &steps, .buy, 10, 120, fee: 1)
            apply(&ledger, &steps, .sell, 5, 130, fee: 1)
            apply(&ledger, &steps, .sell, 15, 90, fee: 1, at: Fx.now.addingTimeInterval(600))
        }
        sequence("selling everything removes the whole cost",
                 Ledger(id: U(12), name: "Test", kind: .manualPaper, startingCash: 1_000, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .buy, 0.333_333, 300.01, instrument: Fx.btc)
            apply(&ledger, &steps, .sell, 0.333_333, 310, instrument: Fx.btc)
        }
        sequence("fractions that don't divide evenly",
                 Ledger(id: U(13), name: "Test", kind: .agentPaper, agentID: U(14), startingCash: 5_000.005, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .buy, 0.012_345_67, 64_012.8, fee: 1.98, instrument: Fx.btc)
            apply(&ledger, &steps, .buy, 0.004_111_11, 63_250.25, fee: 0.65, instrument: Fx.btc)
            apply(&ledger, &steps, .sell, 0.005, 65_000.01, fee: 0.81, at: Fx.now.addingTimeInterval(60), instrument: Fx.btc)
            apply(&ledger, &steps, .sell, 0.003, 61_000, fee: 0.46, at: Fx.now.addingTimeInterval(120), instrument: Fx.btc)
            apply(&ledger, &steps, .buy, 3.333_333, 123.45, fee: 0, at: Fx.now.addingTimeInterval(180))
            apply(&ledger, &steps, .sell, 1.111_111, 125.5, fee: 0, at: Fx.now.addingTimeInterval(240))
            apply(&ledger, &steps, .sell, 0.008_456_78, 66_100.5, fee: 1.4, at: Fx.now.addingTimeInterval(300), instrument: Fx.btc)
        }
        sequence("selling what isn't there",
                 Ledger(id: U(15), name: "Test", kind: .manualPaper, startingCash: 1_000, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .sell, 1, 100, fee: 2)
            apply(&ledger, &steps, .buy, 2, 100)
            apply(&ledger, &steps, .sell, 5, 110, fee: 1)                 // more than held: only what is held leaves
        }
        sequence("marks, peak and drawdown",
                 Ledger(id: U(16), name: "Test", kind: .manualPaper, startingCash: 5_000, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .buy, 10, 100)
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 110)], at: Fx.now)
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 90, time: Fx.now.addingTimeInterval(60))], at: Fx.now.addingTimeInterval(60))
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 500, provenance: .synthetic)], at: Fx.now.addingTimeInterval(120))
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 0)], at: Fx.now.addingTimeInterval(180))
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 95.5, provenance: .market("Alpaca (IEX)")), Fx.quote(Fx.msft, last: 1)],
                 at: Fx.now.addingTimeInterval(3_700))
            mark(&ledger, &steps, [], at: Fx.now.addingTimeInterval(3_800))
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 130)], at: Fx.now.addingTimeInterval(7_400))
        }
        sequence("daily counters reset on the next trading day",
                 Ledger(id: U(17), name: "Test", kind: .manualPaper, startingCash: 5_000, createdAt: Fx.now)) { ledger, steps in
            apply(&ledger, &steps, .buy, 10, 100)
            apply(&ledger, &steps, .sell, 10, 90)
            roll(&ledger, &steps, at: Fx.now.addingTimeInterval(3_600))
            roll(&ledger, &steps, at: Fx.now.addingTimeInterval(86_400))
            apply(&ledger, &steps, .buy, 4, 50, at: Fx.now.addingTimeInterval(2 * 86_400))
            mark(&ledger, &steps, [Fx.quote(Fx.aapl, last: 55)], at: Fx.now.addingTimeInterval(3 * 86_400))
        }
        sequence("an AUD book keeps Sydney days",
                 Ledger(id: U(18), name: "Aussie", kind: .manualPaper, currency: "AUD", startingCash: 20_000,
                        createdAt: Fx.date("2026-11-09T12:30:00Z"))) { ledger, steps in
            apply(&ledger, &steps, .buy, 100, 45.12, fee: 9.5, at: Fx.date("2026-11-09T12:59:00Z"), instrument: Fx.bhp)
            apply(&ledger, &steps, .sell, 40, 46, fee: 9.5, at: Fx.date("2026-11-09T13:01:00Z"), instrument: Fx.bhp)
            roll(&ledger, &steps, at: Fx.date("2026-11-10T12:59:59Z"))
            roll(&ledger, &steps, at: Fx.date("2026-11-10T13:00:00Z"))
        }

        try Vectors.check("ledger", ["sequences": sequences])
    }

    // MARK: Audit chain

    func testAuditVectors() throws {
        var chains: [Any] = []
        func chain(_ name: String, _ build: (inout AuditLog) -> Void, archiveKeeping: Int? = nil) {
            var log = AuditLog()
            build(&log)
            if let archiveKeeping { log.archive(keepingLast: archiveKeeping) }
            let events: [Any] = log.events.map { event in
                var input: [String: Any] = ["timeMs": event.time.timeIntervalSince1970 * 1_000, "actor": event.actor.rawValue,
                                            "kind": event.kind.rawValue, "summary": event.summary, "details": event.details]
                if let mode = event.mode { input["mode"] = mode.rawValue }
                if let id = event.agentID { input["agentID"] = id.uuidString }
                if let id = event.ledgerID { input["ledgerID"] = id.uuidString }
                if let id = event.orderID { input["orderID"] = id.uuidString }
                if let id = event.proposalID { input["proposalID"] = id.uuidString }
                if let id = event.instrumentID { input["instrumentID"] = id }
                return ["input": input, "sequence": event.sequence, "previousHash": event.previousHash,
                        "canonical": event.canonical, "hash": event.hash] as [String: Any]
            }
            let verification = log.verify()
            chains.append(["name": name, "baseHash": log.baseHash, "baseSequence": log.baseSequence, "events": events,
                           "lastHash": log.lastHash, "nextSequence": log.nextSequence,
                           "intact": verification.isIntact, "eventCount": verification.eventCount] as [String: Any])
        }

        chain("plain events") { log in
            for i in 0..<5 {
                log.append(time: Fx.now.addingTimeInterval(Double(i)), actor: .user, kind: .orderSubmitted,
                           summary: "Order \(i)", mode: .paper, details: ["n": String(i), "a": "x"])
            }
        }
        chain("every field and every kind") { log in
            for (i, kind) in AuditKind.allCases.enumerated() {
                let actor: AuditActor = [.user, .agent, .system, .copilot][i % 4]
                log.append(time: Fx.now.addingTimeInterval(Double(i) * 37), actor: actor, kind: kind,
                           summary: "\(kind.title) #\(i)", mode: i % 3 == 0 ? nil : (i % 3 == 1 ? .paper : .live),
                           agentID: i % 2 == 0 ? U(100 + i) : nil, ledgerID: i % 5 == 0 ? nil : U(200 + i),
                           orderID: i % 4 == 1 ? U(300 + i) : nil, proposalID: i % 4 == 2 ? U(400 + i) : nil,
                           instrumentID: i % 2 == 1 ? "us:AAPL" : nil,
                           details: i % 3 == 0 ? [:] : ["quantity": String(Double(i) * 1.5), "price": String(100.01 + Double(i))])
            }
        }
        chain("awkward text") { log in
            log.append(time: Fx.now, actor: .user, kind: .riskPolicyChanged, summary: "Momo: risk limits changed.",
                       agentID: UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"),
                       details: ["maxOrderNotional": "500.0 → 750.0", "maxPositionPct": "10.0 → 12.5"])
            log.append(time: Fx.now.addingTimeInterval(0.1234), actor: .system, kind: .orderFilled,
                       summary: "Paper fill: Bought 4.081299 AAPL at $122.51.", mode: .paper, instrumentID: "us:AAPL",
                       details: ["Zeta": "1", "alpha": "2", "Alpha": "3", "_x": "4", "a1": "5", "a": "6", "B": "7", "10": "8", "9": "9"])
            log.append(time: Fx.now.addingTimeInterval(0.9995), actor: .agent, kind: .signalGenerated,
                       summary: "Pipes | semi;colons = equals, \"quotes\", a tab\tand a\nnew line", instrumentID: "crypto:BTC",
                       details: ["note": "a=b;c|d", "empty": ""])
            log.append(time: Fx.now.addingTimeInterval(1.0005), actor: .copilot, kind: .strategyChanged,
                       summary: "Café — naïve façade · 50% ± 5 × 2 ≥ 1 “curly” ‘quotes’ … ✓ 🚀 日本語",
                       details: ["emoji": "📈", "accent": "é"])
            log.append(time: Date(timeIntervalSince1970: 0), actor: .system, kind: .backtestRun, summary: "")
            log.append(time: Date(timeIntervalSince1970: 1_794_322_800.0005), actor: .system, kind: .backtestRun, summary: "half a millisecond")
            log.append(time: Date(timeIntervalSince1970: 1_794_322_800.0015), actor: .system, kind: .backtestRun, summary: "one and a half")
        }
        chain("after archiving", { log in
            for i in 0..<10 { log.append(time: Fx.now, actor: .system, kind: .signalGenerated, summary: "S\(i)") }
        }, archiveKeeping: 4)

        try Vectors.check("audit", ["genesisHash": AuditLog.genesisHash, "chains": chains,
                                    "kinds": AuditKind.allCases.map { [$0.rawValue, $0.title] }])
    }

    /// The other direction: an audit trail written by the server (the TypeScript engine, hashed
    /// again by the database trigger) must verify with this package's own rule.
    ///
    /// Skipped unless `SERVER_AUDIT_CHAIN` names a file exported by the local-stack test
    /// `supabase/functions/tests/integration/api.test.ts` (run with `TRADING_AUDIT_EXPORT`).
    func testServerAuditChainVerifies() throws {
        guard let path = ProcessInfo.processInfo.environment["SERVER_AUDIT_CHAIN"], !path.isEmpty else {
            throw XCTSkip("Set SERVER_AUDIT_CHAIN to an audit trail exported by the server's integration test.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let log = try TradingCodec.decoder().decode(AuditLog.self, from: data)
        XCTAssertGreaterThanOrEqual(log.events.count, 6, "the end-to-end run writes at least six events")
        XCTAssertEqual(log.verify(), AuditVerification(isIntact: true, brokenAtSequence: nil, eventCount: log.events.count))
        XCTAssertEqual(log.events.first?.previousHash, AuditLog.genesisHash)
        XCTAssertEqual(log.events.map(\.sequence), Array(1...log.events.count))
        XCTAssertTrue(log.events.allSatisfy { $0.mode == nil || $0.mode == .paper }, "nothing live happened on the server")

        // And the rule still bites on the server's data: change one word in the middle and it says where.
        var tampered = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var events = try XCTUnwrap(tampered["events"] as? [[String: Any]])
        let target = events.count / 2
        events[target]["summary"] = (events[target]["summary"] as? String ?? "") + " (edited)"
        tampered["events"] = events
        let edited = try TradingCodec.decoder().decode(AuditLog.self, from: JSONSerialization.data(withJSONObject: tampered))
        XCTAssertEqual(edited.verify(), AuditVerification(isIntact: false, brokenAtSequence: target + 1, eventCount: events.count))
    }

    // MARK: Engine scenarios

    /// Runs the engine through whole stories and records the state it ends in. The server
    /// replays the same stories and must end in the same state — same numbers, same
    /// wording, same audit trail. Generated UUIDs are replaced with labels and audit hashes
    /// are left out (they cover the UUIDs; the audit vectors pin the hash rule).
    private final class Recorder {
        private var labels: [(uuid: String, label: String)] = []
        private var seen = Set<UUID>()
        private var counters: [String: Int] = [:]
        private var log: [Any] = []

        private func mark(_ id: UUID, _ kind: String) {
            guard seen.insert(id).inserted else { return }
            let n = counters[kind, default: 0]
            counters[kind] = n + 1
            labels.append((id.uuidString, "\(kind)-\(n)"))
        }

        func sync(_ engine: TradingEngine) {
            let state = engine.state
            state.ledgers.forEach { mark($0.id, "ledger") }
            state.agents.forEach { mark($0.id, "agent") }
            state.connections.forEach { mark($0.id, "connection") }
            state.signals.forEach { mark($0.id, "signal") }
            state.proposals.forEach { mark($0.id, "proposal") }
            state.orders.forEach { mark($0.id, "order") }
            state.fills.forEach { mark($0.id, "fill") }
            for run in state.runs {
                mark(run.id, "run")
                run.steps.forEach { mark($0.id, "step") }
            }
            state.audit.events.forEach { mark($0.id, "audit") }
        }

        func note(_ step: String, _ value: Any) { log.append(["step": step, "value": value] as [String: Any]) }

        func result(_ step: String, _ result: OrderResult, fills: [Fill]? = nil) {
            var value: [String: Any] = ["accepted": result.isAccepted, "risk": J(result.risk), "summary": result.risk.summary]
            if let order = result.order { value["order"] = J(order) }
            if case .accepted(_, let fills, _) = result { value["fills"] = J(fills) }
            note(step, value)
        }

        func error(_ step: String, _ error: Error) {
            guard let error = error as? TradingError else { return note(step, ["kind": "unexpected"]) }
            switch error {
            case .invalid(let problems): note(step, ["kind": "invalid", "messages": problems, "description": error.errorDescription ?? ""] as [String: Any])
            case .liveNotAvailable(let reasons): note(step, ["kind": "liveNotAvailable", "messages": reasons, "description": error.errorDescription ?? ""] as [String: Any])
            case .notFound(let what): note(step, ["kind": "notFound", "messages": [what], "description": error.errorDescription ?? ""] as [String: Any])
            case .notAllowed(let why): note(step, ["kind": "notAllowed", "messages": [why], "description": error.errorDescription ?? ""] as [String: Any])
            }
        }

        func preview(_ step: String, _ preview: OrderPreview?) {
            guard let p = preview else { return note(step, NSNull()) }
            var value: [String: Any] = [
                "instrument": J(p.instrument), "side": p.side.rawValue, "type": p.type.rawValue, "timeInForce": p.timeInForce.rawValue,
                "quantity": p.quantity, "estimatedPrice": p.estimatedPrice, "estimatedValue": p.estimatedValue,
                "estimatedFee": p.estimatedFee, "cashAfter": p.cashAfter, "currency": p.currency, "ledgerName": p.ledgerName,
                "mode": p.mode.rawValue, "usesModelledSpread": p.usesModelledSpread, "willQueueUntilOpen": p.willQueueUntilOpen,
                "risk": J(p.risk), "canSubmit": p.canSubmit
            ]
            if let quote = p.quote { value["quote"] = J(quote) }
            if let spread = p.spreadBps { value["spreadBps"] = spread }
            if let next = p.nextOpen { value["nextOpen"] = ms(next) }
            note(step, value)
        }

        func dump(_ engine: inout TradingEngine) -> Any {
            sync(engine)
            var state = J(engine.state) as! [String: Any]
            if var audit = state["audit"] as? [String: Any], let events = audit["events"] as? [[String: Any]] {
                audit["events"] = events.map { event -> [String: Any] in
                    var event = event
                    event["hash"] = nil
                    event["previousHash"] = nil
                    return event
                }
                state["audit"] = audit
            }
            let notices: [Any] = engine.drainNotices().map { notice in
                var value: [String: Any] = ["kind": notice.kind.rawValue, "title": notice.title, "body": notice.body, "mode": notice.mode.rawValue]
                if let id = notice.agentID { value["agentID"] = id.uuidString }
                if let id = notice.orderID { value["orderID"] = id.uuidString }
                if let id = notice.proposalID { value["proposalID"] = id.uuidString }
                if let id = notice.instrumentID { value["instrumentID"] = id }
                return value
            }
            let verification = engine.state.audit.verify()
            let root: [String: Any] = ["state": state, "notices": notices, "log": log,
                                       "auditIntact": verification.isIntact, "auditCount": verification.eventCount,
                                       "dueAgents": engine.dueAgents(at: Fx.now.addingTimeInterval(30 * 86_400)).map(\.id.uuidString),
                                       "instrumentsNeedingQuotes": engine.instrumentsNeedingQuotes().map(\.id)]
            var text = Vectors.line(root)
            for (uuid, label) in labels {
                text = text.replacingOccurrences(of: uuid, with: label, options: [.caseInsensitive])
            }
            var normalized = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            if var state = normalized["state"] as? [String: Any], let known = state["knownClientOrderIDs"] as? [String] {
                state["knownClientOrderIDs"] = known.sorted()
                normalized["state"] = state
            }
            return normalized
        }
    }

    private func draft(review: Bool = false, mode: AgentMode = .paper, universe: [Instrument] = [Fx.aapl],
                       budget: Double = 5_000, policy: RiskPolicy? = nil) -> AgentDraft {
        AgentDraft(name: "Momo", mode: mode, spec: Fx.aboveAverageSpec(universe), budget: budget, maxPositionPct: 10,
                   riskPolicy: policy, reviewEachPaperTrade: review)
    }

    private func bullish(_ instrument: Instrument = Fx.aapl, now: Date = Fx.now) -> MarketSnapshot {
        let closes = Fx.risingCloses()
        var snapshot = MarketSnapshot()
        snapshot.series[instrument.id] = BarSeries(instrument: instrument, timeframe: .day,
                                                   bars: Fx.dailyBars(closes: closes, days: Fx.usTradingDays(count: closes.count, before: now)),
                                                   provenance: .fixture("test"), fetchedAt: now)
        snapshot.quotes[instrument.id] = Fx.quote(instrument, last: closes.last!, time: now)
        return snapshot
    }

    private func portfolio(_ engine: inout TradingEngine, _ rec: Recorder, cash: Double = 10_000, last: Double = 100,
                           dayVolume: Double? = nil) throws -> Ledger {
        let ledger = try engine.createPaperPortfolio(name: "Practice", startingCash: cash, now: Fx.now)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: last, dayVolume: dayVolume)],
                      stats: [Fx.aapl.id: InstrumentStats(averageDollarVolume: 1e9, dailyVolatilityPct: 2)], now: Fx.now)
        rec.sync(engine)
        return ledger
    }

    private typealias Scenario = (name: String, fixtures: Bool, run: (inout TradingEngine, Recorder) throws -> Void)

    private func scenarios() -> [Scenario] {
        let saturday = Fx.date("2026-11-14T16:00:00Z")
        let mondayOpen = Fx.date("2026-11-16T14:31:00Z")
        var list: [Scenario] = []
        func scenario(_ name: String, fixtures: Bool = true, _ run: @escaping (inout TradingEngine, Recorder) throws -> Void) {
            list.append((name, fixtures, run))
        }

        scenario("signal to approval to fill") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            let proposal = e.state.proposals[0]
            r.result("approve", try e.approveProposal(id: proposal.id, now: Fx.now.addingTimeInterval(60))); r.sync(e)
            do { _ = try e.approveProposal(id: proposal.id, now: Fx.now.addingTimeInterval(90)) } catch { r.error("approve again", error) }
            r.sync(e)
        }
        scenario("automatic paper agent, then a second run") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            let later = Fx.now.addingTimeInterval(3_600)
            e.runAgent(id: agent.id, snapshot: self.bullish(now: later), trigger: .schedule, now: later); r.sync(e)
        }
        scenario("a waiting proposal is not duplicated") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            let later = Fx.now.addingTimeInterval(1_800)
            e.runAgent(id: agent.id, snapshot: self.bullish(now: later), trigger: .schedule, now: later); r.sync(e)
        }
        scenario("stop loss exit") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            let tomorrow = Fx.now.addingTimeInterval(86_400)
            let closes = Fx.risingCloses() + [105]
            var snapshot = MarketSnapshot()
            snapshot.series[Fx.aapl.id] = BarSeries(instrument: Fx.aapl, timeframe: .day,
                                                    bars: Fx.dailyBars(closes: closes, days: Fx.usTradingDays(count: closes.count, before: tomorrow)),
                                                    provenance: .fixture("test"), fetchedAt: tomorrow)
            snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 105, time: tomorrow)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: tomorrow); r.sync(e)
        }
        scenario("risk-blocked trade") { e, r in
            var policy = RiskPolicy.standard(budget: 5_000)
            policy.maxDailyNotional = 100
            let agent = try e.createAgent(self.draft(policy: policy), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            do { _ = try e.approveProposal(id: e.state.proposals[0].id, now: Fx.now) } catch { r.error("approve blocked", error) }
            r.sync(e)
        }
        scenario("research and signal modes") { e, r in
            let research = try e.createAgent(self.draft(mode: .researchOnly), now: Fx.now); r.sync(e)
            e.runAgent(id: research.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            let signals = try e.createAgent(self.draft(mode: .signals), now: Fx.now); r.sync(e)
            e.runAgent(id: signals.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
        }
        scenario("live modes are refused") { e, r in
            do { _ = try e.createAgent(self.draft(mode: .approvalRequired), now: Fx.now) } catch { r.error("create live agent", error) }
            r.sync(e)
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            do { try e.setMode(agentID: agent.id, mode: .autonomousLive, now: Fx.now) } catch { r.error("promote to live", error) }
            r.sync(e)
            r.note("blockers before", ["manual": e.liveBlockers(for: nil), "approval": e.liveBlockers(for: .approvalRequired),
                                       "autonomous": e.liveBlockers(for: .autonomousLive)])
            e.state.connections.append(BrokerConnection(adapterID: "snaptrade", name: "CommSec", environment: .live,
                                                        permissions: [.read], createdAt: Fx.now))
            r.sync(e)
            r.note("blockers with a read-only connection", ["manual": e.liveBlockers(for: nil), "approval": e.liveBlockers(for: .approvalRequired)])
            let portfolio = try e.createPaperPortfolio(name: "Mine", startingCash: 10_000, now: Fx.now); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 100)], now: Fx.now); r.sync(e)
            let request = OrderRequest(clientOrderID: "live-1", ledgerID: portfolio.id, instrument: Fx.aapl, side: .buy, quantity: 1, mode: .live)
            r.preview("preview live", e.preview(request, now: Fx.now))
            r.result("submit live", e.submit(request, now: Fx.now)); r.sync(e)
            let agentLive = OrderRequest(clientOrderID: "live-2", ledgerID: portfolio.id, instrument: Fx.aapl, side: .buy, quantity: 1,
                                         source: .agent(agent.id), mode: .live)
            r.result("submit live as an agent", e.submit(agentLive, now: Fx.now)); r.sync(e)
        }
        scenario("switching away from paper") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            try e.setMode(agentID: agent.id, mode: .signals, now: Fx.now); r.sync(e)
            try e.setMode(agentID: agent.id, mode: .paper, now: Fx.now.addingTimeInterval(60)); r.sync(e)
            try e.setMode(agentID: agent.id, mode: .researchOnly, now: Fx.now.addingTimeInterval(120)); r.sync(e)
        }
        scenario("missing data") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: MarketSnapshot(failures: [Fx.aapl.id: "HTTP 500"]), trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("synthetic data") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            var snapshot = self.bullish()
            snapshot.series[Fx.aapl.id]?.provenance = .synthetic
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("fixture data with the production setting", fixtures: false) { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("stale history") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            var stale = self.bullish(now: Fx.now.addingTimeInterval(-21 * 86_400))
            stale.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 122.5)
            e.runAgent(id: agent.id, snapshot: stale, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("wrong timeframe and no bars") { e, r in
            let agent = try e.createAgent(self.draft(universe: [Fx.aapl, Fx.msft]), now: Fx.now); r.sync(e)
            var snapshot = self.bullish()
            snapshot.series[Fx.aapl.id]?.timeframe = .hour
            snapshot.series[Fx.msft.id] = BarSeries(instrument: Fx.msft, timeframe: .day, bars: [], provenance: .fixture("test"), fetchedAt: Fx.now)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("a signal without a live quote") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            var snapshot = self.bullish()
            snapshot.quotes = [:]
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("today's unfinished bar is ignored") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            var days = Fx.usTradingDays(count: 40)
            days.append(Fx.date("2026-11-10T05:00:00Z"))
            var snapshot = MarketSnapshot()
            snapshot.series[Fx.aapl.id] = Fx.series(Fx.aapl, closes: [Double](repeating: 100, count: 40) + [150], days: days)
            snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 150)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("repeated data failures pause the agent") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            for i in 0..<6 {
                e.runAgent(id: agent.id, snapshot: MarketSnapshot(), trigger: .schedule, now: Fx.now.addingTimeInterval(Double(i) * 3_600)); r.sync(e)
            }
        }
        scenario("kill switch") { e, r in
            let a = try e.createAgent(self.draft(), now: saturday); r.sync(e)
            var second = self.draft(universe: [Fx.msft])
            second.name = "Second"
            let b = try e.createAgent(second, now: saturday); r.sync(e)
            e.runAgent(id: a.id, snapshot: self.bullish(now: saturday), trigger: .manual, now: saturday); r.sync(e)
            r.note("cancelled", e.engageKillSwitch(now: saturday)); r.sync(e)
            r.note("cancelled again", e.engageKillSwitch(now: saturday.addingTimeInterval(1))); r.sync(e)
            e.runAgent(id: b.id, snapshot: self.bullish(Fx.msft, now: saturday), trigger: .manual, now: saturday); r.sync(e)
            do { try e.resumeAgent(id: a.id, now: saturday) } catch { r.error("resume while engaged", error) }
            e.releaseKillSwitch(now: saturday); r.sync(e)
            try e.resumeAgent(id: a.id, now: saturday); r.sync(e)
        }
        scenario("kill switch with a waiting proposal and a manual order") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            let ledger = try e.createPaperPortfolio(name: "Mine", startingCash: 10_000, now: Fx.now); r.sync(e)
            r.result("resting limit", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy,
                                                            type: .limit, quantity: 1, limitPrice: 90, timeInForce: .gtc), now: Fx.now)); r.sync(e)
            r.note("cancelled", e.engageKillSwitch(now: Fx.now.addingTimeInterval(60))); r.sync(e)
            r.result("manual order while engaged", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy,
                                                                         quantity: 1), now: Fx.now.addingTimeInterval(120))); r.sync(e)
            do { _ = try e.approveProposal(id: e.state.proposals[0].id, now: Fx.now.addingTimeInterval(180)) } catch { r.error("approve after the switch", error) }
            r.sync(e)
        }
        scenario("drawdown limit pauses the agent") { e, r in
            e.state.accountPolicy.maxSymbolExposurePct = 100
            var big = self.draft()
            big.spec.sizing = Sizing(mode: .percentOfEquity, value: 90)
            big.riskPolicy = RiskPolicy(maxOrderNotional: 5_000, maxPositionPct: 100, maxDailyNotional: 10_000)
            let agent = try e.createAgent(big, now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 98, time: Fx.now.addingTimeInterval(600))], now: Fx.now.addingTimeInterval(600)); r.sync(e)
        }
        scenario("daily loss notice") { e, r in
            e.state.accountPolicy.maxSymbolExposurePct = 100
            var big = self.draft()
            big.spec.sizing = Sizing(mode: .percentOfEquity, value: 50)
            big.riskPolicy = RiskPolicy(maxOrderNotional: 5_000, maxPositionPct: 100, maxDailyNotional: 20_000, maxDrawdownPct: 50, cooldownSeconds: 0)
            let agent = try e.createAgent(big, now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .schedule, now: Fx.now); r.sync(e)
            let ledgerID = agent.ledgerID!
            let held = e.state.ledger(ledgerID)!.position(Fx.aapl.id)!.quantity
            let later = Fx.now.addingTimeInterval(600)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 110, time: later)], now: later); r.sync(e)
            r.result("sell at a loss", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledgerID, instrument: Fx.aapl, side: .sell,
                                                             quantity: held), now: later)); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 110, time: later.addingTimeInterval(60))], now: later.addingTimeInterval(60)); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 110, time: later.addingTimeInterval(120))], now: later.addingTimeInterval(120)); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(now: later.addingTimeInterval(180)), trigger: .schedule, now: later.addingTimeInterval(180)); r.sync(e)
        }
        scenario("manual market order: preview and fill") { e, r in
            let ledger = try self.portfolio(&e, r)
            let request = OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, notional: 1_000)
            r.preview("preview", e.preview(request, now: Fx.now))
            r.result("submit", e.submit(request, now: Fx.now)); r.sync(e)
            let sell = OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .sell, quantity: 4)
            r.preview("preview sell", e.preview(sell, now: Fx.now.addingTimeInterval(30)))
            r.result("sell", e.submit(sell, now: Fx.now.addingTimeInterval(30))); r.sync(e)
            r.preview("preview unknown portfolio", e.preview(OrderRequest(clientOrderID: "m-3", ledgerID: U(999), instrument: Fx.aapl, side: .buy, quantity: 1), now: Fx.now))
            r.result("unknown portfolio", e.submit(OrderRequest(clientOrderID: "m-3", ledgerID: U(999), instrument: Fx.aapl, side: .buy, quantity: 1), now: Fx.now)); r.sync(e)
        }
        scenario("refused orders are recorded") { e, r in
            let ledger = try self.portfolio(&e, r, cash: 1_000)
            r.result("too big", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 20), now: Fx.now)); r.sync(e)
            r.result("short", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .sell, quantity: 1), now: Fx.now)); r.sync(e)
            r.result("no quote", e.submit(OrderRequest(clientOrderID: "m-3", ledgerID: ledger.id, instrument: Fx.msft, side: .buy, notional: 100), now: Fx.now)); r.sync(e)
            r.result("same id after a refusal", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 2), now: Fx.now.addingTimeInterval(5))); r.sync(e)
        }
        scenario("the same order is never placed twice") { e, r in
            let ledger = try self.portfolio(&e, r)
            let request = OrderRequest(clientOrderID: "tap-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 2)
            r.result("first", e.submit(request, now: Fx.now)); r.sync(e)
            r.result("again", e.submit(request, now: Fx.now.addingTimeInterval(1))); r.sync(e)
        }
        scenario("limit order rests then fills") { e, r in
            let ledger = try self.portfolio(&e, r)
            let result = e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                               quantity: 5, limitPrice: 95, timeInForce: .gtc), now: Fx.now)
            r.result("place", result); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 97, time: Fx.now.addingTimeInterval(60))], now: Fx.now.addingTimeInterval(60)); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 94.9, time: Fx.now.addingTimeInterval(120))], now: Fx.now.addingTimeInterval(120)); r.sync(e)
            r.note("cancel after fill", e.cancelOrder(id: result.order!.id, now: Fx.now.addingTimeInterval(180))); r.sync(e)
        }
        scenario("cancel and expire") { e, r in
            let ledger = try self.portfolio(&e, r)
            let first = e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                              quantity: 1, limitPrice: 90), now: Fx.now)
            r.result("first", first); r.sync(e)
            r.note("cancel", e.cancelOrder(id: first.order!.id, now: Fx.now)); r.sync(e)
            r.note("cancel twice", e.cancelOrder(id: first.order!.id, now: Fx.now)); r.sync(e)
            r.result("second", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                                     quantity: 1, limitPrice: 90), now: Fx.now)); r.sync(e)
            e.ingest(quotes: [], now: Fx.date("2026-11-10T21:05:00Z")); r.sync(e)
        }
        scenario("a large order fills in parts") { e, r in
            let ledger = try self.portfolio(&e, r, cash: 100_000, dayVolume: 10_000)
            r.result("place", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 250,
                                                    timeInForce: .gtc), now: Fx.now)); r.sync(e)
            for minute in 1...2 {
                let time = Fx.now.addingTimeInterval(Double(minute) * 60)
                e.ingest(quotes: [Fx.quote(Fx.aapl, last: 100 + Double(minute), time: time, dayVolume: 10_000)], now: time); r.sync(e)
            }
        }
        scenario("stops and immediate orders") { e, r in
            let ledger = try self.portfolio(&e, r, cash: 100_000, dayVolume: 10_000)
            r.result("buy", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 50), now: Fx.now)); r.sync(e)
            r.result("stop", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .sell, type: .stop,
                                                   quantity: 20, stopPrice: 95, timeInForce: .gtc), now: Fx.now)); r.sync(e)
            r.result("stop limit", e.submit(OrderRequest(clientOrderID: "m-3", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .stopLimit,
                                                         quantity: 5, limitPrice: 104, stopPrice: 103, timeInForce: .gtc), now: Fx.now)); r.sync(e)
            r.result("immediate part fill", e.submit(OrderRequest(clientOrderID: "m-4", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy,
                                                                  quantity: 250, timeInForce: .ioc), now: Fx.now)); r.sync(e)
            r.result("fill or kill too big", e.submit(OrderRequest(clientOrderID: "m-5", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy,
                                                                   quantity: 250, timeInForce: .fok), now: Fx.now)); r.sync(e)
            let t1 = Fx.now.addingTimeInterval(60)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 104.5, time: t1, dayVolume: 10_000)], now: t1); r.sync(e)
            let t2 = Fx.now.addingTimeInterval(120)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 103.5, time: t2, dayVolume: 10_000)], now: t2); r.sync(e)
            let t3 = Fx.now.addingTimeInterval(180)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 94, time: t3, dayVolume: 10_000)], now: t3); r.sync(e)
        }
        scenario("an order placed while shut fills at the open") { e, r in
            let ledger = try e.createPaperPortfolio(name: "Practice", startingCash: 10_000, now: saturday); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 100, time: saturday)], now: saturday); r.sync(e)
            let request = OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10)
            r.preview("preview", e.preview(request, now: saturday))
            r.result("place", e.submit(request, now: saturday)); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 101, time: mondayOpen)], now: mondayOpen); r.sync(e)
        }
        scenario("an order placed while shut is cancelled on a gap") { e, r in
            let ledger = try e.createPaperPortfolio(name: "Practice", startingCash: 10_000, now: saturday); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 100, time: saturday)], now: saturday); r.sync(e)
            r.result("place", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: saturday)); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.aapl, last: 115, time: mondayOpen)], now: mondayOpen); r.sync(e)
        }
        scenario("crypto on a Saturday") { e, r in
            let ledger = try e.createPaperPortfolio(name: "Crypto practice", startingCash: 5_000, now: saturday); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.btc, last: 64_000, spreadBps: 4, time: saturday)], now: saturday); r.sync(e)
            r.result("buy", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.btc, side: .buy, notional: 1_000), now: saturday)); r.sync(e)
            r.result("sell half", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.btc, side: .sell, quantity: 0.007),
                                           now: saturday.addingTimeInterval(60))); r.sync(e)
        }
        scenario("an AUD portfolio and the ASX") { e, r in
            let sydneyOpen = Fx.date("2026-11-10T00:30:00Z")
            let ledger = try e.createPaperPortfolio(name: "Aussie", startingCash: 20_000, currency: "AUD", now: sydneyOpen); r.sync(e)
            e.ingest(quotes: [Fx.quote(Fx.bhp, last: 45.12, spreadBps: nil, time: sydneyOpen), Fx.quote(Fx.aapl, last: 100, time: sydneyOpen)],
                     now: sydneyOpen); r.sync(e)
            r.result("whole shares", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.bhp, side: .buy, notional: 2_000), now: sydneyOpen)); r.sync(e)
            r.result("fraction refused", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.bhp, side: .buy, quantity: 1.5), now: sydneyOpen)); r.sync(e)
            r.result("wrong currency", e.submit(OrderRequest(clientOrderID: "m-3", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 1), now: sydneyOpen)); r.sync(e)
        }
        scenario("strategy changes are versioned") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            let proposal = e.state.proposals[0]
            var spec = agent.spec
            spec.protections.stopLossPct = 5
            try e.updateStrategy(agentID: agent.id, spec: spec, note: "Tighter stop", author: .copilot, now: Fx.now); r.sync(e)
            do { _ = try e.approveProposal(id: proposal.id, now: Fx.now) } catch { r.error("approve the old proposal", error) }
            try e.updateStrategy(agentID: agent.id, spec: spec, note: "No change", now: Fx.now); r.sync(e)
            spec.exit = nil
            spec.protections = Protections()
            do { try e.updateStrategy(agentID: agent.id, spec: spec, note: "", now: Fx.now) } catch { r.error("invalid strategy", error) }
            var aud = agent.spec
            aud.universe = [Fx.bhp]
            do { try e.updateStrategy(agentID: agent.id, spec: aud, note: "", now: Fx.now) } catch { r.error("other currency", error) }
            do { try e.updateStrategy(agentID: agent.id, spec: AgentTemplates.portfolioResearch([Fx.aapl]), note: "", now: Fx.now) } catch { r.error("research strategy", error) }
            r.sync(e)
        }
        scenario("proposals expire") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            do { _ = try e.approveProposal(id: e.state.proposals[0].id, now: Fx.now.addingTimeInterval(86_400 + 60)) } catch { r.error("approve too late", error) }
            r.sync(e)
        }
        scenario("rejecting a proposal") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            try e.rejectProposal(id: e.state.proposals[0].id, now: Fx.now); r.sync(e)
            try e.rejectProposal(id: e.state.proposals[0].id, now: Fx.now.addingTimeInterval(5)); r.sync(e)
            do { try e.rejectProposal(id: U(998), now: Fx.now) } catch { r.error("unknown proposal", error) }
        }
        scenario("creation validates everything") { e, r in
            var bad = self.draft()
            bad.name = " "
            bad.budget = 5
            bad.spec.universe = []
            do { _ = try e.createAgent(bad, now: Fx.now) } catch { r.error("bad agent", error) }
            do { _ = try e.createPaperPortfolio(name: "x", startingCash: 1, now: Fx.now) } catch { r.error("tiny portfolio", error) }
            do { _ = try e.createPaperPortfolio(name: "x", startingCash: 1_000, currency: "XYZ", now: Fx.now) } catch { r.error("unknown currency", error) }
            do { _ = try e.createPaperPortfolio(name: "x", startingCash: 500, currency: "JPY", now: Fx.now) } catch { r.error("too few yen", error) }
            do { _ = try e.createPaperPortfolio(name: "", startingCash: 99.99, currency: "GBP", now: Fx.now) } catch { r.error("no name and too few pounds", error) }
            do { _ = try e.createPaperPortfolio(name: String(repeating: "n", count: 41), startingCash: 1_000, now: Fx.now) } catch { r.error("long name", error) }
            var yen = AgentDraft(name: "Yen", mode: .paper, spec: Fx.aboveAverageSpec([.listed("7203", on: .tse)]), budget: 5_000, maxPositionPct: 10)
            do { _ = try e.createAgent(yen, now: Fx.now) } catch { r.error("yen budget too small", error) }
            yen.budget = 2_000_000_000
            do { _ = try e.createAgent(yen, now: Fx.now) } catch { r.error("yen budget too big", error) }
            var research = self.draft()
            research.spec = AgentTemplates.portfolioResearch([Fx.aapl])
            do { _ = try e.createAgent(research, now: Fx.now) } catch { r.error("research strategy in paper mode", error) }
            var fast = self.draft()
            fast.schedule = AgentSchedule(intervalMinutes: 1)
            do { _ = try e.createAgent(fast, now: Fx.now) } catch { r.error("too frequent", error) }
            var guardian = AgentDraft(name: "Guard", mode: .paper, spec: AgentTemplates.riskManager(), budget: 10_000, maxPositionPct: 100)
            do { _ = try e.createAgent(guardian, now: Fx.now) } catch { r.error("guardian without a portfolio", error) }
            guardian.attachToLedgerID = U(997)
            do { _ = try e.createAgent(guardian, now: Fx.now) } catch { r.error("guardian with an unknown portfolio", error) }
            var limits = self.draft()
            limits.riskPolicy = RiskPolicy(maxOrderNotional: 0, maxPositionPct: 10, maxDailyNotional: 100)
            do { _ = try e.createAgent(limits, now: Fx.now) } catch { r.error("bad limits", error) }
            r.sync(e)
        }
        scenario("reset and delete") { e, r in
            let ledger = try self.portfolio(&e, r)
            r.result("buy", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: Fx.now)); r.sync(e)
            r.result("resting", e.submit(OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit, quantity: 1,
                                                      limitPrice: 80, timeInForce: .gtc), now: Fx.now)); r.sync(e)
            try e.resetPaperPortfolio(id: ledger.id, now: Fx.now.addingTimeInterval(60)); r.sync(e)
            let agent = try e.createAgent(self.draft(), now: Fx.now.addingTimeInterval(120)); r.sync(e)
            do { try e.deletePaperPortfolio(id: agent.ledgerID!, now: Fx.now.addingTimeInterval(180)) } catch { r.error("delete an agent's portfolio", error) }
            try e.deleteAgent(id: agent.id, now: Fx.now.addingTimeInterval(240)); r.sync(e)
            try e.deletePaperPortfolio(id: ledger.id, now: Fx.now.addingTimeInterval(300)); r.sync(e)
            do { try e.deletePaperPortfolio(id: ledger.id, now: Fx.now.addingTimeInterval(360)) } catch { r.error("delete twice", error) }
            do { try e.resetPaperPortfolio(id: ledger.id, now: Fx.now.addingTimeInterval(360)) } catch { r.error("reset a deleted portfolio", error) }
        }
        scenario("housekeeping: rename, schedule, review, limits, pause, resume, delete") { e, r in
            let agent = try e.createAgent(self.draft(review: true), now: Fx.now); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now); r.sync(e)
            try e.renameAgent(id: agent.id, name: "  Momentum One ", now: Fx.now.addingTimeInterval(10)); r.sync(e)
            do { try e.renameAgent(id: agent.id, name: "", now: Fx.now) } catch { r.error("empty name", error) }
            try e.setSchedule(agentID: agent.id, AgentSchedule(intervalMinutes: 15), now: Fx.now.addingTimeInterval(20)); r.sync(e)
            do { try e.setSchedule(agentID: agent.id, AgentSchedule(intervalMinutes: 2), now: Fx.now) } catch { r.error("too frequent", error) }
            try e.setReviewEachPaperTrade(agentID: agent.id, false, now: Fx.now.addingTimeInterval(30)); r.sync(e)
            try e.setReviewEachPaperTrade(agentID: agent.id, true, now: Fx.now.addingTimeInterval(40)); r.sync(e)
            var policy = agent.riskPolicy
            policy.maxOrderNotional = 750
            policy.maxPositionPct = 12.5
            policy.maxDailyLossPct = 2
            try e.updateRiskPolicy(agentID: agent.id, policy: policy, now: Fx.now.addingTimeInterval(50)); r.sync(e)
            try e.updateRiskPolicy(agentID: agent.id, policy: policy, now: Fx.now.addingTimeInterval(55)); r.sync(e)
            policy.maxDrawdownPct = 0
            do { try e.updateRiskPolicy(agentID: agent.id, policy: policy, now: Fx.now) } catch { r.error("bad limits", error) }
            try e.pauseAgent(id: agent.id, now: Fx.now.addingTimeInterval(60)); r.sync(e)
            try e.pauseAgent(id: agent.id, now: Fx.now.addingTimeInterval(65)); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now.addingTimeInterval(70)); r.sync(e)
            try e.resumeAgent(id: agent.id, now: Fx.now.addingTimeInterval(80)); r.sync(e)
            try e.resumeAgent(id: agent.id, now: Fx.now.addingTimeInterval(85)); r.sync(e)
            e.runAgent(id: agent.id, snapshot: self.bullish(now: Fx.now.addingTimeInterval(90)), trigger: .manual, now: Fx.now.addingTimeInterval(90)); r.sync(e)
            try e.deleteAgent(id: agent.id, now: Fx.now.addingTimeInterval(100)); r.sync(e)
            do { try e.pauseAgent(id: agent.id, now: Fx.now) } catch { r.error("pause a deleted agent", error) }
            r.note("run a deleted agent", e.runAgent(id: agent.id, snapshot: self.bullish(), trigger: .manual, now: Fx.now) == nil)
        }
        scenario("scheduled buys") { e, r in
            let dca = AgentDraft(name: "DCA", mode: .paper, spec: AgentTemplates.dollarCostAveraging([Fx.spy]), budget: 5_000, maxPositionPct: 60)
            let agent = try e.createAgent(dca, now: Fx.now); r.sync(e)
            let flat = [Double](repeating: 400, count: 60)
            e.runAgent(id: agent.id, snapshot: Fx.snapshot([(Fx.spy, flat, 400)]), trigger: .schedule, now: Fx.now); r.sync(e)
            let later = Fx.now.addingTimeInterval(3_600)
            var again = Fx.snapshot([(Fx.spy, flat, 400)])
            again.quotes[Fx.spy.id] = Fx.quote(Fx.spy, last: 400, time: later)
            e.runAgent(id: agent.id, snapshot: again, trigger: .schedule, now: later); r.sync(e)
        }
        scenario("rebalancing from cash") { e, r in
            e.state.accountPolicy.maxSymbolExposurePct = 100
            let funds = UniverseCatalog.balancedETFs
            var rebalance = AgentDraft(name: "Mix", mode: .paper, spec: AgentTemplates.etfRebalancing(funds), budget: 10_000, maxPositionPct: 70)
            rebalance.riskPolicy = RiskPolicy(maxOrderNotional: 10_000, maxPositionPct: 70, maxDailyNotional: 20_000)
            let mix = try e.createAgent(rebalance, now: Fx.now); r.sync(e)
            let snapshot = Fx.snapshot(funds.map { ($0, [Double](repeating: 100, count: 60), 100) })
            e.runAgent(id: mix.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
            let later = Fx.now.addingTimeInterval(3_600)
            var onTarget = snapshot
            for fund in funds { onTarget.quotes[fund.id] = Fx.quote(fund, last: 100, time: later) }
            e.runAgent(id: mix.id, snapshot: onTarget, trigger: .schedule, now: later); r.sync(e)
            // One fund runs ahead: it is sold back and the laggards topped up.
            let muchLater = Fx.now.addingTimeInterval(2 * 3_600)
            var drifted = snapshot
            drifted.quotes[funds[0].id] = Fx.quote(funds[0], last: 130, time: muchLater)
            drifted.quotes[funds[1].id] = Fx.quote(funds[1], last: 100, time: muchLater)
            drifted.quotes[funds[2].id] = Fx.quote(funds[2], last: 100, time: muchLater)
            e.runAgent(id: mix.id, snapshot: drifted, trigger: .schedule, now: muchLater); r.sync(e)
            var missing = snapshot
            missing.quotes[funds[2].id] = nil
            missing.series[funds[1].id] = nil
            e.runAgent(id: mix.id, snapshot: missing, trigger: .schedule, now: muchLater.addingTimeInterval(3_600)); r.sync(e)
        }
        scenario("a risk manager guards a manual portfolio") { e, r in
            let ledger = try self.portfolio(&e, r)
            r.result("buy", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: Fx.now)); r.sync(e)
            var guardDraft = AgentDraft(name: "Guard", mode: .paper, spec: AgentTemplates.riskManager(), budget: 10_000, maxPositionPct: 100)
            guardDraft.attachToLedgerID = ledger.id
            let agent = try e.createAgent(guardDraft, now: Fx.now); r.sync(e)
            let tomorrow = Fx.now.addingTimeInterval(86_400)
            let closes = [Double](repeating: 100, count: 40) + [88]
            var snapshot = MarketSnapshot()
            snapshot.series[Fx.aapl.id] = Fx.series(Fx.aapl, closes: closes, days: Fx.usTradingDays(count: closes.count, before: tomorrow))
            snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 88, time: tomorrow)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: tomorrow); r.sync(e)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: tomorrow.addingTimeInterval(3_600)); r.sync(e)
        }
        scenario("sizing is cut to the limits and the cash") { e, r in
            var big = self.draft(universe: [Fx.aapl, Fx.msft], budget: 1_000)
            big.spec.sizing = Sizing(mode: .fixedNotional, value: 5_000)
            big.riskPolicy = RiskPolicy(maxOrderNotional: 800, maxPositionPct: 60, maxDailyNotional: 5_000, cooldownSeconds: 0)
            e.state.accountPolicy.maxSymbolExposurePct = 100
            let agent = try e.createAgent(big, now: Fx.now); r.sync(e)
            var snapshot = self.bullish()
            let msft = self.bullish(Fx.msft)
            snapshot.series[Fx.msft.id] = msft.series[Fx.msft.id]
            snapshot.quotes[Fx.msft.id] = msft.quotes[Fx.msft.id]
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
        }
        scenario("a crypto agent on hourly bars") { e, r in
            var spec = Fx.aboveAverageSpec([Fx.btc])
            spec.timeframe = .hour
            let cryptoDraft = AgentDraft(name: "Coin", mode: .paper, spec: spec, budget: 5_000, maxPositionPct: 20, reviewEachPaperTrade: true)
            let agent = try e.createAgent(cryptoDraft, now: Fx.now); r.sync(e)
            let closes = Fx.risingCloses(base: 60_000, step: 400)
            let hours = (1...closes.count).reversed().map { Fx.now.addingTimeInterval(-Double($0) * 3_600) }
            var snapshot = MarketSnapshot()
            snapshot.series[Fx.btc.id] = BarSeries(instrument: Fx.btc, timeframe: .hour, bars: Fx.dailyBars(closes: closes, days: hours, volume: 250),
                                                   provenance: .fixture("test"), fetchedAt: Fx.now)
            snapshot.quotes[Fx.btc.id] = Fx.quote(Fx.btc, last: closes.last!, spreadBps: 6, time: Fx.now)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now); r.sync(e)
            // An hourly agent's liquidity figures come from daily bars the host supplies.
            e.ingest(quotes: [], stats: [Fx.btc.id: InstrumentStats(averageDollarVolume: 2e9, dailyVolatilityPct: 3.5)], now: Fx.now.addingTimeInterval(30)); r.sync(e)
            let later = Fx.now.addingTimeInterval(60)
            snapshot.quotes[Fx.btc.id] = Fx.quote(Fx.btc, last: closes.last!, spreadBps: 6, time: later)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: later); r.sync(e)
            if let proposal = e.state.pendingProposals.first {
                r.result("approve", try e.approveProposal(id: proposal.id, now: later.addingTimeInterval(30))); r.sync(e)
            }
        }
        scenario("one venue's volume is not the asset's liquidity") { e, r in
            let coin = AgentDraft(name: "Coin", mode: .paper, spec: Fx.aboveAverageSpec([Fx.btc]), budget: 5_000, maxPositionPct: 10)
            let agent = try e.createAgent(coin, now: Fx.now); r.sync(e)
            let closes = Fx.risingCloses().map { $0 * 500 }
            var snapshot = MarketSnapshot()
            snapshot.series[Fx.btc.id] = BarSeries(instrument: Fx.btc, timeframe: .day,
                                                   bars: Fx.dailyBars(closes: closes, days: Fx.cryptoDays(count: closes.count), volume: 0.09),
                                                   provenance: .fixture("test"), fetchedAt: Fx.now, volumeIsMarketWide: false)
            snapshot.quotes[Fx.btc.id] = Fx.quote(Fx.btc, last: closes.last!, spreadBps: 4)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: Fx.now); r.sync(e)
            r.note("stats without a market-wide figure", J(e.state.stats))
            snapshot.dollarVolume[Fx.btc.id] = 25_000_000_000
            let later = Fx.now.addingTimeInterval(600)
            snapshot.quotes[Fx.btc.id] = Fx.quote(Fx.btc, last: closes.last!, spreadBps: 4, time: later)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: later); r.sync(e)
            r.note("stats with one", J(e.state.stats))
            // The figure doesn't outlive the data it came with.
            snapshot.dollarVolume = [:]
            let muchLater = later.addingTimeInterval(3_600)
            snapshot.quotes[Fx.btc.id] = Fx.quote(Fx.btc, last: closes.last!, spreadBps: 4, time: muchLater)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: muchLater); r.sync(e)
            r.note("stats after it is gone", J(e.state.stats))
        }
        scenario("Tokyo: lots of 100 and a lunch break") { e, r in
            let toyota = Instrument.listed("7203", name: "Toyota Motor", on: .tse)
            let tokyoNow = Fx.date("2026-11-10T01:00:00Z")
            let ledger = try e.createPaperPortfolio(name: "Japan", startingCash: 5_000_000, currency: "JPY", now: tokyoNow); r.sync(e)
            e.ingest(quotes: [Fx.quote(toyota, last: 2_800, time: tokyoNow)],
                     stats: [toyota.id: InstrumentStats(averageDollarVolume: 1e11, dailyVolatilityPct: 1.5)], now: tokyoNow); r.sync(e)
            r.result("odd lot", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: ledger.id, instrument: toyota, side: .buy, quantity: 150), now: tokyoNow)); r.sync(e)
            let byAmount = OrderRequest(clientOrderID: "m-2", ledgerID: ledger.id, instrument: toyota, side: .buy, notional: 700_000)
            r.preview("preview by amount", e.preview(byAmount, now: tokyoNow))
            r.result("by amount", e.submit(byAmount, now: tokyoNow)); r.sync(e)
            let lunch = Fx.date("2026-11-10T03:00:00Z")
            e.ingest(quotes: [Fx.quote(toyota, last: 2_810, time: lunch)], now: lunch); r.sync(e)
            let waiting = OrderRequest(clientOrderID: "m-3", ledgerID: ledger.id, instrument: toyota, side: .buy, quantity: 100)
            r.preview("preview at lunch", e.preview(waiting, now: lunch))
            r.result("at lunch", e.submit(waiting, now: lunch)); r.sync(e)
            let afternoon = Fx.date("2026-11-10T03:31:00Z")
            e.ingest(quotes: [Fx.quote(toyota, last: 2_815, time: afternoon)], now: afternoon); r.sync(e)
            r.result("sell a lot", e.submit(OrderRequest(clientOrderID: "m-4", ledgerID: ledger.id, instrument: toyota, side: .sell, quantity: 100),
                                            now: afternoon.addingTimeInterval(60))); r.sync(e)
        }
        scenario("a pound portfolio can't buy a yen share") { e, r in
            let pounds = try e.createPaperPortfolio(name: "UK", startingCash: 10_000, currency: "GBP", now: Fx.now); r.sync(e)
            let sony = Instrument.listed("6758", on: .tse)
            e.ingest(quotes: [Fx.quote(sony, last: 3_500)], now: Fx.now); r.sync(e)
            r.result("yen share", e.submit(OrderRequest(clientOrderID: "m-1", ledgerID: pounds.id, instrument: sony, side: .buy, quantity: 100), now: Fx.now)); r.sync(e)
        }
        scenario("a UK agent runs end to end in pounds") { e, r in
            let shell = Instrument.listed("SHEL", name: "Shell", on: .lse)
            let londonNow = Fx.date("2026-11-10T11:00:00Z")
            let agent = try e.createAgent(AgentDraft(name: "UK trend", mode: .paper, spec: Fx.aboveAverageSpec([shell]), budget: 10_000, maxPositionPct: 10),
                                          now: londonNow); r.sync(e)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Europe/London")!
            var days: [Date] = []
            var day = cal.startOfDay(for: londonNow)
            while days.count < 60 {
                day = cal.date(byAdding: .day, value: -1, to: day)!
                if MarketCalendar.standard.isTradingDay(.lse, day) { days.append(day.addingTimeInterval(8 * 3_600)) }
            }
            let closes = Fx.risingCloses().map { $0 * 0.27 }
            var snapshot = MarketSnapshot()
            snapshot.series[shell.id] = Fx.series(shell, closes: closes, days: days.reversed())
            snapshot.quotes[shell.id] = Fx.quote(shell, last: closes.last!, time: londonNow)
            e.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: londonNow); r.sync(e)
        }
        scenario("a backtest is noted in the audit trail") { e, r in
            let agent = try e.createAgent(self.draft(), now: Fx.now); r.sync(e)
            e.noteBacktest(title: "Above average", summary: "+12.4% over 2 years, 31 trades.", agentID: agent.id,
                           details: ["trades": "31", "returnPct": "12.4"], now: Fx.now.addingTimeInterval(60)); r.sync(e)
            e.noteBacktest(title: "Momentum", summary: "No trades.", actor: .copilot, now: Fx.now.addingTimeInterval(120)); r.sync(e)
        }
        return list
    }

    func testEngineScenarioVectors() throws {
        var out: [Any] = []
        for scenario in scenarios() {
            var engine = scenario.fixtures ? Fx.engine() : TradingEngine()
            let recorder = Recorder()
            try scenario.run(&engine, recorder)
            out.append(["name": scenario.name, "allowFixtureData": scenario.fixtures, "end": recorder.dump(&engine)] as [String: Any])
        }
        try Vectors.check("engine", ["scenarios": out, "fixtureNow": ms(Fx.now)])
    }
}
