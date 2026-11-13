import Foundation
import XCTest
@testable import TradingCore

final class PrivateMarketsTests: XCTestCase {
    func testOwnershipEvidenceRoundTripsAndLegacyHoldingsStillDecode() throws {
        let companyID = UUID()
        let evidenceID = UUID()
        let date = Date(timeIntervalSince1970: 100_000)
        let holding = PrivateHolding(name: "Venture Fund", assetClass: .ventureFund, currency: "AUD",
                                     catalogueCompanyID: companyID, ownershipEvidenceID: evidenceID, ownershipReviewedOn: date)
        let data = try JSONEncoder().encode(holding)
        XCTAssertEqual(try JSONDecoder().decode(PrivateHolding.self, from: data), holding)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["catalogueCompanyID", "ownershipEvidenceID", "ownershipReviewedOn"] { legacy.removeValue(forKey: field) }
        let decoded = try JSONDecoder().decode(PrivateHolding.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.id, holding.id)
        XCTAssertNil(decoded.catalogueCompanyID)
        XCTAssertNil(decoded.ownershipEvidenceID)
        XCTAssertNil(decoded.ownershipReviewedOn)
    }

    func testDilutionAndInvalidRoundTerms() {
        XCTAssertEqual(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                             nextRoundPostMoney: 2_000_000, nextRoundRaise: 500_000), Decimal(string: "0.00375"))
        XCTAssertNil(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                           nextRoundPostMoney: 500_000, nextRoundRaise: 500_000))
        XCTAssertNil(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                           nextRoundPostMoney: nil, nextRoundRaise: 500_000))
    }

    func testPendingCallAndDatedFundMetrics() throws {
        let initial = Date(timeIntervalSince1970: 0)
        let year = initial.addingTimeInterval(365 * 86_400)
        let fund = PrivateHolding(name: "Test fund", assetClass: .ventureFund, currency: "AUD", commitment: 2_000,
                                  valuations: [.init(value: 1_100, date: year, source: "Statement", method: "NAV")],
                                  cashFlows: [.init(kind: .contribution, amount: 1_000, date: initial, settled: true, source: "Statement"),
                                              .init(kind: .distribution, amount: 200, date: year, settled: true, source: "Statement"),
                                              .init(kind: .capitalCall, amount: 500, date: year, settled: false, source: "Notice")])
        let metrics = fund.metrics(asOf: year)
        XCTAssertEqual(metrics.paid, 1_000)
        XCTAssertEqual(metrics.uncalled, 1_000)
        XCTAssertEqual(metrics.pendingCalls, 500)
        XCTAssertEqual(metrics.multiple, Decimal(string: "1.3"))
        XCTAssertEqual(metrics.dpi, Decimal(string: "0.2"))
        XCTAssertEqual(try XCTUnwrap(metrics.xirr), 0.30, accuracy: 0.00001)
        XCTAssertFalse(try XCTUnwrap(fund.valuation(asOf: year)).isStale(asOf: year))
        XCTAssertTrue(try XCTUnwrap(fund.valuation(asOf: year)).isStale(asOf: year.addingTimeInterval(91 * 86_400)))
    }

    func testSaleSeparatesRealizedAndUnrealizedGainWhenBasisIsKnown() {
        let first = Date(timeIntervalSince1970: 0)
        let mark = first.addingTimeInterval(86_400)
        var holding = PrivateHolding(name: "Test startup", assetClass: .startupEquity, currency: "AUD",
                                     valuations: [.init(value: 900, date: mark, source: "Statement", method: "Fair value")],
                                     cashFlows: [.init(kind: .contribution, amount: 1_000, date: first, settled: true, source: "Statement"),
                                                 .init(kind: .sale, amount: 600, date: mark, settled: true, source: "Statement", disposedCost: 400)])
        XCTAssertEqual(holding.metrics(asOf: mark).realizedGain, 200)
        XCTAssertEqual(holding.metrics(asOf: mark).unrealizedGain, 300)
        holding.cashFlows[1].disposedCost = nil
        XCTAssertNil(holding.metrics(asOf: mark).realizedGain)
        XCTAssertNil(holding.metrics(asOf: mark).unrealizedGain)
        XCTAssertEqual(holding.metrics(asOf: mark).netGain, 500)
    }

    func testLaterCashFlowSuppressesRatiosAndUnknownValuationRemainsUnknown() {
        let earlier = Date(timeIntervalSince1970: 1)
        let later = earlier.addingTimeInterval(86_400)
        var holding = PrivateHolding(name: "Test startup", assetClass: .startupEquity, currency: "USD",
                                     cashFlows: [.init(kind: .contribution, amount: 1_000, date: later, settled: true, source: "Statement")])
        XCTAssertNil(holding.metrics(asOf: later).multiple)
        holding.valuations = [.init(value: 500, date: earlier, source: "Statement", method: "Fair value")]
        XCTAssertNil(holding.metrics(asOf: later).netGain)
        XCTAssertNil(holding.metrics(asOf: later).xirr)
        XCTAssertEqual(holding.valuation(asOf: later)?.value, 500)
    }
}
