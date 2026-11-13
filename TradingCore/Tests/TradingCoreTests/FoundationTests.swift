import XCTest
@testable import TradingCore

final class RoundingTests: XCTestCase {
    func testMoneyRoundsHalfAwayFromZero() {
        XCTAssertEqual(Rounding.money(1.005), 1.0)          // 1.005 is 1.00499… in binary
        XCTAssertEqual(Rounding.money(2.675), 2.68)
        XCTAssertEqual(Rounding.money(-2.675), -2.68)
        XCTAssertEqual(Rounding.money(10), 10)
    }

    func testFloorToIncrementSurvivesBinaryFractions() {
        XCTAssertEqual(Rounding.floor(0.3, increment: 0.1), 0.3)   // 0.3 / 0.1 is 2.9999999999999996
        XCTAssertEqual(Rounding.floor(1.23456789, increment: 0.000_001), 1.234567)
        XCTAssertEqual(Rounding.floor(7.9, increment: 1), 7)
        XCTAssertEqual(Rounding.floor(0.123456789, increment: 0.000_000_01), 0.12345678)
    }

    func testDecimalsAndStrings() {
        XCTAssertEqual(Rounding.decimals(for: 1), 0)
        XCTAssertEqual(Rounding.decimals(for: 0.01), 2)
        XCTAssertEqual(Rounding.decimals(for: 0.000_000_01), 8)
        XCTAssertEqual(Rounding.decimals(for: 0.005), 3)
        XCTAssertEqual(Rounding.string(0.000123, increment: 0.000_000_01), "0.00012300")
        XCTAssertEqual(Rounding.string(12, increment: 1), "12")
    }

    func testIsMultiple() {
        XCTAssertTrue(Rounding.isMultiple(0.3, of: 0.1))
        XCTAssertTrue(Rounding.isMultiple(101.25, of: 0.01))
        XCTAssertFalse(Rounding.isMultiple(101.255, of: 0.01))
        XCTAssertFalse(Rounding.isMultiple(1.5, of: 1))
    }
}

final class IndicatorTests: XCTestCase {
    func testSMA() {
        let out = Indicators.sma([1, 2, 3, 4, 5], period: 3)
        XCTAssertNil(out[0]); XCTAssertNil(out[1])
        XCTAssertEqual(out[2], 2); XCTAssertEqual(out[3], 3); XCTAssertEqual(out[4], 4)
    }

    func testEMASeedsWithSimpleAverage() {
        let out = Indicators.ema([2, 4, 6, 8, 10], period: 3)
        XCTAssertNil(out[1])
        XCTAssertEqual(out[2], 4)                      // (2+4+6)/3
        XCTAssertClose(out[3]!, 4 + 0.5 * (8 - 4))     // k = 2/(3+1)
        XCTAssertClose(out[4]!, 6 + 0.5 * (10 - 6))
    }

    func testRSIExtremesAndHandComputedValue() {
        XCTAssertEqual(Indicators.rsi([1, 2, 3, 4, 5, 6], period: 3).last!, 100)
        XCTAssertEqual(Indicators.rsi([6, 5, 4, 3, 2, 1], period: 3).last!, 0)
        XCTAssertEqual(Indicators.rsi([5, 5, 5, 5, 5], period: 3).last!, 50)
        // Changes +2, -1 → avgGain 1, avgLoss 0.5 → RS 2 → RSI 66.67
        let out = Indicators.rsi([10, 12, 11], period: 2)
        XCTAssertClose(out[2]!, 100 - 100 / 3, accuracy: 1e-9)
        // Next change +3 → avgGain (1·1 + 3)/2 = 2, avgLoss (0.5·1 + 0)/2 = 0.25 → RS 8
        let next = Indicators.rsi([10, 12, 11, 14], period: 2)
        XCTAssertClose(next[3]!, 100 - 100 / 9, accuracy: 1e-9)
    }

