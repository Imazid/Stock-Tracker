import Foundation

/// Extracts only explicit assumptions from an ownership or dilution question.
public struct PrivateScenarioQuestion: Equatable, Sendable {
    public let investment: Decimal?
    public let existingOwnership: Decimal?
    public let postMoney: Decimal?
    public let newCapital: Decimal?
    public let currency: String?
    public let calculatesDilution: Bool

    public var initialOwnership: Decimal? {
        if calculatesDilution { return existingOwnership }
        guard let investment, let postMoney else { return nil }
        return PrivateMath.ownership(investment: investment, postMoney: postMoney,
                                     nextRoundPostMoney: nil, nextRoundRaise: nil)
    }

    public var ownershipAfterRound: Decimal? {
        guard calculatesDilution, let existingOwnership, let newCapital, let postMoney else { return nil }
        return PrivateMath.dilutedOwnership(existingOwnership, newCapital: newCapital, postMoney: postMoney)
    }

    public init?(_ question: String) {
        let text = question.lowercased().replacingOccurrences(of: "[‑–−]", with: "-", options: .regularExpression)
        let dilution = text.range(of: #"\b(?:dilut\w*|ownership after (?:the |a |another )?(?:funding |financing )?round)\b"#,
                                  options: .regularExpression) != nil
        let ownership = text.range(of: #"\b(?:ownership|equity stake|stake would|(?:what|how much) (?:equity|stake))\b"#,
                                   options: .regularExpression) != nil
        guard dilution || ownership && text.range(of: #"\b(?:invest\w*|valuation|post-money|pre-money)\b"#,
                                                   options: .regularExpression) != nil else { return nil }
        calculatesDilution = dilution

        let percent = #"(?<![\w,.\-])([0-9]{1,3}(?:\.[0-9]{1,8})?)\s*(?:%|percent\b)"#
        let share = Self.uniqueValue(in: text, patterns: [
            percent + #"\s+(?:equity\s+)?(?:ownership|stake)\b"#,
            #"\b(?:own|hold|(?:existing |starting |initial )?(?:ownership|stake)(?: of| is)?|dilution from)\s+"# + percent,
        ])
        existingOwnership = dilution ? share.flatMap { $0 <= 100 ? $0 / 100 : nil } : nil
        let post = Self.money(in: text, label: #"post[ -]money(?:\s+valuation)?"#)
        let pre = Self.money(in: text, label: #"pre[ -]money(?:\s+valuation)?"#)
        let capital = Self.money(in: text, label: #"(?:new (?:capital|money|funding)|(?:the |next )?(?:round )?rais(?:e|es|ed|ing))"#)
        var stake = Self.money(in: text, label: #"(?:invest(?:s|ed|ing|ment)?(?:\s+amount)?)"#)
        if stake.value == nil, !stake.ambiguous {
            stake = Self.money(in: text, label: #"(?:for|with)"#, matchBeforeLabel: false)
        }
        let relevant = dilution ? [post, pre, capital] : [post, pre, capital, stake]
        var currencies = Set(relevant.flatMap(\.currencies))
        if currencies.contains("$") && !currencies.isDisjoint(with: ["aud", "usd", "nzd", "cad", "sgd", "hkd"]) {
            currencies.remove("$")
        }
        let hasRange = text.range(of: #"[0-9]\s*(?:(?:k|m|mn|bn|thousand|million|billion)\b\s*)?(?:-|\bto\b|\bor\b)\s*[$£€¥]?[0-9]"#,
                                  options: .regularExpression) != nil
        guard currencies.count <= 1, !hasRange, !relevant.contains(where: \.ambiguous) else {
            investment = nil
            newCapital = nil
            postMoney = nil
            currency = nil
            return
        }
        currency = currencies.first.flatMap { $0 == "$" ? nil : $0.uppercased() }
        investment = dilution ? nil : stake.value.flatMap { $0 > 0 ? $0 : nil }
        newCapital = dilution ? capital.value : nil
        if let before = pre.value, let raise = capital.value, before > 0, raise >= 0 {
            let after = before + raise
            postMoney = (post.value == nil || post.value == after) && after < 1_000_000_000_000_000 ? after : nil
        } else {
            postMoney = post.value.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    private static let codes = "aud|usd|nzd|cad|gbp|eur|jpy|chf|sgd|hkd"
    private static let amount = #"(?<![\w.,$£€¥\-])(?:("# + codes + #"|a\$|us\$|\$|£|€|¥)\s*)?"# +
        #"([0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,8})?|[0-9]{1,15}(?:\.[0-9]{1,8})?)"# +
        #"(?:\s*(thousand|million|billion|k|m|mn|bn))?(?![\w%]|[,.][0-9])(?:\s+\b("# + codes + #")\b)?"#

    private static func money(in text: String, label: String,
                              matchBeforeLabel: Bool = true) -> (value: Decimal?, currencies: Set<String>, ambiguous: Bool) {
        let prefix = #"\b"# + label + #"\b\s*(?:(?:of|is)\s+|=\s*)?"# + amount
        let suffix = amount + #"\s+(?:in\s+|as\s+|at\s+)?"# + label + #"\b"#
        var values = Set<Decimal>()
        var currencies = Set<String>()
        for pattern in matchBeforeLabel ? [prefix, suffix] : [prefix] {
            for groups in captures(in: text, pattern: pattern) {
                guard let number = Decimal(string: groups[1].replacingOccurrences(of: ",", with: ""),
                                           locale: Locale(identifier: "en_US_POSIX")) else { continue }
                let scale: Decimal
                switch groups[2] {
                case "k", "thousand": scale = 1_000
                case "m", "mn", "million": scale = 1_000_000
                case "bn", "billion": scale = 1_000_000_000
                default: scale = 1
                }
                let value = number * scale
                guard value < 1_000_000_000_000_000 else { continue }
                values.insert(value)
                switch groups[0] {
                case "": break
                case "a$": currencies.insert("aud")
                case "us$": currencies.insert("usd")
                case "£": currencies.insert("gbp")
                case "€": currencies.insert("eur")
                case "¥": currencies.insert("jpy")
                default: currencies.insert(groups[0])
                }
                if !groups[3].isEmpty { currencies.insert(groups[3]) }
            }
        }
        return (values.first, currencies, values.count > 1)
    }

    private static func uniqueValue(in text: String, patterns: [String]) -> Decimal? {
        let values = Set(patterns.flatMap { captures(in: text, pattern: $0) }.compactMap {
            Decimal(string: $0[0], locale: Locale(identifier: "en_US_POSIX"))
        })
        return values.count == 1 ? values.first : nil
    }

    private static func captures(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
