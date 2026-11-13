import Foundation

public enum BrokerPermission: String, Codable, CaseIterable, Sendable {
    case read, trade
}

public enum BrokerEnvironment: String, Codable, CaseIterable, Sendable {
    /// Simulated inside this app or its server. No outside party involved.
    case paper
    /// A provider's own test environment.
    case sandbox
    /// Real money.
    case live
}

/// What an execution venue can do. Every adapter publishes one of these, and the risk
/// engine checks orders against it — nothing is assumed from the venue's name.
public struct BrokerCapabilities: Codable, Hashable, Sendable {
    public var adapterID: String
    public var displayName: String
    public var environment: BrokerEnvironment
    /// ISO country codes whose residents can use it; ["*"] means no restriction.
    public var countries: [String]
    public var venues: [Venue]
    public var assetClasses: [AssetClass]
    public var orderTypes: [OrderType]
    public var timeInForce: [TimeInForce]
    public var supportsFractional: Bool
    public var supportsNotionalOrders: Bool
    /// The most this adapter could ever be granted. A connection may hold less.
    public var permissions: [BrokerPermission]
    /// False for integrations that are described but not switched on.
    public var isExecutionEnabled: Bool
    public var disabledReason: String?
    public var notes: [String]

    public init(adapterID: String, displayName: String, environment: BrokerEnvironment, countries: [String],
                venues: [Venue], assetClasses: [AssetClass], orderTypes: [OrderType], timeInForce: [TimeInForce],
                supportsFractional: Bool, supportsNotionalOrders: Bool, permissions: [BrokerPermission],
                isExecutionEnabled: Bool, disabledReason: String? = nil, notes: [String] = []) {
        self.adapterID = adapterID
        self.displayName = displayName
        self.environment = environment
        self.countries = countries
        self.venues = venues
        self.assetClasses = assetClasses
        self.orderTypes = orderTypes
        self.timeInForce = timeInForce
        self.supportsFractional = supportsFractional
        self.supportsNotionalOrders = supportsNotionalOrders
        self.permissions = permissions
        self.isExecutionEnabled = isExecutionEnabled
        self.disabledReason = disabledReason
        self.notes = notes
    }

    public func supports(_ instrument: Instrument) -> Bool {
        venues.contains(instrument.venue) && assetClasses.contains(instrument.assetClass)
    }
}

/// How the built-in simulator prices and charges for a fill.
public struct PaperBrokerConfig: Codable, Hashable, Sendable {
    /// Flat commission per equity order.
    public var equityFeePerOrder: Double
    /// Commission on equity orders, in basis points of the trade value.
    public var equityFeeBps: Double
    /// Taker fee on crypto orders, in basis points.
    public var cryptoFeeBps: Double
    /// Half-spread assumed when the feed has no usable bid and ask, in basis points.
    public var modelledHalfSpreadBpsEquity: Double
    public var modelledHalfSpreadBpsCrypto: Double
    /// The most one match will fill, as a share of the day's reported volume. Bigger
    /// orders fill in parts. Ignored when the feed reports no volume.
    public var maxParticipation: Double
    /// A quote older than this is not matched against (the order waits for a fresh one).
    public var maxMatchQuoteAgeSeconds: Double

    public init(equityFeePerOrder: Double = 0, equityFeeBps: Double = 0, cryptoFeeBps: Double = 25,
                modelledHalfSpreadBpsEquity: Double = 2, modelledHalfSpreadBpsCrypto: Double = 5,
                maxParticipation: Double = 0.01, maxMatchQuoteAgeSeconds: Double = 1_200) {
        self.equityFeePerOrder = equityFeePerOrder
        self.equityFeeBps = equityFeeBps
        self.cryptoFeeBps = cryptoFeeBps
        self.modelledHalfSpreadBpsEquity = modelledHalfSpreadBpsEquity
        self.modelledHalfSpreadBpsCrypto = modelledHalfSpreadBpsCrypto
        self.maxParticipation = maxParticipation
        self.maxMatchQuoteAgeSeconds = maxMatchQuoteAgeSeconds
    }
}

/// The built-in simulator. It fills against real quotes with a spread, fees and partial
/// fills, and it is the only venue that executes anything in this build.
public enum PaperBroker {
    public static let adapterID = "paper"

    public static let capabilities = BrokerCapabilities(
        adapterID: adapterID,
        displayName: "Paper trading",
        environment: .paper,
        countries: ["*"],
        venues: Venue.allCases,
        assetClasses: [.equity, .etf, .crypto],
        orderTypes: [.market, .limit, .stop, .stopLimit],
        timeInForce: [.day, .gtc, .ioc, .fok],
        supportsFractional: true,
        supportsNotionalOrders: true,
        permissions: [.read, .trade],
        isExecutionEnabled: true,
        notes: [
            "Simulated fills against live quotes (delayed for markets outside the US). No order leaves this app.",
            "Shares outside the US trade in whole units; Tokyo and Singapore in lots of 100. Exchange tick-size tables and Hong Kong board lots are not enforced.",
            "No leverage, margin, short selling or withdrawals."
        ]
    )