    func testMACDIsFastMinusSlowAndHistogramIsLineMinusSignal() {
        let values = (0..<80).map { index in
            let position = Double(index)
            let oscillation = sin(position / 5) * 10
            return 100 + oscillation + position * 0.2
        }
        let macd = Indicators.macd(values, fast: 12, slow: 26, signal: 9)
        let fast = Indicators.ema(values, period: 12), slow = Indicators.ema(values, period: 26)
        XCTAssertNil(macd.line[24])
        XCTAssertClose(macd.line[40]!, fast[40]! - slow[40]!)
        XCTAssertNil(macd.signal[32])                  // first signal at 25 + 8
        XCTAssertNotNil(macd.signal[33])
        XCTAssertClose(macd.histogram[60]!, macd.line[60]! - macd.signal[60]!)
    }

    func testBollingerUsesPopulationDeviation() {
        let flat = Indicators.bollinger([5, 5, 5, 5], period: 3, deviations: 2)
        XCTAssertEqual(flat.upper[3], 5); XCTAssertEqual(flat.lower[3], 5)
        // Window 2,4,6: mean 4, population sd = sqrt(8/3)
        let bands = Indicators.bollinger([2, 4, 6], period: 3, deviations: 2)
        XCTAssertClose(bands.upper[2]!, 4 + 2 * (8.0 / 3).squareRoot())
        XCTAssertClose(bands.lower[2]!, 4 - 2 * (8.0 / 3).squareRoot())
    }

    func testATRUsesTrueRangeIncludingGaps() {
        let t = Fx.usTradingDays(count: 3)
        let bars = [
            Bar(time: t[0], open: 10, high: 11, low: 9, close: 10, volume: 1),
            Bar(time: t[1], open: 13, high: 14, low: 13, close: 13.5, volume: 1),   // gap up: TR = 14 - 10 = 4
            Bar(time: t[2], open: 13, high: 13.5, low: 12.5, close: 13, volume: 1)  // TR = 1
        ]
        XCTAssertClose(Indicators.atr(bars, period: 2)[2]!, 2.5)
    }

    func testPriorHighestExcludesTheCurrentBar() {
        let out = Indicators.priorHighest([1, 5, 3, 9], period: 2)
        XCTAssertNil(out[1])
        XCTAssertEqual(out[2], 5)       // max of 1, 5
        XCTAssertEqual(out[3], 5)       // max of 5, 3 — the 9 itself is not included
        XCTAssertEqual(Indicators.priorLowest([4, 2, 6, 1], period: 2)[3], 2)
    }

    /// The value at bar i must not change when later bars are added. This is the
    /// no-look-ahead guarantee for every indicator the strategies can use.
    func testNoIndicatorLooksAhead() {
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var closes: [Double] = [100]
        for _ in 1..<120 { closes.append(max(closes.last! * (1 + (next() - 0.5) * 0.06), 1)) }
        let bars = Fx.dailyBars(closes: closes)
        let operands: [Operand] = [.sma(10), .ema(10), .rsi(14), .atr(14), .highest(20), .lowest(20), .rateOfChange(10),
                                   .macdLine(), .macdSignal(), .macdHistogram(), .bollingerUpper(), .bollingerLower(),
                                   .bollingerMiddle(), .volumeAverage(10)]
        let full = PreparedSeries(bars: bars)
        for cut in [40, 75, 100] {
            let partial = PreparedSeries(bars: Array(bars.prefix(cut + 1)))
            for operand in operands {
                let a = partial.value(operand, at: cut), b = full.value(operand, at: cut)
                XCTAssertEqual(a == nil, b == nil, "\(operand.kind) at \(cut)")
                if let a, let b { XCTAssertClose(a, b, accuracy: 1e-9) }
            }
        }
    }
}

final class MarketCalendarTests: XCTestCase {
    let calendar = MarketCalendar.standard

    func testUSSessionHours() {
        XCTAssertTrue(calendar.isOpen(.us, at: Fx.date("2026-11-10T15:00:00Z")))     // 10:00 ET
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-11-10T14:29:00Z")))    // 9:29 ET
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-11-10T21:00:00Z")))    // 16:00 ET, closed at the bell
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-11-14T16:00:00Z")))    // Saturday
    }

    func testUSDaylightSavingShiftsTheOpenInUTC() {
        // In July New York is UTC-4: the open is 13:30 UTC, not 14:30.
        XCTAssertTrue(calendar.isOpen(.us, at: Fx.date("2026-07-14T13:31:00Z")))
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-07-14T13:29:00Z")))
    }

