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
        let manual = PrivateHolding(name: "Tracked fund", assetClass: .ventureFund, currency: "USD",
                                    valuations: [.init(value: 100, date: Date(timeIntervalSince1970: 1_750_000_000),
                                                       source: "Manual", method: "Statement")])
        let snapshot = try XCTUnwrap(PrivateFundSnapshot.make(
            reference: "fund", name: "Tracked fund", assetClass: .ventureFund, currency: "USD", asOf: "2026-11-01",
            netAssetValue: "125", commitment: nil, paidIn: nil, distributions: nil,
            replacesManualHoldingID: manual.id, retrievedAt: retrieved
        ))
        let confirmed = PrivateHolding(name: "Confirmed fund", assetClass: .ventureFund, currency: "AUD")
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [manual], confirmed: [confirmed], snapshots: [snapshot]).map(\.id),
                       [confirmed.id, snapshot.id])
        var changed = manual
        changed.currency = "EUR"
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [changed], confirmed: [], snapshots: [snapshot]).map(\.id),
                       [manual.id])
        var revised = manual
        revised.valuations.append(.init(value: 140, date: retrieved, source: "Manual", method: "Newer statement"))
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [revised], confirmed: [], snapshots: [snapshot], asOf: retrieved), [revised])
        XCTAssertEqual(PrivateFundSnapshot.allocation(manual: [manual], confirmed: [], snapshots: []), [manual])
    }

    private func make(date: String = "2026-11-01", currency: String = "USD",
                      netAssetValue: String? = "22000", paidIn: String? = nil, distributions: String? = nil) -> PrivateFundSnapshot? {
        PrivateFundSnapshot.make(reference: "capital-account-a", name: "Venture fund", assetClass: .ventureFund,
                                 currency: currency, asOf: date, netAssetValue: netAssetValue, commitment: nil,
                                 paidIn: paidIn, distributions: distributions, retrievedAt: retrieved)
    }
}
