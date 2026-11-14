import Foundation

/// Reads explicit comparisons from buy and sell clauses. A clause is accepted only
/// when every part can be represented by the strategy engine.
struct DescribedStrategyRules {
    var entry: Condition?
    var exit: Condition?
    var notes: [String] = []
    private var usedDefaultRSI = false

    static func parse(_ text: String) -> Self? {
        let hasTimedRule = text.range(of: #"\b(?:rsi|relative strength index|ema|sma|(?:moving )?average|macd|bollinger|price|volume|close)\b"#, options: .regularExpression) != nil
        let hasDirection = text.range(of: #"\b(?:when|if|above|below|under|over|exceeds|crosses|once)\b|[<>≤≥]"#, options: .regularExpression) != nil
        // An undirected shorthand such as "10-day EMA crosses the 30-day EMA"
        // is handled by the named crossover template.
        let onlyUndirectedCross = text.range(of: #"\bcross(?:es|over)?\b"#, options: .regularExpression) != nil
            && text.range(of: #"\b(?:above|below|under|over|rsi|relative strength index)\b|[<>]"#, options: .regularExpression) == nil
        guard hasTimedRule, hasDirection, !onlyUndirectedCross else { return nil }

        let marker = #"\b(buy|sell|enter|exit)\b[^,;.!?\n]*?\b(?:when|if|once|on)\s+"#
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: marker) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var result = Self()
        var seen = Set<String>()
        for (index, match) in matches.enumerated() {
            let side = ns.substring(with: match.range(at: 1))
            let isBuy = side == "buy" || side == "enter"
            let key = isBuy ? "buy" : "sell"
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let fragment = ns.substring(with: NSRange(location: start, length: end - start))
            let clause = trimClause(fragment)
            let repeated = !seen.insert(key).inserted
            let opposite = clause.range(of: #"^(?:the )?(?:opposite|reverse) cross(?:over)?$"#, options: .regularExpression) != nil
            let rule = repeated ? nil : opposite && !isBuy ? result.entry.flatMap(reverseCross) : result.readGroup(clause)
            // An unread explicit exit must be repaired even if the draft also
            // includes a stop. An empty group stays visible in the rule editor.
            if isBuy { result.entry = rule } else { result.exit = rule ?? .all([]) }
            if rule == nil {
                let note = "Review the \(key) condition. The full comparison could not be read."
                if !result.notes.contains(note) { result.notes.append(note) }
            }
        }
        if result.usedDefaultRSI { result.notes.append("Used 14 bars wherever the RSI period was omitted.") }
        return result
    }

    private static func trimClause(_ raw: String) -> String {
        let end = #"(?:,\s*(?!\s*(?:and|or)\b)|[;\n!?]|\.(?!\d)|\b(?:with (?:a |an )?(?=\$)|with (?:a |an )?(?:stop loss|take profit)|(?:and )?ask me|for paper trading|in (?:a )?paper (?:portfolio|account)|every (?:hour|day|week|month|\d+\s*min)|once a day|hourly|daily|called|named)\b)"#
        var text = raw
        if let first = text.range(of: end, options: .regularExpression) { text = String(text[..<first.lowerBound]) }
        text = text.replacingOccurrences(of: #",\s*(?=(?:and|or)\b)"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+(?:and|then)$"#, with: "", options: .regularExpression)
    }

    private static func reverseCross(_ rule: Condition) -> Condition? {
        guard rule.op == .crossesAbove || rule.op == .crossesBelow else { return nil }
        guard let left = rule.left, let right = rule.right else { return nil }
        return rule.op == .crossesAbove ? .crossesBelow(left, right) : .crossesAbove(left, right)
    }

    // Match ordinary comparison precedence: "A or B and C" uses A or (B and C).
    private mutating func readGroup(_ text: String) -> Condition? {
        let groups = text.replacingOccurrences(of: #"\s+or\s+"#, with: "\u{1F}", options: .regularExpression).components(separatedBy: "\u{1F}")
        guard groups.count <= 8 else { return nil }
        var alternatives: [Condition] = []
        for part in groups {
            let comparisons = part.replacingOccurrences(of: #"\s+and\s+"#, with: "\u{1F}", options: .regularExpression).components(separatedBy: "\u{1F}")
            guard comparisons.count <= 8 else { return nil }
            let leaves = comparisons.compactMap { readComparison($0) }
            guard leaves.count == comparisons.count, let first = leaves.first else { return nil }
            alternatives.append(leaves.count == 1 ? first : .all(leaves))
        }
        guard let first = alternatives.first else { return nil }
        return alternatives.count == 1 ? first : .any(alternatives)
    }

    private mutating func readComparison(_ raw: String) -> Condition? {
        let pattern = #"\s*(\bcross(?:es)?\s+(?:back\s+)?(?:above|below|under|over)|\b(?:is\s+)?(?:above|below|under|over)|\b(?:drops?|falls?|goes|rises?|moves?|breaks?)\s+(?:above|below|under|over)|\bexceeds\b|[<>])\s*"#
        guard let span = raw.range(of: pattern, options: .regularExpression),
              let left = readOperand(String(raw[..<span.lowerBound])),
              let right = readOperand(String(raw[span.upperBound...])), left.kind != .constant else { return nil }
        if left.kind == .rsi, right.kind == .constant, let value = right.value, !(0...100).contains(value) { return nil }
        let relation = raw[span].trimmingCharacters(in: .whitespacesAndNewlines)
        let above = relation == ">" || relation == "exceeds" || relation.hasSuffix("above") || relation.hasSuffix("over")
        if relation.hasPrefix("cross") { return above ? .crossesAbove(left, right) : .crossesBelow(left, right) }
        return above ? .above(left, right) : .below(left, right)
    }

    private mutating func readOperand(_ raw: String) -> Operand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:(?:the|its)\s+)+"#, with: "", options: .regularExpression)
        if text.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil,
           let value = Double(text), value.isFinite { return .constant(value) }
        if ["price", "close", "closing price"].contains(text) { return .close }
        if let field = PriceField(rawValue: text) { return .price(field) }
        if text == "volume" { return .volume }
        if let match = Self.captures(#"^(?:rsi|relative strength index)(?:\s*\((\d+)\)|\s+(\d+))?$"#, in: text) {
            let periodText = match.compactMap { $0 }.first
            if periodText == nil { usedDefaultRSI = true }
            guard let period = Int(periodText ?? "14"), (2...StrategyValidator.maxPeriod).contains(period) else { return nil }
            return .rsi(period)
        }
        if let match = Self.captures(#"^(\d+)[ -]?(?:day|hour|bar|period)s?\s+(ema|sma|(?:exponential |simple )?(?:moving )?average)$"#, in: text)
            ?? Self.captures(#"^(\d+)\s*(ema|sma)$"#, in: text),
            let number = match[0], let period = Int(number), let kind = match[1], (2...StrategyValidator.maxPeriod).contains(period) {
            return kind == "ema" || kind.hasPrefix("exponential") ? .ema(period) : .sma(period)
        }
        return nil
    }

    private static func captures(_ pattern: String, in text: String) -> [String?]? {
        let ns = text as NSString
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<match.numberOfRanges).map {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}