    func testHolidaysAndEarlyCloses() {
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-11-26T16:00:00Z")))    // Thanksgiving
        XCTAssertTrue(calendar.isOpen(.us, at: Fx.date("2026-11-27T17:30:00Z")))     // 12:30 ET on the half day
        XCTAssertFalse(calendar.isOpen(.us, at: Fx.date("2026-11-27T18:30:00Z")))    // 13:30 ET, after the 13:00 close
        XCTAssertFalse(calendar.isTradingDay(.asx, Fx.date("2026-01-26T01:00:00Z"))) // Australia Day
    }

    func testASXAndCrypto() {
        XCTAssertTrue(calendar.isOpen(.asx, at: Fx.date("2026-11-10T00:30:00Z")))    // 11:30 Sydney (AEDT)
        XCTAssertFalse(calendar.isOpen(.asx, at: Fx.date("2026-11-10T06:00:00Z")))   // 17:00 Sydney
        XCTAssertTrue(calendar.isOpen(.crypto, at: Fx.date("2026-11-14T03:00:00Z"))) // Saturday
        XCTAssertNil(calendar.nextOpen(.crypto, after: Fx.now))
    }

    func testNextOpenSkipsWeekendAndHoliday() {
        // Friday after the close → Monday 9:30 ET.
        XCTAssertEqual(calendar.nextOpen(.us, after: Fx.date("2026-11-13T22:00:00Z")), Fx.date("2026-11-16T14:30:00Z"))
        // Wednesday before Thanksgiving, after the close → Friday.
        XCTAssertEqual(calendar.nextOpen(.us, after: Fx.date("2026-11-25T22:00:00Z")), Fx.date("2026-11-27T14:30:00Z"))
    }

    func testTodaysDailyBarIsNotCompleteUntilTheClose() {
        let today = Bar(time: Fx.date("2026-11-10T05:00:00Z"), open: 1, high: 1, low: 1, close: 1, volume: 1)
        XCTAssertFalse(calendar.isBarComplete(today, timeframe: .day, venue: .us, now: Fx.now))
        XCTAssertTrue(calendar.isBarComplete(today, timeframe: .day, venue: .us, now: Fx.date("2026-11-10T21:00:00Z")))
        let cryptoToday = Bar(time: Fx.date("2026-11-10T00:00:00Z"), open: 1, high: 1, low: 1, close: 1, volume: 1)
        XCTAssertFalse(calendar.isBarComplete(cryptoToday, timeframe: .day, venue: .crypto, now: Fx.now))
        XCTAssertTrue(calendar.isBarComplete(cryptoToday, timeframe: .day, venue: .crypto, now: Fx.date("2026-11-11T00:00:00Z")))
    }

    func testCompletedBarsDropsTheBarStillForming() {
        var days = Fx.usTradingDays(count: 3)
        days.append(Fx.date("2026-11-10T05:00:00Z"))
        let series = Fx.series(Fx.aapl, closes: [1, 2, 3, 4], days: days)
        XCTAssertEqual(calendar.completedBars(series, now: Fx.now).map(\.close), [1, 2, 3])
    }
}

final class OrderStatusTests: XCTestCase {
    func testAllowedAndRefusedTransitions() {
        XCTAssertTrue(OrderStatus.accepted.canTransition(to: .partiallyFilled))
        XCTAssertTrue(OrderStatus.partiallyFilled.canTransition(to: .filled))
        XCTAssertTrue(OrderStatus.partiallyFilled.canTransition(to: .canceled))
        XCTAssertTrue(OrderStatus.pendingSubmit.canTransition(to: .rejected))
        XCTAssertFalse(OrderStatus.partiallyFilled.canTransition(to: .rejected))
        XCTAssertFalse(OrderStatus.partiallyFilled.canTransition(to: .accepted))
        for terminal in [OrderStatus.filled, .canceled, .rejected, .expired] {
            XCTAssertTrue(terminal.isTerminal)
            for next in OrderStatus.allCases { XCTAssertFalse(terminal.canTransition(to: next), "\(terminal) → \(next)") }
        }
    }

