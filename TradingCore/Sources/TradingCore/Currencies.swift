import Foundation

/// What the app needs to know about each currency a practice portfolio can hold.
public enum Currencies {
    public static let supported = ["USD", "AUD", "GBP", "EUR", "CHF", "JPY", "HKD", "SGD", "KRW", "INR"]

    public static func isSupported(_ code: String) -> Bool { supported.contains(code) }

    /// The prefix used in amounts. USD keeps a bare "$" here; the app's own formatter
    /// prints "US$" where both markets appear together.
    public static func symbol(_ code: String) -> String {
        switch code {
        case "USD": return "$"
        case "AUD": return "A$"
        case "GBP": return "£"
        case "EUR": return "€"
        case "CHF": return "CHF "
        case "JPY": return "¥"
        case "HKD": return "HK$"
        case "SGD": return "S$"
        case "KRW": return "₩"
        case "INR": return "₹"
        default: return code + " "
        }
    }

    /// Minor-unit decimals used for cash amounts.
    public static func decimals(_ code: String) -> Int {
        code == "JPY" || code == "KRW" ? 0 : 2
    }

    /// The time zone a portfolio in this currency counts its trading day in.
    public static func timeZone(_ code: String) -> TimeZone {
        let identifier: String
        switch code {
        case "AUD": identifier = "Australia/Sydney"
        case "GBP": identifier = "Europe/London"
        case "EUR": identifier = "Europe/Paris"
        case "CHF": identifier = "Europe/Zurich"
        case "JPY": identifier = "Asia/Tokyo"
        case "HKD": identifier = "Asia/Hong_Kong"
        case "SGD": identifier = "Asia/Singapore"
        case "KRW": identifier = "Asia/Seoul"
        case "INR": identifier = "Asia/Kolkata"
        default: identifier = "America/New_York"
        }
        return TimeZone(identifier: identifier)!
    }

    /// Roughly how many units of the currency buy one US dollar. Used ONLY to scale defaults
    /// (a sensible starting budget, a liquidity floor) so they mean about the same everywhere.
    /// It never converts money: practice portfolios hold one currency and are never mixed.
    public static func roughUnitsPerUSD(_ code: String) -> Double {
        switch code {
        case "AUD": return 1.5
        case "GBP": return 0.8
        case "EUR", "CHF": return 0.9
        case "JPY": return 150
        case "HKD": return 7.8
        case "SGD": return 1.3
        case "KRW": return 1_400
        case "INR": return 85
        default: return 1
        }
    }

    /// A round multiplier for budget limits and suggestions (1 for the dollar-like currencies).
    static func budgetScale(_ code: String) -> Double {
        switch code {
        case "JPY": return 100
        case "HKD": return 10
        case "KRW": return 1_000
        case "INR": return 100
        default: return 1
        }
    }

    /// The smallest and largest practice budget allowed in this currency.
    public static func budgetRange(_ code: String) -> ClosedRange<Double> {
        let scale = budgetScale(code)
        return (100 * scale)...(10_000_000 * scale)
    }

    /// A starting budget large enough to buy a normal trading lot of a large company there.
    /// (Tokyo trades in 100-share units, so a yen budget needs to be bigger.)
    public static func defaultBudget(_ code: String) -> Double {
        code == "JPY" ? 5_000_000 : 10_000 * budgetScale(code)
    }

    /// Suggested starting balances for a new practice portfolio.
    public static func balanceChoices(_ code: String) -> [Double] {
        if code == "JPY" { return [1_000_000, 5_000_000, 10_000_000, 30_000_000] }
        let scale = budgetScale(code)
        return [5_000, 10_000, 25_000, 100_000].map { $0 * scale }
    }

    /// The smallest average daily traded value an agent may buy into: about US$1 million.
    public static func liquidityFloor(_ code: String) -> Double {
        let raw = 1_000_000 * roughUnitsPerUSD(code)
        let magnitude = pow(10, floor(log10(raw)))
        return (raw / magnitude).rounded() * magnitude
    }
}
