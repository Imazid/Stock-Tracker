import Foundation

/// Regular trading sessions. Crypto never closes; each stock exchange follows its own
/// calendar in its own time zone, and some Asian exchanges stop for lunch.
///
/// Holiday tables come from each exchange's published calendar (US and ASX here, the
/// others in `ExchangeHolidays`) and need extending each year. Outside the years a table
/// covers, the calendar still knows weekends and weekly hours but not holidays —
/// `coversDate` says which. An unlisted holiday fails safe: no fresh quotes arrive, the
/// risk engine refuses stale prices, and nothing trades.
public struct MarketCalendar: Sendable {
    public static let standard = MarketCalendar()

    public init() {}

    private struct Hours {
        let timeZone: TimeZone
        /// Trading segments in minutes after local midnight; two when there's a lunch break.
        let segments: [(open: Int, close: Int)]
        let holidays: Set<String>
        /// Early-close days → the minute trading ends that day.
        let earlyCloses: [String: Int]
        let covered: ClosedRange<Int>?
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private static func international(_ venue: Venue, _ zone: String, _ segments: [(Int, Int)]) -> Hours {
        Hours(timeZone: TimeZone(identifier: zone)!,
              segments: segments.map { (open: $0.0, close: $0.1) },
              holidays: ExchangeHolidays.closures[venue.rawValue] ?? [],
              earlyCloses: (ExchangeHolidays.earlyCloses[venue.rawValue] ?? [:]).compactMapValues(minutes),
              covered: ExchangeHolidays.coveredYears[venue.rawValue])
    }

    private static let table: [Venue: Hours] = {
        var t: [Venue: Hours] = [:]
        t[.us] = Hours(
            timeZone: TimeZone(identifier: "America/New_York")!,
            segments: [(open: 9 * 60 + 30, close: 16 * 60)],
            holidays: [
                "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19",
                "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
                "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18",
                "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24"
            ],
            earlyCloses: ["2026-11-27": 13 * 60, "2026-12-24": 13 * 60, "2027-11-26": 13 * 60],
            covered: 2026...2027)
        t[.asx] = Hours(
            timeZone: TimeZone(identifier: "Australia/Sydney")!,
            segments: [(open: 10 * 60, close: 16 * 60)],
            holidays: [
                "2026-01-01", "2026-01-26", "2026-04-03", "2026-04-06", "2026-06-08", "2026-12-25", "2026-12-28",
                "2027-01-01", "2027-01-26", "2027-03-26", "2027-03-29", "2027-06-14", "2027-12-27", "2027-12-28"
            ],
            earlyCloses: ["2026-12-24": 14 * 60 + 10, "2026-12-31": 14 * 60 + 10,
                          "2027-12-24": 14 * 60 + 10, "2027-12-31": 14 * 60 + 10],
            covered: 2026...2027)
        // Continuous trading through the closing auction, local time.
        t[.lse] = international(.lse, "Europe/London", [(8 * 60, 16 * 60 + 35)])
        t[.xetra] = international(.xetra, "Europe/Berlin", [(9 * 60, 17 * 60 + 35)])
        t[.euronextParis] = international(.euronextParis, "Europe/Paris", [(9 * 60, 17 * 60 + 35)])
        t[.euronextAmsterdam] = international(.euronextAmsterdam, "Europe/Amsterdam", [(9 * 60, 17 * 60 + 35)])
        t[.six] = international(.six, "Europe/Zurich", [(9 * 60, 17 * 60 + 30)])
        t[.tse] = international(.tse, "Asia/Tokyo", [(9 * 60, 11 * 60 + 30), (12 * 60 + 30, 15 * 60 + 30)])
        t[.hkex] = international(.hkex, "Asia/Hong_Kong", [(9 * 60 + 30, 12 * 60), (13 * 60, 16 * 60 + 10)])
        t[.sgx] = international(.sgx, "Asia/Singapore", [(9 * 60, 12 * 60), (13 * 60, 17 * 60 + 6)])
        t[.krx] = international(.krx, "Asia/Seoul", [(9 * 60, 15 * 60 + 30)])
        t[.nse] = international(.nse, "Asia/Kolkata", [(9 * 60 + 15, 15 * 60 + 30)])
        return t
    }()

    /// Years the US and ASX holiday tables cover. Other venues: see `coveredYears(for:)`.
    public static let coveredYears = 2026...2027

    private func hours(_ venue: Venue) -> Hours? { Self.table[venue] }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// The exchange's own time zone (UTC for crypto).
    public func timeZone(_ venue: Venue) -> TimeZone {
        hours(venue)?.timeZone ?? TimeZone(identifier: "UTC")!
    }

    /// First open and last close of a normal day, in minutes after local midnight; nil for crypto.
    public func regularHours(_ venue: Venue) -> (timeZone: TimeZone, open: Int, close: Int)? {
        guard let h = hours(venue), let first = h.segments.first, let last = h.segments.last else { return nil }
        return (h.timeZone, first.open, last.close)
    }

    /// Whether trading stops for lunch on a normal day.
    public func hasLunchBreak(_ venue: Venue) -> Bool { (hours(venue)?.segments.count ?? 1) > 1 }

