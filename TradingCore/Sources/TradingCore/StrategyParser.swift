import Foundation

/// The result of reading a typed request such as "Create an agent that monitors technology
/// stocks … give it a $5,000 paper portfolio and limit each position to 10%".
public struct ParsedAgentRequest: Sendable {
    public var draft: AgentDraft
    /// What was recognised in the request, in plain words.
    public var understood: [String]
    /// Defaults that were filled in because the request didn't say.
    public var assumptions: [String]
    /// Tickers that looked like symbols but aren't known; the person can add them by search.
    public var unrecognisedSymbols: [String]
}

/// Turns a typed request into an editable agent draft using fixed rules — no model call.
/// It works offline and always gives the same answer for the same words. When an AI model
/// drafts a strategy instead, its JSON goes through `decodeDraft` and the same validator.
/// Either way the result is only a draft: a person reviews it, and it must pass
/// `StrategyValidator` and the engine's own checks before it can run.
public enum StrategyParser {

    public static func parse(_ text: String) -> ParsedAgentRequest {
        let lower = text.lowercased()
        var understood: [String] = []
        var assumptions: [String] = []

        // 1. Assets.
        let (universe, unknown, universeNote) = universe(in: text)

        // 2. Strategy.
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        let periods = averagePeriods(in: lower)
        var templateID: String
        var spec: StrategySpec
        var name: String
        var mode: AgentMode = .paper
        let pick = universe.isEmpty ? nil : universe

        if has("rebalanc") {
            templateID = "etfRebalance"; name = "ETF Rebalancing Agent"
            spec = AgentTemplates.etfRebalancing(pick ?? UniverseCatalog.balancedETFs)
        } else if has("dollar-cost", "dollar cost", " dca", "recurring", "every week", "each week", "every month", "regularly") {
            templateID = "dca"; name = "Dollar-Cost Averaging Agent"
            let interval = has("every day", "daily") ? 1 : (has("every month", "monthly") ? 21 : 5)
            spec = AgentTemplates.dollarCostAveraging(pick ?? [.usETF("SPY", name: "S&P 500 ETF")], intervalBars: interval)
        } else if has("risk manag", "protect my", "guard my") {
            templateID = "riskManager"; name = "Risk Management Agent"
            spec = AgentTemplates.riskManager()
        } else if has("research") && !has("trade", "buy", "sell", "paper") {
            templateID = "research"; name = "Portfolio Research Agent"; mode = .researchOnly
            spec = AgentTemplates.portfolioResearch(pick ?? UniverseCatalog.technology)
        } else if has("breakout", "break out", "breaks out", "new high") {
            templateID = "breakout"; name = "Breakout Agent"
            spec = AgentTemplates.breakout(pick ?? UniverseCatalog.technology)
        } else if has("mean reversion", "mean-reversion", "oversold", "buy the dip", "dips", "bollinger") {
            templateID = "meanReversion"; name = "Mean Reversion Agent"
            spec = AgentTemplates.meanReversion(pick ?? UniverseCatalog.technology)
        } else if has("crossover", "cross over", "cross-over", "crosses", "moving average", "moving-average") {
            templateID = has("momentum") ? "momentum" : "trend"
            name = has("momentum") ? "Momentum Agent" : "Trend Following Agent"
            let fast = periods?.fast ?? 20, slow = periods?.slow ?? 50
            spec = AgentTemplates.movingAverageCrossover(pick ?? UniverseCatalog.technology, fast: fast, slow: slow,
                                                         exponential: has("ema", "exponential"))
            if periods == nil { assumptions.append("Used 20-day and 50-day averages for the crossover.") }
        } else if has("momentum") {
            templateID = "momentum"; name = "Momentum Agent"
            spec = AgentTemplates.momentum(pick ?? UniverseCatalog.technology)
        } else if has("trend") {
            templateID = "trend"; name = "Trend Following Agent"
            spec = AgentTemplates.trendFollowing(pick ?? UniverseCatalog.broadETFs)
        } else if !universe.isEmpty && universe.allSatisfy({ $0.assetClass == .crypto }) {
            templateID = "cryptoMonitor"; name = "Crypto Agent"
            spec = AgentTemplates.cryptoMonitor(universe)
            assumptions.append("No strategy was named, so this uses a crypto trend strategy.")
        } else {
            templateID = "trend"; name = "Trend Following Agent"
            spec = AgentTemplates.trendFollowing(pick ?? UniverseCatalog.broadETFs)
            assumptions.append("No strategy was named, so this uses trend following.")
        }
        understood.append("Strategy: \(spec.title)")

        if spec.followsLedgerPositions {
            understood.append("Assets: the positions in the portfolio it guards")
        } else if universe.isEmpty {
            assumptions.append("No assets were named, so it starts with \(spec.universe.map(\.symbol).joined(separator: ", ")).")
        } else {
            understood.append("Assets: \(universeNote)")
        }

        // 3. Money and percentages.
        let amounts = dollarAmounts(in: text)
        var budget = 10_000.0
        if let largest = amounts.max() {
            if spec.kind == .dca, amounts.count >= 2, let smallest = amounts.min(), smallest < largest {
                budget = largest
                spec.dca?.amountPerBuy = smallest
                spec.sizing.value = smallest
                understood.append("Buys \(money(smallest)) at a time")
            } else if spec.kind == .dca, largest < 1_000 {
                spec.dca?.amountPerBuy = largest
                spec.sizing.value = largest
                understood.append("Buys \(money(largest)) at a time")
                assumptions.append("Used a \(money(budget)) paper budget.")
            } else {
                budget = largest
            }
            if budget == largest { understood.append("Budget: \(money(budget))") }
        } else {
            assumptions.append("Used a \(money(budget)) paper budget.")
        }

        var maxPositionPct = AgentTemplates.template(templateID)?.maxPositionPct ?? 10
        var policyEdits: [(inout RiskPolicy) -> Void] = []
        for (value, meaning) in percentages(in: lower) {
            switch meaning {
            case .trailingStop:
                spec.protections.trailingStopPct = value
                understood.append("Trailing stop: \(Operand.trim(value))%")
            case .stopLoss:
                spec.protections.stopLossPct = value
                understood.append("Stop loss: \(Operand.trim(value))%")
            case .takeProfit:
                spec.protections.takeProfitPct = value
                understood.append("Take profit: \(Operand.trim(value))%")
            case .drawdown:
                policyEdits.append { $0.maxDrawdownPct = value }
                understood.append("Drawdown limit: \(Operand.trim(value))%")
            case .dailyLoss:
                policyEdits.append { $0.maxDailyLossPct = value }
                understood.append("Daily loss limit: \(Operand.trim(value))%")
            case .position:
                maxPositionPct = value
                if spec.sizing.mode == .percentOfEquity && spec.kind == .rules { spec.sizing.value = min(spec.sizing.value, value) }
                understood.append("Position limit: \(Operand.trim(value))% each")
            }
        }

        // 4. Mode.
        if has("research only", "research-only") {
            mode = .researchOnly
        } else if has("signal") && !has("paper") {
            mode = .signals
        }
        if has("real money", "live trading", "live money", "trade live", "go live") {
            assumptions.append("Live trading isn't available, so this is set up as paper trading.")
        }
        if mode == .paper && spec.kind == .research { mode = .researchOnly }
        understood.append("Mode: \(mode.displayName)")
        let review = has("approve", "approval", "ask me", "confirm with me", "check with me", "my permission")
        if review && mode == .paper { understood.append("Each paper trade waits for your approval") }

        // 5. Schedule.
        var schedule = AgentTemplates.template(templateID)?.schedule ?? .hourly
        if let minutes = firstMatch(#"every\s+(\d{1,3})\s*min"#, in: lower).flatMap(Int.init), (5...720).contains(minutes) {
            schedule = AgentSchedule(intervalMinutes: minutes)
        } else if has("every hour", "hourly") {
            schedule = .hourly
        } else if has("once a day", "daily", "every day") && spec.kind != .dca {
            schedule = AgentSchedule(intervalMinutes: 1_440)
        }

        if let custom = firstMatch(#"(?:called|named)\s+["“']?([A-Za-z0-9][A-Za-z0-9 &'-]{1,38})"#, in: text) {
            name = custom.trimmingCharacters(in: CharacterSet(charactersIn: " \"”'.,"))
        }

        var policy = RiskPolicy.standard(budget: budget, maxPositionPct: maxPositionPct,
                                         crypto: !spec.universe.isEmpty && spec.universe.allSatisfy { $0.assetClass == .crypto })
        for edit in policyEdits { edit(&policy) }

        let draft = AgentDraft(name: name, templateID: templateID, mode: mode, spec: spec, budget: budget,
                               maxPositionPct: maxPositionPct, riskPolicy: policy, reviewEachPaperTrade: review,
                               schedule: schedule, author: .user)
        return ParsedAgentRequest(draft: draft, understood: understood, assumptions: assumptions, unrecognisedSymbols: unknown)
    }