    func testAFilledOrderCannotBeCancelled() {
        var order = Order(clientOrderID: "a", ledgerID: UUID(), instrument: Fx.aapl, side: .buy, type: .market, quantity: 1,
                          timeInForce: .day, source: .manual, mode: .paper, status: .accepted, referencePrice: 10, createdAt: Fx.now)
        XCTAssertTrue(order.transition(to: .filled, at: Fx.now))
        XCTAssertFalse(order.transition(to: .canceled, at: Fx.now))
        XCTAssertEqual(order.status, .filled)
    }
}

final class LedgerTests: XCTestCase {
    private func fill(_ side: OrderSide, _ quantity: Double, _ price: Double, fee: Double = 0, at time: Date = Fx.now,
                      ledger: Ledger, instrument: Instrument = Fx.aapl) -> Fill {
        Fill(orderID: UUID(), ledgerID: ledger.id, instrument: instrument, side: side, quantity: quantity, price: price,
             fee: fee, time: time, source: .manual, mode: .paper)
    }

    func testBuyThenPartialSellUsesAverageCostAndBooksFees() {
        var ledger = Ledger(name: "Test", kind: .manualPaper, startingCash: 10_000, createdAt: Fx.now)
        ledger.apply(fill(.buy, 10, 100, fee: 1, ledger: ledger))        // cost 1001
        ledger.apply(fill(.buy, 10, 120, fee: 1, ledger: ledger))        // cost 1201 → basis 2202, avg 110.10
        XCTAssertEqual(ledger.cash, 10_000 - 1_001 - 1_201)
        XCTAssertEqual(ledger.position(Fx.aapl.id)?.quantity, 20)
        XCTAssertClose(ledger.position(Fx.aapl.id)!.averageCost, 110.10)

        let sold = ledger.apply(fill(.sell, 5, 130, fee: 1, ledger: ledger))
        // Proceeds 650 − 1 fee − cost of 5 at 110.10 (550.50) = 98.50
        XCTAssertEqual(sold.realizedPnL, 98.50)
        XCTAssertEqual(ledger.realizedPnL, 98.50)
        XCTAssertEqual(ledger.cash, 10_000 - 2_202 + 649)
        XCTAssertEqual(ledger.position(Fx.aapl.id)?.costBasis, 2_202 - 550.50)
        XCTAssertEqual(ledger.feesPaid, 3)
    }

    func testSellingEverythingRemovesThePositionAndItsWholeCost() {
        var ledger = Ledger(name: "Test", kind: .manualPaper, startingCash: 1_000, createdAt: Fx.now)
        ledger.apply(fill(.buy, 0.333333, 300.01, ledger: ledger, instrument: Fx.btc))
        let cost = ledger.position(Fx.btc.id)!.costBasis
        let sold = ledger.apply(fill(.sell, 0.333333, 310, ledger: ledger, instrument: Fx.btc))
        XCTAssertNil(ledger.position(Fx.btc.id))
        XCTAssertEqual(sold.realizedPnL, Rounding.money(Rounding.money(0.333333 * 310) - cost))
        // With no position left, equity is exactly cash: nothing was lost to rounding.
        XCTAssertEqual(ledger.equity, ledger.cash)
        XCTAssertEqual(ledger.cash, Rounding.money(1_000 + (sold.realizedPnL ?? 0)))
        XCTAssertNotNil(ledger.lastExitAt[Fx.btc.id])
    }

    func testEquityIsCashPlusPositionsAtTheLastQuote() {
        var ledger = Ledger(name: "Test", kind: .manualPaper, startingCash: 5_000, createdAt: Fx.now)
        ledger.apply(fill(.buy, 10, 100, ledger: ledger))
        ledger.mark(quotes: [Fx.aapl.id: Fx.quote(Fx.aapl, last: 110)], now: Fx.now)
        XCTAssertEqual(ledger.equity, 4_000 + 1_100)
        XCTAssertEqual(ledger.unrealizedPnL, 100)
        XCTAssertEqual(ledger.peakEquity, 5_100)
        ledger.mark(quotes: [Fx.aapl.id: Fx.quote(Fx.aapl, last: 90)], now: Fx.now.addingTimeInterval(60))
        XCTAssertClose(ledger.drawdownPct, (5_100 - 4_900) / 5_100 * 100)
    }

