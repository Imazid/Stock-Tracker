import Foundation

/// Regular trading sessions. Crypto never closes; US and ASX equities follow their
/// exchange calendars. Holiday tables match the app's market-status view and need
/// extending each year — after the last listed year the calendar still knows weekends
/// but not holidays, so `coversDate` says whether a date is inside the tables.
public struct MarketCalendar: Sendable {
    public static let standard = MarketCalendar()

    public init() {}

    private struct Hours {
        let timeZone: TimeZone
        let open: Int        // minutes after local midnight
        let close: Int
        let earlyClose: Int
        let holidays: Set<String>
        let earlyCloses: Set<String>
    }

    private static let us = Hours(
        timeZone: TimeZone(identifier: "America/New_York")!,
        open: 9 * 60 + 30, close: 16 * 60, earlyClose: 13 * 60,
        holidays: [
            "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19",
            "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
            "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18",
            "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24"
        ],
        earlyCloses: ["2026-11-27", "2026-12-24", "2027-11-26"]
    )

    private static let asx = Hours(
        timeZone: TimeZone(identifier: "Australia/Sydney")!,
        open: 10 * 60, close: 16 * 60, earlyClose: 14 * 60 + 10,
        holidays: [
            "2026-01-01", "2026-01-26", "2026-04-03", "2026-04-06", "2026-06-08", "2026-12-25", "2026-12-28",
            "2027-01-01", "2027-01-26", "2027-03-26", "2027-03-29", "2027-06-14", "2027-12-27", "2027-12-28"
        ],
        earlyCloses: ["2026-12-24", "2026-12-31", "2027-12-24", "2027-12-31"]
    )

    /// Years the holiday tables cover.
    public static let coveredYears = 2026...2027

    private func hours(_ venue: Venue) -> Hours? {
        switch venue {
        case .us: return Self.us
        case .asx: return Self.asx
        case .crypto: return nil
        }
    }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// "yyyy-MM-dd" in the venue's own time zone (UTC for crypto).
    public func dayKey(_ venue: Venue, _ date: Date) -> String {
        let cal = calendar(hours(venue)?.timeZone ?? TimeZone(identifier: "UTC")!)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether the holiday tables cover this date. Outside them, equity hours are a best guess.
    public func coversDate(_ venue: Venue, _ date: Date) -> Bool {
        guard let h = hours(venue) else { return true }
        let year = calendar(h.timeZone).component(.year, from: date)
        return Self.coveredYears.contains(year)
    }

    public func isTradingDay(_ venue: Venue, _ date: Date) -> Bool {
        guard let h = hours(venue) else { return true }
        let weekday = calendar(h.timeZone).component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        return !h.holidays.contains(dayKey(venue, date))
    }

    /// The regular session on the venue-local day containing `date`; nil when the venue is
    /// shut that day. Crypto returns the whole UTC day.
    public func session(_ venue: Venue, containing date: Date) -> DateInterval? {
        guard let h = hours(venue) else {
            let cal = calendar(TimeZone(identifier: "UTC")!)
            let start = cal.startOfDay(for: date)
            return DateInterval(start: start, duration: 86_400)
        }
        guard isTradingDay(venue, date) else { return nil }
        let cal = calendar(h.timeZone)
        let day = cal.startOfDay(for: date)
        let closeMinute = h.earlyCloses.contains(dayKey(venue, date)) ? h.earlyClose : h.close
        // Built from components so a daylight-saving change on the day can't shift the open.
        guard let open = cal.date(bySettingHour: h.open / 60, minute: h.open % 60, second: 0, of: day),
              let close = cal.date(bySettingHour: closeMinute / 60, minute: closeMinute % 60, second: 0, of: day)
        else { return nil }
        return DateInterval(start: open, end: close)
    }

    public func isOpen(_ venue: Venue, at date: Date) -> Bool {
        guard venue != .crypto else { return true }
        guard let s = session(venue, containing: date) else { return false }
        return date >= s.start && date < s.end
    }

    /// The next regular open strictly after `date` (nil for crypto, which is always open).
    public func nextOpen(_ venue: Venue, after date: Date) -> Date? {
        guard let h = hours(venue) else { return nil }
        let cal = calendar(h.timeZone)
        for offset in 0..<15 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date),
                  let s = session(venue, containing: day) else { continue }
            if s.start > date { return s.start }
        }
        return nil
    }

    /// When the session that is open at `date` ends, or the end of the next one if shut.
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