    // MARK: - AI-drafted strategies

    /// The JSON an AI model is asked to produce. Only these fields are read.
    public struct DraftEnvelope: Codable, Sendable {
        public var name: String
        public var mode: AgentMode?
        public var budget: Double?
        public var maxPositionPct: Double?
        public var reviewEachPaperTrade: Bool?
        public var intervalMinutes: Int?
        public var spec: StrategySpec
        public var notes: [String]?
    }

    /// Reads a model-drafted agent. The model's text is treated as untrusted input: it is
    /// decoded strictly, live modes are downgraded to paper, and the caller still has to
    /// pass the result through validation and a person's review.
    public static func decodeDraft(json: String) throws -> ParsedAgentRequest {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end else {
            throw TradingError.invalid(["The reply didn't contain a strategy."])
        }
        let data = Data(json[start...end].utf8)
        let envelope: DraftEnvelope
        do {
            envelope = try JSONDecoder().decode(DraftEnvelope.self, from: data)
        } catch {
            throw TradingError.invalid(["The drafted strategy wasn't in the expected format."])
        }
        var assumptions: [String] = []
        var mode = envelope.mode ?? .paper
        if mode.isLive {
            mode = .paper
            assumptions.append("Live trading isn't available, so this is set up as paper trading.")
        }
        if mode == .paper && envelope.spec.kind == .research { mode = .researchOnly }
        let budget = min(max(envelope.budget ?? 10_000, TradingEngine.budgetRange.lowerBound), TradingEngine.budgetRange.upperBound)
        let draft = AgentDraft(name: String(envelope.name.prefix(40)), mode: mode, spec: envelope.spec, budget: budget,
                               maxPositionPct: min(max(envelope.maxPositionPct ?? 10, 1), 100),
                               reviewEachPaperTrade: envelope.reviewEachPaperTrade ?? false,
                               schedule: AgentSchedule(intervalMinutes: min(max(envelope.intervalMinutes ?? 60, 5), 10_080)),
                               author: .copilot)
        let problems = StrategyValidator.validate(draft.spec).filter { $0.severity == .error }.map(\.message)
        guard problems.isEmpty else { throw TradingError.invalid(problems) }
        return ParsedAgentRequest(draft: draft, understood: envelope.notes ?? [], assumptions: assumptions, unrecognisedSymbols: [])
    }

