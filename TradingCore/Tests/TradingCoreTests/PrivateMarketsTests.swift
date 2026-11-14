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
        for field in ["catalogueCompanyID", "ownershipEvidenceID", "ownershipReviewedOn", "matchingProviderHoldingID"] {
            legacy.removeValue(forKey: field)
        }
        let decoded = try JSONDecoder().decode(PrivateHolding.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.id, holding.id)
        XCTAssertNil(decoded.catalogueCompanyID)
        XCTAssertNil(decoded.ownershipEvidenceID)
        XCTAssertNil(decoded.ownershipReviewedOn)
        XCTAssertNil(decoded.matchingProviderHoldingID)
    }

    func testDilutionAndInvalidRoundTerms() {
        XCTAssertEqual(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                             nextRoundPostMoney: 2_000_000, nextRoundRaise: 500_000), Decimal(string: "0.00375"))
        XCTAssertNil(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                           nextRoundPostMoney: 500_000, nextRoundRaise: 500_000))
        XCTAssertNil(PrivateMath.ownership(investment: 5_000, postMoney: 1_000_000,
                                           nextRoundPostMoney: nil, nextRoundRaise: 500_000))
    }

    func testConversationalOwnershipUsesExplicitValuationTerms() throws {
        let post = try XCTUnwrap(PrivateScenarioQuestion("What percentage ownership would a $5,000 investment represent at a $1m post-money valuation?"))
        XCTAssertEqual(post.investment, 5_000)
        XCTAssertEqual(post.postMoney, 1_000_000)
        XCTAssertEqual(post.initialOwnership, Decimal(string: "0.005"))

        let pre = try XCTUnwrap(PrivateScenarioQuestion("What ownership would I get if I invest AUD 5k at AUD 800k pre-money and the round raises AUD 200k?"))
        XCTAssertEqual(pre.initialOwnership, post.initialOwnership)
        XCTAssertEqual(pre.currency, "AUD")
        let stake = try XCTUnwrap(PrivateScenarioQuestion("How much equity would I get for £5k at £1m post-money?"))
        XCTAssertEqual(stake.initialOwnership, post.initialOwnership)
        XCTAssertEqual(stake.currency, "GBP")

        let contextual = try XCTUnwrap(PrivateScenarioQuestion("What percentage ownership would a $5,000 investment represent at this valuation?"))
        XCTAssertEqual(contextual.investment, 5_000)
        XCTAssertNil(contextual.initialOwnership)
        XCTAssertNil(PrivateScenarioQuestion("Show my private investment exposure alongside my listed stocks"))
    }

    func testConversationalDilutionUsesExistingStakeAndRoundTerms() throws {
        let query = try XCTUnwrap(PrivateScenarioQuestion("How will my 2% stake dilute if the round raises $500k at a $2m post-money valuation?"))
        XCTAssertEqual(query.initialOwnership, Decimal(string: "0.02"))
        XCTAssertEqual(query.ownershipAfterRound, Decimal(string: "0.015"))
        XCTAssertNil(PrivateScenarioQuestion("What’s my dilution from 2% if the round raises $2m at a $2m post-money valuation?")?.ownershipAfterRound)
        XCTAssertNil(PrivateScenarioQuestion("What’s my dilution from 101% if the round raises $500k at a $2m post-money valuation?")?.initialOwnership)
        XCTAssertNil(PrivateScenarioQuestion("What dilution should I expect with a 10% option pool if the round raises $500k at $2m post-money?")?.ownershipAfterRound)
        XCTAssertNil(PrivateScenarioQuestion("Explain the dilution implications of another financing round.")?.ownershipAfterRound)
    }

    func testConversationalOwnershipRejectsAmbiguousAmounts() {
        let questions = [
            "What ownership would an AUD 5k investment buy at USD 1m post-money?",
            "What ownership would a 5k AUD investment buy at 1m USD post-money?",
            "What ownership would a $5k investment buy at a €1m post-money valuation?",
            "What ownership would a $5k to $10k investment buy at a $1m post-money valuation?",
            "What ownership would a -$5k investment buy at a $1m post-money valuation?",
            "What ownership would a $5k investment buy at a $1m valuation?",
        ]
        for question in questions {
            XCTAssertNil(PrivateScenarioQuestion(question)?.initialOwnership, question)
        }
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