    public static func rules(for instrument: Instrument) -> InstrumentRules {
        switch instrument.assetClass {
        case .crypto:
            return InstrumentRules(quantityIncrement: 0.000_000_01, minQuantity: 0.000_000_01, minNotional: 1,
                                   priceIncrement: 0.01, fractionable: true)
        case .equity, .etf:
            func whole(lot: Double = 1, tick: Double) -> InstrumentRules {
                InstrumentRules(quantityIncrement: lot, minQuantity: lot, minNotional: 1, priceIncrement: tick, fractionable: false)
            }
            switch instrument.venue {
            case .us, .crypto:
                return InstrumentRules(quantityIncrement: 0.000_001, minQuantity: 0.000_001, minNotional: 1,
                                       priceIncrement: 0.01, fractionable: true)
            case .asx: return whole(tick: 0.005)
            // Price steps are the finest each market uses; the full tick tables aren't modelled.
            case .lse: return whole(tick: 0.0001)          // pounds (Yahoo quotes pence; converted)
            case .xetra, .euronextParis, .euronextAmsterdam: return whole(tick: 0.001)
            case .six: return whole(tick: 0.01)
            case .tse: return whole(lot: 100, tick: 0.1)    // Tokyo trades in units of 100 shares
            case .hkex: return whole(tick: 0.001)          // board lots vary by stock; not enforced
            case .sgx: return whole(lot: 100, tick: 0.001)  // SGX board lot is 100 shares
            case .krx: return whole(tick: 1)
            case .nse: return whole(tick: 0.01)
            }
        }
    }

    /// A quantity as a person would read it: at the instrument's precision, without trailing zeros.
    public static func quantityText(_ quantity: Double, for instrument: Instrument) -> String {
        RiskEngine.quantityText(quantity, rules(for: instrument))
    }

    public static func fee(for instrument: Instrument, notional: Double, isFirstFillOfOrder: Bool,
                           config: PaperBrokerConfig) -> Double {
        switch instrument.assetClass {
        case .crypto:
            return Rounding.money(notional * config.cryptoFeeBps / 10_000)
        case .equity, .etf:
            let flat = isFirstFillOfOrder ? config.equityFeePerOrder : 0
            return Rounding.money(flat + notional * config.equityFeeBps / 10_000)
        }
    }

    /// The price a market order would trade at right now: the ask to buy and the bid to
    /// sell, or the last price moved by a modelled half-spread when the feed is one-sided.
    public static func executionPrice(side: OrderSide, quote: Quote, instrument: Instrument,
                                      config: PaperBrokerConfig) -> (price: Double, modelled: Bool) {
        let rules = rules(for: instrument)
        if quote.hasTwoSidedMarket, let bid = quote.bid, let ask = quote.ask {
            return (side == .buy ? ask : bid, false)
        }
        let half = (instrument.assetClass == .crypto ? config.modelledHalfSpreadBpsCrypto : config.modelledHalfSpreadBpsEquity) / 10_000
        let raw = side == .buy ? quote.last * (1 + half) : quote.last * (1 - half)
        return (max(Rounding.nearest(raw, increment: rules.priceIncrement), rules.priceIncrement), true)
    }

    public struct Match: Sendable, Equatable {
        public var fillQuantity: Double
        public var fillPrice: Double
        public var fee: Double
        public var newStatus: OrderStatus
        public var stopTriggered: Bool
        public var note: String?
    }