    // MARK: - Reading the text

    private static let themes: [(words: [String], label: String, list: [Instrument])] = [
        (["semiconductor", "chip stock", "chipmaker", "chip maker"], "semiconductor stocks", UniverseCatalog.semiconductors),
        (["technology", "tech stock", "tech compan", "big tech", "tech sector"], "technology stocks", UniverseCatalog.technology),
        (["bank", "financial"], "financial stocks", UniverseCatalog.financials),
        (["healthcare", "health care", "pharma"], "healthcare stocks", UniverseCatalog.healthcare),
        (["energy stock", "oil"], "energy stocks", UniverseCatalog.energy),
        (["crypto", "coins"], "major crypto", UniverseCatalog.cryptoMajors),
        (["asx", "australian stock", "australian share", "aussie"], "ASX blue chips", UniverseCatalog.asxBlueChips),
        (["etf", "index fund", "funds"], "broad-market ETFs", UniverseCatalog.broadETFs)
    ]

    private static let names: [String: String] = [
        "bitcoin": "BTC", "ethereum": "ETH", "ether": "ETH", "solana": "SOL", "dogecoin": "DOGE", "cardano": "ADA",
        "apple": "AAPL", "microsoft": "MSFT", "nvidia": "NVDA", "alphabet": "GOOGL", "google": "GOOGL",
        "amazon": "AMZN", "meta": "META", "tesla": "TSLA", "netflix": "NFLX", "broadcom": "AVGO",
        "s&p 500": "SPY", "s&p500": "SPY", "sp500": "SPY", "nasdaq": "QQQ"
    ]

