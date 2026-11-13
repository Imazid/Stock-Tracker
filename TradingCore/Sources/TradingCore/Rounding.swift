import Foundation

/// One place for every rounding rule, so the phone and the server round the same way.
/// (The server mirrors these functions; shared test vectors keep the two in step.)
public enum Rounding {
    /// Half away from zero at `places` decimal places.
    public static func round(_ x: Double, places: Int) -> Double {
        guard x.isFinite else { return x }
        let m = pow(10.0, Double(places))
        return (x * m).rounded(.toNearestOrAwayFromZero) / m
    }

    /// Cash amounts are kept to the cent.
    public static func money(_ x: Double) -> Double { round(x, places: 2) }

    /// Decimal places implied by an increment (0.01 → 2, 0.00000001 → 8, 1 → 0).
    public static func decimals(for increment: Double) -> Int {
        guard increment > 0, increment < 1 else { return 0 }
        var places = 0
        var value = increment
        while places < 10, abs(value - value.rounded()) > 1e-9 {
            value *= 10
            places += 1
        }
        return places
    }

    /// The largest multiple of `increment` that is not above `x`.
    /// The small tolerance stops 0.3 / 0.1 (2.9999999999999996) flooring to 2.
    public static func floor(_ x: Double, increment: Double) -> Double {
        guard increment > 0, x.isFinite else { return x }
        let steps = (x / increment + 1e-9).rounded(.down)
        return round(steps * increment, places: decimals(for: increment))
    }

    /// The nearest multiple of `increment`.
    public static func nearest(_ x: Double, increment: Double) -> Double {
        guard increment > 0, x.isFinite else { return x }
        let steps = (x / increment).rounded(.toNearestOrAwayFromZero)
        return round(steps * increment, places: decimals(for: increment))
    }

    /// Whether `x` sits on the increment grid.
    public static func isMultiple(_ x: Double, of increment: Double) -> Bool {
        guard increment > 0 else { return true }
        return abs(nearest(x, increment: increment) - x) <= increment * 1e-6
    }

    /// A plain decimal string at the increment's precision, for provider payloads
    /// ("0.00012300", never "1.23e-4").
    public static func string(_ x: Double, increment: Double) -> String {
        String(format: "%.\(decimals(for: increment))f", x)
    }
}
