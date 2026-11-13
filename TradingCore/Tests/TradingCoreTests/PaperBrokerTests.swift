import XCTest
@testable import TradingCore

final class PaperBrokerTests: XCTestCase {
    private let config = PaperBrokerConfig()

    private func order(_ side: OrderSide = .buy, type: OrderType = .market, quantity: Double = 10, limit: Double? = nil,
                       stop: Double? = nil, tif: TimeInForce = .day, instrument: Instrument = Fx.aapl) -> Order {
        Order(clientOrderID: UUID().uuidString, ledgerID: UUID(), instrument: instrument, side: side, type: type,
              quantity: quantity, limitPrice: limit, stopPrice: stop, timeInForce: tif, source: .manual, mode: .paper,
              status: .accepted, referencePrice: 100, createdAt: Fx.now)
    }

    private func match(_ order: Order, last: Double = 100, spreadBps: Double? = 2, open: Bool = true,
                       quoteTime: Date = Fx.now, dayVolume: Double? = nil) -> PaperBroker.Match? {
        PaperBroker.match(order: order, quote: Fx.quote(order.instrument, last: last, spreadBps: spreadBps, time: quoteTime, dayVolume: dayVolume),
                          marketOpen: open, now: Fx.now, config: config)
    }

    func testMarketOrdersTradeAtTheAskAndTheBid() {
        let buy = match(order(.buy))!
        XCTAssertEqual(buy.fillPrice, 100.01)
        XCTAssertEqual(buy.fillQuantity, 10)
        XCTAssertEqual(buy.newStatus, .filled)
        XCTAssertEqual(buy.fee, 0)
        XCTAssertEqual(match(order(.sell))!.fillPrice, 99.99)
    }

    func testAOneSidedFeedUsesAModelledSpreadAndSaysSo() {
        let buy = match(order(.buy), spreadBps: nil)!
        XCTAssertEqual(buy.fillPrice, 100.02)             // last + 2 bps
        XCTAssertTrue(buy.note?.contains("modelled spread") == true)
        XCTAssertEqual(match(order(.sell), spreadBps: nil)!.fillPrice, 99.98)
    }

    func testLimitOrdersRestUntilThePriceIsAvailable() {
        XCTAssertNil(match(order(.buy, type: .limit, limit: 99)))                  // ask 100.01 is above the limit
        let improved = match(order(.buy, type: .limit, limit: 100.5))!
        XCTAssertEqual(improved.fillPrice, 100.01)                                  // fills at the better market price
        XCTAssertNil(match(order(.sell, type: .limit, limit: 101)))
        XCTAssertEqual(match(order(.sell, type: .limit, limit: 99.5))!.fillPrice, 99.99)
    }

    func testStopsWaitForTheirTrigger() {
        let stop = order(.sell, type: .stop, stop: 95)
        XCTAssertNil(match(stop, last: 100))
        let triggered = match(stop, last: 94)!
        XCTAssertTrue(triggered.stopTriggered)
        XCTAssertEqual(triggered.newStatus, .filled)
        XCTAssertEqual(triggered.fillPrice, Rounding.round(94 * (1 - 0.0001), places: 4))

        // A stop-limit that triggers but can't trade at its limit stays open, marked as triggered.
        let stopLimit = order(.buy, type: .stopLimit, limit: 105.2, stop: 105)
        XCTAssertNil(match(stopLimit, last: 104))
        let waiting = match(stopLimit, last: 105.5)!
        XCTAssertTrue(waiting.stopTriggered)
        XCTAssertEqual(waiting.fillQuantity, 0)
        XCTAssertEqual(waiting.newStatus, .accepted)
        XCTAssertEqual(match(order(.buy, type: .stopLimit, limit: 106, stop: 105), last: 105.5)!.newStatus, .filled)
    }