    /// Words in capitals that are not tickers.
    private static let notTickers: Set<String> = [
        "AI", "ETF", "ETFS", "USD", "AUD", "RSI", "MACD", "DCA", "ASX", "US", "USA", "EMA", "SMA", "MA", "ATR",
        "I", "A", "AN", "THE", "AND", "OR", "TO", "IT", "IN", "ON", "OF", "MY", "ME", "IF", "AT", "BY", "FOR",
        "BUY", "SELL", "HOLD", "CREATE", "PAPER", "LIVE", "STOP", "LOSS", "ALL", "NYSE", "NASDAQ", "CEO", "IPO", "PE", "UK", "EU"
    ]

    static func universe(in text: String) -> (instruments: [Instrument], unknown: [String], note: String) {
        let lower = text.lowercased()
        var seen = Set<String>()
        var out: [Instrument] = []
        var labels: [String] = []
        func add(_ instrument: Instrument) {
            if seen.insert(instrument.id).inserted { out.append(instrument) }
        }

        // Explicit tickers ($AAPL, or capitals that match a known symbol).
        var unknown: [String] = []
        let wantsASX = lower.contains("asx") || lower.contains("australian")
        for token in tickerTokens(in: text) {
            let explicit = token.hasPrefix("$")
            let symbol = explicit ? String(token.dropFirst()) : token
            guard !notTickers.contains(symbol) else { continue }
            if let instrument = UniverseCatalog.instrument(symbol: symbol, preferring: wantsASX ? .asx : nil) {
                add(instrument)
            } else if explicit, StrategyValidator.isValidSymbol(symbol) {
                unknown.append(symbol)
            }
        }
        for (word, symbol) in names.sorted(by: { $0.key < $1.key }) where lower.contains(word) {
            // "meta" alone is too common a word fragment to trust ("metadata").
            if word == "meta", !containsWord("meta", in: lower) { continue }
            if word == "ether", lower.contains("ethereum") { continue }
            if let instrument = UniverseCatalog.instrument(symbol: symbol) { add(instrument) }
        }
        if !out.isEmpty { labels.append(out.map(\.symbol).joined(separator: ", ")) }

        // Themes only fill the list when no specific asset was named.
        if out.isEmpty {
            for theme in themes where theme.words.contains(where: { lower.contains($0) }) {
                theme.list.forEach(add)
                labels.append(theme.label)
            }
        }

        // One currency per agent: keep the first group named and drop the rest.
        if let currency = out.first?.currency, out.contains(where: { $0.currency != currency }) {
            out = out.filter { $0.currency == currency }
            labels.append("(\(currency) assets only — an agent trades in one currency)")
        }
        if out.count > StrategyValidator.maxUniverse { out = Array(out.prefix(StrategyValidator.maxUniverse)) }
        return (out, unknown, labels.joined(separator: " "))
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        firstMatch("(?<![a-z])\(word)(?![a-z])", in: text, group: 0) != nil
    }

