import Foundation
import XCTest
@testable import TradingCore

final class PrivateFundSnapshotTests: XCTestCase {
    private let retrieved = Date(timeIntervalSince1970: 1_800_000_000)

    func testFindsFieldsFromOneRecordWithoutCombiningArrayRows() throws {
        let json = Data("""
            {"rows":[{"id":"A", "name":"Fund A","as_of":"2026-11-01","currency":"USD","balances":{"nav":2400.25},
            "editable":true}, {"id":"B","name":"Fund B","as_of":"2026-11-02","currency":"AUD","balances":{"nav":"540"}}]}
            """.utf8)
        let rows = PrivateFundSnapshot.records(in: json)
        XCTAssertEqual(rows.map(\.id), ["Response › rows[1]", "Response › rows[2]"])
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.fields.first { $0.id == "balances › nav" }?.value, "2400.25")
        XCTAssertFalse(first.fields.contains { $0.id == "editable" || $0.value == "Fund B" })
        XCTAssertTrue(PrivateFundSnapshot.records(in: Data("rendered prose".utf8)).isEmpty)
        let block = try XCTUnwrap(String(data: json, encoding: .utf8))
        let textRecords = PrivateFundSnapshot.statementRecords(structured: nil, text: ["Provider summary", block])
        XCTAssertEqual(textRecords.map(\.id), ["Response 2 › Response › rows[1]", "Response 2 › Response › rows[2]"])
        XCTAssertEqual(PrivateFundSnapshot.statementRecords(structured: json, text: [block]), rows)
    }

    func testOnlyDatedNetAssetValueEntersAllocation() throws {
        let report = try XCTUnwrap(make(netAssetValue: "28000.125", paidIn: "17000", distributions: "0"))
        XCTAssertEqual(report.allocationHolding.valuation(asOf: retrieved)?.value, Decimal(string: "28000.125"))
        XCTAssertEqual(report.distributions, 0)
        XCTAssertTrue(report.allocationHolding.cashFlows.isEmpty)
        let balancesOnly = try XCTUnwrap(make(netAssetValue: nil, paidIn: "17000"))
        XCTAssertNil(balancesOnly.allocationHolding.valuation(asOf: retrieved))
        XCTAssertNil(make(netAssetValue: nil, paidIn: nil))
    }

    func testRejectsAmbiguousAmountsAndInvalidDates() {
        for amount in ["USD 28000", "28,000", "1e5", "-2", "∞"] {
            XCTAssertNil(make(netAssetValue: amount))
        }
        XCTAssertNil(make(date: "2026-02-30"))
        XCTAssertNil(make(date: "2030-01-01"))
        XCTAssertNil(make(currency: "XXX"))
        XCTAssertNil(make(netAssetValue: "24000", paidIn: "unknown"))
    }

    func testReimportPreservesIdentityAndRefusesEarlierStatementOrCurrencyChange() throws {
        let old = try XCTUnwrap(make())
        let newer = try XCTUnwrap(make(date: "2026-11-07", netAssetValue: "24000"))
        let snapshots = try XCTUnwrap(newer.replacing(in: [old]))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, old.id)
        XCTAssertEqual(snapshots.first?.netAssetValue, 24000)
        XCTAssertNil(old.replacing(in: snapshots))
        let otherCurrency = try XCTUnwrap(make(date: "2026-11-08", currency: "AUD"))
        XCTAssertNil(otherCurrency.replacing(in: snapshots))
    }

    func testLinkedSnapshotReplacesOnlyMatchingManualNAV() throws {
        let opening = Date(timeIntervalSince1970: 1_750_000_000)
        let manual = PrivateHolding(name: "Tracked fund", assetClass: .ventureFund, currency: "USD", commitment: 200, units: 5,
                                    valuations: [.init(value: 100, date: opening, source: "Manual", method: "Statement")],
                                    cashFlows: [.init(kind: .contribution, amount: 100, date: opening, settled: true, source: "Receipt")])
        let snapshot = try XCTUnwrap(PrivateFundSnapshot.make(
            reference: "fund", name: "Tracked fund", assetClass: .ventureFund, currency: "USD", asOf: "2026-11-01",
            netAssetValue: "125", commitment: "300", paidIn: "100", distributions: "0",
            replacesManualHoldingID: manual.id, retrievedAt: retrieved
        ))
        let confirmed = PrivateHolding(name: "Confirmed fund", assetClass: .ventureFund, currency: "AUD")
        let allocation = PrivateFundSnapshot.allocation(manual: [manual], confirmed: [confirmed], snapshots: [snapshot], asOf: retrieved)
        XCTAssertEqual(allocation.map(\.id), [manual.id, confirmed.id])
        let effective = try XCTUnwrap(allocation.first)
        XCTAssertEqual(effective.cashFlows, manual.cashFlows)
        XCTAssertEqual(effective.commitment, manual.commitment)
        XCTAssertEqual(effective.remainingUnits(asOf: retrieved), manual.units)
        XCTAssertEqual(effective.valuation(asOf: retrieved)?.source, PrivateFundSnapshot.source)
        XCTAssertEqual(effective.metrics(asOf: retrieved).multiple, 1.25)
        XCTAssertTrue(snapshot.agreesWithRecordedCashFlows(of: effective))
        XCTAssertFalse(snapshot.agreesWithRecordedCashFlows(of: snapshot.allocationHolding))
        var changed = manual
        changed.currency = "EUR"
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [changed], confirmed: [], snapshots: [snapshot]).map(\.id),
                       [manual.id])
        var revised = manual
        revised.valuations.append(.init(value: 140, date: retrieved, source: "Manual", method: "Newer statement"))
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [revised], confirmed: [], snapshots: [snapshot], asOf: retrieved), [revised])
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [manual], confirmed: [], snapshots: []), [manual])
        XCTAssertTrue(PrivateFundSnapshot.allocation(manual: [], confirmed: [], snapshots: [snapshot], asOf: retrieved).isEmpty)
    }

    func testLinkedProviderRecordReplacesOnlyThatPositionAndKeepsManualHistory() throws {
        let company = UUID()
        let mark = PrivateValuation(value: 100, date: retrieved, source: "Manual statement", method: "NAV")
        let call = PrivateCashFlow(kind: .capitalCall, amount: 10, date: retrieved, settled: false, source: "Manual notice")
        var manual = PrivateHolding(name: "Tracked fund", assetClass: .ventureFund, currency: "AUD",
                                    valuations: [mark], cashFlows: [call], catalogueCompanyID: company)
        let providerMark = PrivateValuation(value: 125, date: retrieved, source: "Provider statement", method: "NAV")
        let provider = PrivateHolding(name: "Fund statement", assetClass: .ventureFund, currency: "AUD",
                                      valuations: [providerMark], catalogueCompanyID: company)
        let other = PrivateHolding(name: "Another investment in the same fund", assetClass: .ventureFund,
                                   currency: "AUD", valuations: [mark], catalogueCompanyID: company)
        XCTAssertFalse(manual.linkProviderHolding(PrivateHolding(name: "Unrelated", assetClass: .ventureFund,
                                                                currency: "AUD", catalogueCompanyID: UUID())))
        XCTAssertFalse(manual.linkProviderHolding(PrivateHolding(name: "Foreign", assetClass: .ventureFund, currency: "USD")))
        XCTAssertTrue(manual.linkProviderHolding(provider))
        let restored = try JSONDecoder().decode(PrivateHolding.self, from: JSONEncoder().encode(manual))
        XCTAssertEqual(restored.matchingProviderHoldingID, provider.id)
        XCTAssertEqual(restored.valuations, [mark])
        XCTAssertEqual(restored.cashFlows, [call])
        let allocation = PrivateFundSnapshot.allocation(manual: [restored, other], confirmed: [provider], snapshots: [])
        XCTAssertEqual(allocation, [other, provider])
        XCTAssertEqual(allocation.compactMap { $0.valuation(asOf: retrieved)?.value }.reduce(0, +), 225)
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [restored, other], confirmed: [], snapshots: []), [other])
        manual.unlinkProviderHolding()
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [manual], confirmed: [provider], snapshots: []), [manual, provider])
    }

    func testLinkedFundStatementsRespectPartialSalesAndFullExitsAtTheAllocationDate() throws {
        var holding = PrivateHolding(name: "Tracked fund", assetClass: .ventureFund, currency: "USD", units: 100)
        let early = try XCTUnwrap(PrivateFundSnapshot.make(
            reference: "fund", name: holding.name, assetClass: holding.assetClass, currency: holding.currency,
            asOf: "2026-11-01", netAssetValue: "100", commitment: nil, paidIn: nil, distributions: nil,
            replacesManualHoldingID: holding.id, retrievedAt: retrieved
        ))
        let updated = try XCTUnwrap(PrivateFundSnapshot.make(
            reference: "fund", name: holding.name, assetClass: holding.assetClass, currency: holding.currency,
            asOf: "2026-11-03", netAssetValue: "90", commitment: nil, paidIn: nil, distributions: nil,
            replacesManualHoldingID: holding.id, retrievedAt: retrieved
        ))
        let partialDate = early.asOf.addingTimeInterval(86_400)
        XCTAssertTrue(holding.recordManualSale(amount: 40, date: partialDate, source: "Partial sale statement",
                                               soldUnits: 20, basis: nil, closesPosition: false, asOf: retrieved))
        XCTAssertTrue(holding.recordManualSale(amount: 80, date: updated.asOf.addingTimeInterval(86_400), source: "Final sale statement",
                                               soldUnits: nil, basis: nil, closesPosition: true, asOf: retrieved))

        let beforePartial = PrivateFundSnapshot.allocation(manual: [holding], confirmed: [], snapshots: [early], asOf: early.asOf)
        XCTAssertEqual(beforePartial.map(\.id), [holding.id])
        XCTAssertEqual(beforePartial.first?.valuation(asOf: early.asOf)?.value, 100)
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [holding], confirmed: [], snapshots: [early], asOf: partialDate), [holding])
        let afterPartial = PrivateFundSnapshot.allocation(manual: [holding], confirmed: [], snapshots: [early, updated], asOf: updated.asOf)
        XCTAssertEqual(afterPartial.map(\.id), [holding.id])
        XCTAssertEqual(afterPartial.first?.valuation(asOf: updated.asOf)?.value, 90)
        XCTAssertEqual(afterPartial.first?.remainingUnits(asOf: updated.asOf), 80)
        XCTAssertTrue(PrivateFundSnapshot.allocation(manual: [holding], confirmed: [], snapshots: [updated], asOf: retrieved).isEmpty)
    }

    func testAggregateReconciliationUsesDatedContributionsAndDistributionsThroughStatementDate() throws {
        let snapshot = try XCTUnwrap(make(paidIn: "100", distributions: "30"))
        let before = snapshot.asOf.addingTimeInterval(-86_400)
        let after = snapshot.asOf.addingTimeInterval(86_400)
        var holding = PrivateHolding(name: "Fund", assetClass: .ventureFund, currency: "USD", cashFlows: [
            .init(kind: .contribution, amount: 100, date: before, settled: true, source: "Receipt"),
            .init(kind: .capitalCall, amount: 40, date: snapshot.asOf, settled: false, source: "Notice"),
            .init(kind: .distribution, amount: 30, date: snapshot.asOf, settled: true, source: "Distribution"),
            .init(kind: .sale, amount: 22, date: snapshot.asOf, settled: true, source: "Proceeds"),
            .init(kind: .contribution, amount: 55, date: after, settled: true, source: "Later receipt"),
        ])
        XCTAssertTrue(snapshot.agreesWithRecordedCashFlows(of: holding))
        holding.cashFlows.remove(at: 2)
        XCTAssertFalse(snapshot.agreesWithRecordedCashFlows(of: holding))
    }

    private func make(date: String = "2026-11-01", currency: String = "USD",
                      netAssetValue: String? = "22000", paidIn: String? = nil, distributions: String? = nil) -> PrivateFundSnapshot? {
        PrivateFundSnapshot.make(reference: "capital-account-a", name: "Venture fund", assetClass: .ventureFund,
                                 currency: currency, asOf: date, netAssetValue: netAssetValue, commitment: nil,
                                 paidIn: paidIn, distributions: distributions, retrievedAt: retrieved)
    }
}