    /// The years this venue's holiday table is complete for; nil when there is none.
    public func coveredYears(for venue: Venue) -> ClosedRange<Int>? { hours(venue)?.covered }

    /// "yyyy-MM-dd" in the venue's own time zone (UTC for crypto).
    public func dayKey(_ venue: Venue, _ date: Date) -> String {
        let cal = calendar(timeZone(venue))
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether the holiday tables cover this date. Outside them, equity hours are a best guess.
    public func coversDate(_ venue: Venue, _ date: Date) -> Bool {
        guard let h = hours(venue) else { return true }
        guard let covered = h.covered else { return false }
        return covered.contains(calendar(h.timeZone).component(.year, from: date))
    }

    public func isTradingDay(_ venue: Venue, _ date: Date) -> Bool {
        guard let h = hours(venue) else { return true }
        let weekday = calendar(h.timeZone).component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        return !h.holidays.contains(dayKey(venue, date))
    }

    /// The trading segments on the venue-local day containing `date`, shortened on an early
    /// close; empty when the venue is shut that day. Crypto returns the whole UTC day.
    public func segments(_ venue: Venue, on date: Date) -> [DateInterval] {
        guard let h = hours(venue) else {
            let start = calendar(TimeZone(identifier: "UTC")!).startOfDay(for: date)
            return [DateInterval(start: start, duration: 86_400)]
        }
        guard isTradingDay(venue, date) else { return [] }
        let cal = calendar(h.timeZone)
        let day = cal.startOfDay(for: date)
        let cutoff = h.earlyCloses[dayKey(venue, date)]
        var out: [DateInterval] = []
        for segment in h.segments {
            let close = cutoff.map { min(segment.close, $0) } ?? segment.close
            guard close > segment.open else { continue }
            // Built from components so a daylight-saving change on the day can't shift the times.
            guard let start = cal.date(bySettingHour: segment.open / 60, minute: segment.open % 60, second: 0, of: day),
                  let end = cal.date(bySettingHour: close / 60, minute: close % 60, second: 0, of: day) else { continue }
            out.append(DateInterval(start: start, end: end))
        }
        return out
    }

    /// The regular session on the venue-local day containing `date`, from the first open to
    /// the last close (lunch included); nil when the venue is shut that day.
    public func session(_ venue: Venue, containing date: Date) -> DateInterval? {
        let parts = segments(venue, on: date)
        guard let first = parts.first, let last = parts.last else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }

    public func isOpen(_ venue: Venue, at date: Date) -> Bool {
        guard venue != .crypto else { return true }
        return segments(venue, on: date).contains { date >= $0.start && date < $0.end }
    }

    /// The next time trading starts strictly after `date` — after lunch counts (nil for crypto).
    public func nextOpen(_ venue: Venue, after date: Date) -> Date? {
        guard let h = hours(venue) else { return nil }
        let cal = calendar(h.timeZone)
        for offset in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date) else { continue }
            if let start = segments(venue, on: day).first(where: { $0.start > date })?.start { return start }
        }
        return nil
    }

    /// When the day's trading ends, for the session open at `date`, or the next one if shut.
    public func nextClose(_ venue: Venue, after date: Date) -> Date? {
        guard let h = hours(venue) else { return nil }
        let cal = calendar(h.timeZone)
        for offset in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date),
                  let s = session(venue, containing: day) else { continue }
            if s.end > date { return s.end }
        }
        return nil
    }

    /// A bar is complete once its period has ended. Signals only ever read complete bars:
    /// today's daily bar keeps changing until the close, and acting on it would be
    /// trading on a price that doesn't exist yet.
    public func isBarComplete(_ bar: Bar, timeframe: Timeframe, venue: Venue, now: Date) -> Bool {
        switch timeframe {
        case .hour:
            return now >= bar.time.addingTimeInterval(timeframe.seconds)
        case .day:
            guard venue != .crypto else { return now >= bar.time.addingTimeInterval(86_400) }
            // Daily equity bars are stamped on their session day (midnight or the open, exchange time).
            guard let s = session(venue, containing: bar.time) else {
                return now >= bar.time.addingTimeInterval(86_400)
            }
            return now >= s.end
        }
    }

    /// The completed bars of a series, oldest first.
    public func completedBars(_ series: BarSeries, now: Date) -> [Bar] {
        var bars = series.bars
        while let last = bars.last,
              !isBarComplete(last, timeframe: series.timeframe, venue: series.instrument.venue, now: now) {
            bars.removeLast()
        }
        return bars
    }

    /// Trading days between two dates, used to judge whether a series has gone stale.
    public func tradingDays(_ venue: Venue, from start: Date, to end: Date) -> Int {
        guard end > start else { return 0 }
        guard let h = hours(venue) else { return Int(end.timeIntervalSince(start) / 86_400) }
        let cal = calendar(h.timeZone)
        var count = 0
        var day = cal.startOfDay(for: start)
        let last = cal.startOfDay(for: end)
        while day < last, count < 400 {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            if isTradingDay(venue, day) { count += 1 }
        }
        return count
    }
}