    private static func tickerTokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\$[A-Za-z]{1,6}\b|\b[A-Z]{2,6}\b"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).uppercased() }
        }
    }

    /// "$5,000", "$5k", "5000 dollars" → 5000.
    static func dollarAmounts(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:a?\$\s?([\d,]+(?:\.\d+)?)\s*([kKmM])?(?![a-zA-Z]))|(?:\b([\d,]+(?:\.\d+)?)\s*([kKmM])?\s*(?:dollars|usd|aud)\b)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            func group(_ i: Int) -> String? {
                guard match.range(at: i).location != NSNotFound, let r = Range(match.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            guard let digits = group(1) ?? group(3), var value = Double(digits.replacingOccurrences(of: ",", with: "")) else { return nil }
            switch (group(2) ?? group(4))?.lowercased() {
            case "k": value *= 1_000
            case "m": value *= 1_000_000
            default: break
            }
            return value > 0 ? value : nil
        }
    }

    enum PercentMeaning: Equatable {
        case trailingStop, stopLoss, takeProfit, drawdown, dailyLoss, position
    }

    private static func meaning(of words: String) -> PercentMeaning? {
        if words.contains("trailing") { return .trailingStop }
        if words.contains("stop") { return .stopLoss }
        if words.contains("take profit") || words.contains("take-profit") || words.contains("profit target") { return .takeProfit }
        if words.contains("drawdown") { return .drawdown }
        if words.contains("daily loss") || words.contains("loss per day") || words.contains("lose") || words.contains("loss a day") { return .dailyLoss }
        if words.contains("position") || words.contains("each") || words.contains("per ") || words.contains("allocation")
            || words.contains("any one") || words.contains("single") { return .position }
        return nil
    }

    /// Each percentage in the text with what it refers to. People write the figure on either
    /// side of its name ("8% stop loss", "stop loss of 8%"), so the words just before the
    /// number decide which side to read: after "of", "to", "at", "than" and the like, the
    /// name came first; otherwise it follows.
    static func percentages(in lower: String) -> [(value: Double, meaning: PercentMeaning)] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*(?:%|percent)"#) else { return [] }
        let ns = lower as NSString
        let breaks = CharacterSet(charactersIn: ".;,")
        return regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let value = Double(ns.substring(with: match.range(at: 1))), value > 0, value <= 100 else { return nil }
            let start = max(match.range.location - 48, 0)
            let matchEnd = match.range.location + match.range.length
            let end = min(matchEnd + 30, ns.length)
            // The words before, back to the previous figure or clause break.
            var before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            if let cut = before.lastIndex(where: { $0.isNumber || $0 == "%" || $0.unicodeScalars.allSatisfy(breaks.contains) }) {
                before = String(before[before.index(after: cut)...])
            }
            // The words after, up to the next figure or clause break.
            var after = ns.substring(with: NSRange(location: matchEnd, length: end - matchEnd))
            if let cut = after.firstIndex(where: { $0.isNumber || $0.unicodeScalars.allSatisfy(breaks.contains) }) {
                after = String(after[..<cut])
            }
            let lead = before.trimmingCharacters(in: .whitespaces)
            let nameCameFirst = ["of", "to", "at", "is", "by", "than", "under", "below", "above", "within", "exceeds", "reaches", ":", "="]
                .contains { lead.hasSuffix(" " + $0) || lead == $0 }
            let result = nameCameFirst ? (meaning(of: before) ?? meaning(of: after)) : (meaning(of: after) ?? meaning(of: before))
            return result.map { (value, $0) }
        }
    }

    /// The two averaging periods in "20-day and 50-day moving averages" or "50/200".
    static func averagePeriods(in lower: String) -> (fast: Int, slow: Int)? {
        var found: [Int] = []
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,3})\s*[- ]?\s*(?:day|d\b|period|bar)"#) {
            let ns = lower as NSString
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                if let value = Int(ns.substring(with: match.range(at: 1))) { found.append(value) }
            }
        }
        if found.count < 2, let pair = firstMatch(#"\b(\d{1,3}\s*/\s*\d{1,3})\b"#, in: lower) {
            found = pair.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        let valid = Array(Set(found.filter { (2...StrategyValidator.maxPeriod).contains($0) })).sorted()
        guard valid.count >= 2, let fast = valid.first, let slow = valid.last, fast < slow else { return nil }
        return (fast, slow)
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > group, match.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: group))
    }

    private static func money(_ x: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = x == x.rounded() ? 0 : 2
        formatter.locale = Locale(identifier: "en_US")
        return "$" + (formatter.string(from: NSNumber(value: x)) ?? String(format: "%.0f", x))
    }
}