    /// Tries to trade an open order against one quote. Pure: it returns what should happen
    /// and changes nothing, so the engine applies the result in one place.
    /// Returns nil when the order should simply keep waiting.
    public static func match(order: Order, quote: Quote, marketOpen: Bool, now: Date,
                             config: PaperBrokerConfig) -> Match? {
        guard order.status.isOpen, order.remainingQuantity > 0 else { return nil }
        let immediate = order.timeInForce == .ioc || order.timeInForce == .fok

        func cancel(_ note: String) -> Match {
            Match(fillQuantity: 0, fillPrice: 0, fee: 0, newStatus: .canceled, stopTriggered: false, note: note)
        }

        guard marketOpen else {
            return immediate ? cancel("The market is closed, so an immediate order can't trade.") : nil
        }
        guard quote.last > 0, quote.age(at: now) <= config.maxMatchQuoteAgeSeconds + Double(quote.provenance.delaySeconds) else {
            return immediate ? cancel("No fresh quote to trade against.") : nil
        }

        let (marketPrice, modelled) = executionPrice(side: order.side, quote: quote, instrument: order.instrument, config: config)

        // Stops wait for the last trade to reach the stop price, then behave like a market or limit order.
        var stopTriggered = false
        if order.type.needsStopPrice, order.stopTriggeredAt == nil {
            guard let stop = order.stopPrice else { return cancel("The stop price is missing.") }
            let reached = order.side == .buy ? quote.last >= stop : quote.last <= stop
            guard reached else { return immediate ? cancel("The stop price wasn't reached.") : nil }
            stopTriggered = true
        }

        if order.type.needsLimitPrice {
            guard let limit = order.limitPrice else { return cancel("The limit price is missing.") }
            let marketable = order.side == .buy ? marketPrice <= limit : marketPrice >= limit
            guard marketable else {
                if immediate { return cancel("The limit price wasn't available.") }
                return stopTriggered
                    ? Match(fillQuantity: 0, fillPrice: 0, fee: 0, newStatus: order.status, stopTriggered: true,
                            note: "Stop reached; waiting for the limit price.")
                    : nil
            }
        }

        // How much can trade against this quote.
        let rules = rules(for: order.instrument)
        var available = order.remainingQuantity
        if let volume = quote.dayVolume, volume > 0, config.maxParticipation > 0 {
            let cap = max(Rounding.floor(volume * config.maxParticipation, increment: rules.quantityIncrement), rules.quantityIncrement)
            available = min(available, cap)
        }
        if order.timeInForce == .fok, available + 1e-12 < order.remainingQuantity {
            return cancel("The full quantity wasn't available.")
        }

        let filledBefore = order.filledQuantity
        let notional = Rounding.money(available * marketPrice)
        let fee = fee(for: order.instrument, notional: notional, isFirstFillOfOrder: filledBefore == 0, config: config)
        let complete = order.remainingQuantity - available <= rules.quantityIncrement * 1e-3
        let status: OrderStatus
        if complete { status = .filled }
        else if order.timeInForce == .ioc { status = .canceled }
        else { status = .partiallyFilled }
        var notes: [String] = []
        if modelled { notes.append("No two-sided quote: filled at the last price plus a modelled spread.") }
        if !complete { notes.append(order.timeInForce == .ioc ? "Part filled; the rest was cancelled." : "Part filled; the rest is still working.") }
        return Match(fillQuantity: available, fillPrice: marketPrice, fee: fee, newStatus: status,
                     stopTriggered: stopTriggered, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// When a day order placed at `time` stops working: the end of the current session, or
    /// of the next one if the market is shut. Crypto day orders last 24 hours.
    public static func expiry(for timeInForce: TimeInForce, venue: Venue, placedAt time: Date,
                              calendar: MarketCalendar = .standard) -> Date? {
        switch timeInForce {
        case .day:
            if venue == .crypto { return time.addingTimeInterval(86_400) }
            return calendar.nextClose(venue, after: time)
        case .gtc:
            return time.addingTimeInterval(90 * 86_400)
        case .ioc, .fok:
            return nil
        }
    }
}

// MARK: - Live venues (described, not switched on)

/// Real-money venues this app knows how to describe. None of them can execute in this
/// build: there is no trading-enabled connection, no server-held trading credential and no
/// licence in place. They exist so the product can show an honest "not available yet"
/// with the reason, and so switching one on later is a deliberate, reviewable change.
public enum LiveVenues {
    public static let alpaca = BrokerCapabilities(
        adapterID: "alpaca",
        displayName: "Alpaca",
        environment: .live,
        countries: [],
        venues: [.us, .crypto],
        assetClasses: [.equity, .etf, .crypto],
        orderTypes: [.market, .limit, .stop, .stopLimit],
        timeInForce: [.day, .gtc, .ioc, .fok],
        supportsFractional: true,
        supportsNotionalOrders: true,
        permissions: [.read, .trade],
        isExecutionEnabled: false,
        disabledReason: "Trading through Alpaca isn't set up. The app reads prices with its Alpaca key and never sends an order with it.",
        notes: [
            "Needs a trading account the person authorises (OAuth with the separate trading scope), with credentials held on the server.",
            "US stocks, ETFs and crypto only — Alpaca does not offer ASX securities.",
            "Fractional and notional orders are day orders; crypto takes market, limit and stop-limit with GTC or IOC."
        ]
    )

    public static let snapTrade = BrokerCapabilities(
        adapterID: "snaptrade",
        displayName: "Connected broker (SnapTrade)",
        environment: .live,
        countries: [],
        venues: [.us, .asx, .crypto],
        assetClasses: [.equity, .etf, .crypto],
        orderTypes: [.market, .limit],
        timeInForce: [.day, .gtc],
        supportsFractional: false,
        supportsNotionalOrders: false,
        permissions: [.read],
        isExecutionEnabled: false,
        disabledReason: "Your broker connection is read-only. It shows holdings and can't place orders.",
        notes: [
            "A read-only connection is never treated as permission to trade.",
            "Trading needs a connection made with trade access, and only some brokers offer it (CommSec and Interactive Brokers are read-only through SnapTrade)."
        ]
    )

    public static let cryptoExchange = BrokerCapabilities(
        adapterID: "crypto-exchange",
        displayName: "Crypto exchange",
        environment: .live,
        countries: [],
        venues: [.crypto],
        assetClasses: [.crypto],
        orderTypes: [.market, .limit],
        timeInForce: [.gtc, .ioc],
        supportsFractional: true,
        supportsNotionalOrders: false,
        permissions: [.read, .trade],
        isExecutionEnabled: false,
        disabledReason: "No crypto exchange is connected for trading.",
        notes: ["Spot only. No margin, futures or withdrawals."]
    )

    public static let all = [alpaca, snapTrade, cryptoExchange]
}