    func testLargeOrdersFillInPartsAndTimeInForceDecidesTheRest() {
        // 1% of a 10,000-share day is 100 shares per match.
        let day = match(order(.buy, quantity: 250), dayVolume: 10_000)!
        XCTAssertEqual(day.fillQuantity, 100)
        XCTAssertEqual(day.newStatus, .partiallyFilled)

        let ioc = match(order(.buy, quantity: 250, tif: .ioc), dayVolume: 10_000)!
        XCTAssertEqual(ioc.fillQuantity, 100)
        XCTAssertEqual(ioc.newStatus, .canceled)

        let fok = match(order(.buy, quantity: 250, tif: .fok), dayVolume: 10_000)!
        XCTAssertEqual(fok.fillQuantity, 0)
        XCTAssertEqual(fok.newStatus, .canceled)
        XCTAssertEqual(match(order(.buy, quantity: 50, tif: .fok), dayVolume: 10_000)!.newStatus, .filled)
    }

    func testNothingTradesWhileTheMarketIsShutOrTheQuoteIsStale() {
        XCTAssertNil(match(order(.buy), open: false))
        XCTAssertEqual(match(order(.buy, tif: .ioc), open: false)?.newStatus, .canceled)
        XCTAssertNil(match(order(.buy), quoteTime: Fx.now.addingTimeInterval(-7_200)))
        XCTAssertEqual(match(order(.buy, tif: .fok), quoteTime: Fx.now.addingTimeInterval(-7_200))?.newStatus, .canceled)
    }

    func testAFinishedOrderNeverTradesAgain() {
        var done = order(.buy)
        done.transition(to: .filled, at: Fx.now)
        XCTAssertNil(match(done))
    }

    func testCryptoPaysATakerFeeAndTradesInSmallFractions() {
        let btc = order(.buy, quantity: 0.012_345_67, instrument: Fx.btc)
        let result = match(btc, last: 64_000, spreadBps: 4)!
        XCTAssertEqual(result.fillQuantity, 0.012_345_67)
        XCTAssertEqual(result.fee, Rounding.money(Rounding.money(0.012_345_67 * result.fillPrice) * 0.0025))
        XCTAssertEqual(PaperBroker.rules(for: Fx.btc).quantityIncrement, 0.000_000_01)
        XCTAssertFalse(PaperBroker.rules(for: Fx.bhp).fractionable)
        XCTAssertTrue(PaperBroker.rules(for: Fx.aapl).fractionable)
    }

    func testOrderExpiry() {
        XCTAssertEqual(PaperBroker.expiry(for: .day, venue: .us, placedAt: Fx.now), Fx.date("2026-11-10T21:00:00Z"))
        // Placed on Saturday: good until Monday's close.
        XCTAssertEqual(PaperBroker.expiry(for: .day, venue: .us, placedAt: Fx.date("2026-11-14T16:00:00Z")), Fx.date("2026-11-16T21:00:00Z"))
        XCTAssertEqual(PaperBroker.expiry(for: .day, venue: .crypto, placedAt: Fx.now), Fx.now.addingTimeInterval(86_400))
        XCTAssertEqual(PaperBroker.expiry(for: .gtc, venue: .us, placedAt: Fx.now), Fx.now.addingTimeInterval(90 * 86_400))
        XCTAssertNil(PaperBroker.expiry(for: .ioc, venue: .us, placedAt: Fx.now))
    }

    func testNoLiveVenueCanExecute() {
        for venue in LiveVenues.all {
            XCTAssertFalse(venue.isExecutionEnabled, venue.adapterID)
            XCTAssertNotNil(venue.disabledReason)
        }
        XCTAssertFalse(LiveVenues.snapTrade.permissions.contains(.trade))
        XCTAssertFalse(LiveVenues.alpaca.venues.contains(.asx))
        XCTAssertTrue(PaperBroker.capabilities.isExecutionEnabled)
        XCTAssertEqual(PaperBroker.capabilities.environment, .paper)
    }
}
