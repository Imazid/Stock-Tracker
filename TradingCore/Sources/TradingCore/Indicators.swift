import Foundation

/// Technical indicators over a price series. Every function returns one value per input
/// bar; the value at index `i` is computed only from bars `0...i`, so nothing here can
/// look ahead. `nil` means "not enough history yet".
public enum Indicators {

    public static func sma(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return out }
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { out[i] = sum / Double(period) }
        }
        return out
    }

    /// Exponential average seeded with the simple average of the first `period` values.
    public static func ema(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return out }
        let k = 2.0 / Double(period + 1)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = prev + k * (values[i] - prev)
            out[i] = prev
        }
        return out
    }

    /// Wilder's RSI. First value at index `period`.
    public static func rsi(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return out }
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let change = values[i] - values[i - 1]
            if change >= 0 { gain += change } else { loss -= change }
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        out[period] = rsiValue(avgGain, avgLoss)
        if values.count > period + 1 {
            for i in (period + 1)..<values.count {
                let change = values[i] - values[i - 1]
                avgGain = (avgGain * Double(period - 1) + max(change, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-change, 0)) / Double(period)
                out[i] = rsiValue(avgGain, avgLoss)
            }
        }
        return out
    }

    private static func rsiValue(_ avgGain: Double, _ avgLoss: Double) -> Double {
        if avgLoss == 0 { return avgGain == 0 ? 50 : 100 }
        let rs = avgGain / avgLoss
        return 100 - 100 / (1 + rs)
    }

    public struct MACD: Sendable {
        public let line: [Double?]
        public let signal: [Double?]
        public let histogram: [Double?]
    }

    public static func macd(_ values: [Double], fast: Int, slow: Int, signal: Int) -> MACD {
        let n = values.count
        var line = [Double?](repeating: nil, count: n)
        var signalLine = [Double?](repeating: nil, count: n)
        var histogram = [Double?](repeating: nil, count: n)
        guard fast > 0, slow > fast, signal > 0, n >= slow else {
            return MACD(line: line, signal: signalLine, histogram: histogram)
        }
        let fastEMA = ema(values, period: fast)
        let slowEMA = ema(values, period: slow)
        var defined: [Double] = []
        var firstIndex: Int?
        for i in 0..<n {
            if let f = fastEMA[i], let s = slowEMA[i] {
                line[i] = f - s
                defined.append(f - s)
                if firstIndex == nil { firstIndex = i }
            }
        }
        if let firstIndex {
            let sig = ema(defined, period: signal)
            for (offset, value) in sig.enumerated() {
                guard let value, let l = line[firstIndex + offset] else { continue }
                signalLine[firstIndex + offset] = value
                histogram[firstIndex + offset] = l - value
            }
        }
        return MACD(line: line, signal: signalLine, histogram: histogram)
    }

    public struct Bollinger: Sendable {
        public let upper: [Double?]
        public let middle: [Double?]
        public let lower: [Double?]
    }

    /// Bollinger Bands with the population standard deviation (the standard definition).
    public static func bollinger(_ values: [Double], period: Int, deviations: Double) -> Bollinger {
        let n = values.count
        let middle = sma(values, period: period)
        var upper = [Double?](repeating: nil, count: n)
        var lower = [Double?](repeating: nil, count: n)
        guard period > 0, n >= period else { return Bollinger(upper: upper, middle: middle, lower: lower) }
        for i in (period - 1)..<n {
            guard let mean = middle[i] else { continue }
            var sumSquares = 0.0
            for j in (i - period + 1)...i {
                let d = values[j] - mean
                sumSquares += d * d
            }
            let sd = (sumSquares / Double(period)).squareRoot()
            upper[i] = mean + deviations * sd
            lower[i] = mean - deviations * sd
        }
        return Bollinger(upper: upper, middle: middle, lower: lower)
    }

    /// Wilder's Average True Range. First value at index `period`.
    public static func atr(_ bars: [Bar], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: bars.count)
        guard period > 0, bars.count > period else { return out }
        var trueRanges = [Double](repeating: 0, count: bars.count)
        for i in 1..<bars.count {
            let prevClose = bars[i - 1].close
            trueRanges[i] = max(bars[i].high - bars[i].low,
                                abs(bars[i].high - prevClose),
                                abs(bars[i].low - prevClose))
        }
        var value = trueRanges[1...period].reduce(0, +) / Double(period)
        out[period] = value
        if bars.count > period + 1 {
            for i in (period + 1)..<bars.count {
                value = (value * Double(period - 1) + trueRanges[i]) / Double(period)
                out[i] = value
            }
        }
        return out
    }

    /// Highest value of the `period` bars *before* each bar (the bar itself is excluded,
    /// so "close above the prior 20-day high" is a real breakout test).
    public static func priorHighest(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return out }
        for i in period..<values.count {
            out[i] = values[(i - period)..<i].max()
        }
        return out
    }

    public static func priorLowest(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return out }
        for i in period..<values.count {
            out[i] = values[(i - period)..<i].min()
        }
        return out
    }

    /// Percent change over `period` bars.
    public static func rateOfChange(_ values: [Double], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return out }
        for i in period..<values.count where values[i - period] > 0 {
            out[i] = (values[i] / values[i - period] - 1) * 100
        }
        return out
    }
}