    func testSyntheticQuotesNeverRepriceAPosition() {
        var ledger = Ledger(name: "Test", kind: .manualPaper, startingCash: 5_000, createdAt: Fx.now)
        ledger.apply(fill(.buy, 10, 100, ledger: ledger))
        ledger.mark(quotes: [Fx.aapl.id: Fx.quote(Fx.aapl, last: 500, provenance: .synthetic)], now: Fx.now)
        XCTAssertEqual(ledger.position(Fx.aapl.id)?.lastPrice, 100)
    }

    func testDailyCountersResetOnTheNextTradingDay() {
        var ledger = Ledger(name: "Test", kind: .manualPaper, startingCash: 5_000, createdAt: Fx.now)
        ledger.apply(fill(.buy, 10, 100, ledger: ledger))
        ledger.apply(fill(.sell, 10, 90, ledger: ledger))
        XCTAssertEqual(ledger.realizedToday, -100)
        XCTAssertEqual(ledger.notionalToday, 1_900)
        ledger.rollDayIfNeeded(now: Fx.now.addingTimeInterval(86_400))
        XCTAssertEqual(ledger.realizedToday, 0)
        XCTAssertEqual(ledger.notionalToday, 0)
        XCTAssertEqual(ledger.dayStartEquity, 4_900)
        XCTAssertEqual(ledger.realizedPnL, -100)      // the lifetime figure is untouched
    }
}

final class AuditLogTests: XCTestCase {
    func testChainVerifiesAndSurvivesSaveAndLoad() throws {
        var log = AuditLog()
        for i in 0..<5 {
            log.append(time: Fx.now.addingTimeInterval(Double(i) + 0.123), actor: .user, kind: .orderSubmitted,
                       summary: "Order \(i)", mode: .paper, details: ["n": String(i), "a": "x"])
        }
        XCTAssertTrue(log.verify().isIntact)
        XCTAssertEqual(log.events.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(log.events[1].previousHash, log.events[0].hash)
        let reloaded = try TradingCodec.decoder().decode(AuditLog.self, from: TradingCodec.encoder().encode(log))
        XCTAssertTrue(reloaded.verify().isIntact)
        XCTAssertEqual(reloaded.lastHash, log.lastHash)
    }

    func testEditingOrRemovingAnEventBreaksTheChain() throws {
        var log = AuditLog()
        for i in 0..<4 { log.append(time: Fx.now, actor: .system, kind: .orderFilled, summary: "Fill \(i)", details: ["price": "100"]) }
        let json = String(data: try TradingCodec.encoder().encode(log), encoding: .utf8)!

        let edited = json.replacingOccurrences(of: "Fill 1", with: "Fill 9")
        let editedLog = try TradingCodec.decoder().decode(AuditLog.self, from: Data(edited.utf8))
        XCTAssertEqual(editedLog.verify(), AuditVerification(isIntact: false, brokenAtSequence: 2, eventCount: 4))

        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var events = object["events"] as! [[String: Any]]
        events.remove(at: 1)
        object["events"] = events
        let removed = try TradingCodec.decoder().decode(AuditLog.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(removed.verify().isIntact)
        XCTAssertEqual(removed.verify().brokenAtSequence, 3)
    }

    func testArchivingKeepsTheRemainingChainVerifiable() {
        var log = AuditLog()
        for i in 0..<10 { log.append(time: Fx.now, actor: .system, kind: .signalGenerated, summary: "S\(i)") }
        let removed = log.archive(keepingLast: 4)
        XCTAssertEqual(removed.count, 6)
        XCTAssertEqual(log.events.first?.sequence, 7)
        XCTAssertTrue(log.verify().isIntact)
        log.append(time: Fx.now, actor: .system, kind: .signalGenerated, summary: "after")
        XCTAssertEqual(log.events.last?.sequence, 11)
        XCTAssertTrue(log.verify().isIntact)
    }
}
