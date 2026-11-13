import Foundation
import XCTest
@testable import TradingCore

final class ProviderPrivateHoldingTests: XCTestCase {
    func testProviderStatementUsesLatestRevisionAndDatedCashFlows() throws {
        let record = try decode("""
        {
          "id":"00000000-0000-0000-0000-000000000001", "name":"Example venture fund",
          "asset_class":"Venture fund", "currency":"AUD", "committed_amount":2000,
          "settled_amount":1000, "settled_on":0, "settlement_source":"Settlement record",
          "confirmed_at":3600, "commitment":{"provider":"birchal","provider_reference":"fixture"},
          "marks":[
            {"id":"00000000-0000-0000-0000-000000000002","value":1500,"valued_on":31536000,
             "source":"Revised statement","methodology":"NAV"},
            {"id":"00000000-0000-0000-0000-000000000003","value":1400,"valued_on":31536000,
             "source":"Prior statement","methodology":"NAV"}
          ],
          "calls":[{"id":"00000000-0000-0000-0000-000000000004","amount":200,
             "due_on":20000000,"settled_on":15000000,"source":"Provider"}],
          "distributions":[{"id":"00000000-0000-0000-0000-000000000005","amount":100,
             "received_on":31536000,"source":"Provider"}]
        }
        """)
        let holding = record.holding
        XCTAssertTrue(record.canCalculatePerformance)
        XCTAssertEqual(holding.valuations.count, 1)
        XCTAssertEqual(holding.valuation()?.value, 1500)
        XCTAssertEqual(holding.cashFlows.first?.originalDueDate, Date(timeIntervalSince1970: 20000000))
        let metrics = holding.metrics()
        XCTAssertEqual(metrics.paid, 1200)
        XCTAssertEqual(metrics.returned, 100)
        XCTAssertEqual(metrics.uncalled, 800)
        XCTAssertEqual(metrics.netGain, 400)
        XCTAssertNotNil(metrics.xirr)
    }

    func testMissingSettlementDateNeverBecomesAContributionOnConfirmationDate() throws {
        let record = try decode("""
        {
          "id":"00000000-0000-0000-0000-000000000001", "name":"Example",
          "asset_class":"Startup equity", "currency":"AUD",
          "settled_amount":1000, "confirmed_at":3600,
          "commitment":{"provider":"birchal","provider_reference":"fixture"},
          "marks":[], "calls":[], "distributions":[]
        }
        """)
        XCTAssertTrue(record.hasCompleteActivity)
        XCTAssertFalse(record.canCalculatePerformance)
        XCTAssertTrue(record.holding.cashFlows.isEmpty)
    }

    func testPartialSaleNeedsAStatementAfterTheSaleAndItsRevision() throws {
        let record = try saleRecord(remaining: 70, saleUnits: 30, includeNewMark: false)
        XCTAssertTrue(record.canCalculatePerformance)
        XCTAssertFalse(record.hasExited)
        XCTAssertEqual(record.holding.units, 70)
        XCTAssertNil(record.holding.ownershipPercent)
        XCTAssertNil(record.holding.valuation())
        XCTAssertEqual(record.holding.valuations.count, 2)
        XCTAssertEqual(record.holding.metrics().realizedGain, 200)
        XCTAssertNil(record.holding.metrics().multiple)
        XCTAssertEqual(try saleRecord(remaining: 70, saleUnits: 30, includeNewMark: true).holding.valuation()?.value, 850)
    }

    func testFullExitKeepsHistoricalCashFlowsAndIgnoresThePreviousMark() throws {
        let record = try saleRecord(remaining: 0, saleUnits: 100, exitSource: "Exit statement")
        XCTAssertTrue(record.hasExited)
        let holding = record.holding
        XCTAssertEqual(holding.valuation()?.value, 0)
        XCTAssertEqual(holding.valuation()?.source, "Exit statement")
        XCTAssertEqual(holding.cashFlows.first(where: { $0.kind == .sale })?.disposedUnits, 100)
        let metrics = holding.metrics()
        XCTAssertEqual(metrics.returned, 550)
        XCTAssertEqual(metrics.netGain, -450)
        XCTAssertNil(metrics.realizedGain)
        XCTAssertEqual(metrics.unrealizedGain, 0)
        XCTAssertEqual(metrics.dpi, Decimal(string: "0.05"))
        XCTAssertNotNil(metrics.xirr)
    }

    func testSaleReversalMakesOlderMarksUnavailableUntilTheProviderUpdatesValue() {
        let date = Date(timeIntervalSince1970: 10_000)
        var holding = PrivateHolding(name: "Reopened", assetClass: .startupEquity, currency: "AUD", units: 100,
                                     valuations: [.init(value: 900, date: date, source: "Statement", method: "Fair value",
                                                        providerEventAt: date)],
                                     dispositionRevisionAt: date.addingTimeInterval(60))
        XCTAssertNil(holding.valuation())
        let updated = date.addingTimeInterval(86_400)
        holding.valuations.append(.init(value: 1_400, date: updated, source: "Updated statement", method: "Fair value",
                                        providerEventAt: updated))
        XCTAssertEqual(holding.valuation()?.value, 1_400)
    }

    func testCapitalCallRemindersOnlyScheduleFutureUnsettledCalls() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12)))
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: now))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        let later = PrivateCashFlow(kind: .capitalCall, amount: 100, date: future, settled: false, source: "Notice")
        let next = PrivateCashFlow(kind: .capitalCall, amount: 100, date: tomorrow, settled: false, source: "Notice")
        let paid = PrivateCashFlow(kind: .capitalCall, amount: 100, date: tomorrow, settled: true, source: "Notice")
        let overdue = PrivateCashFlow(kind: .capitalCall, amount: 100, date: now, settled: false, source: "Notice")
        let holding = PrivateHolding(name: "Venture", assetClass: .ventureFund, currency: "AUD",
                                     cashFlows: [later, next, paid, overdue])
        let reminders = PrivateMath.capitalCallReminders(in: [holding], now: now, calendar: calendar)
        XCTAssertEqual(reminders.map(\.callID), [next.id, later.id])
        XCTAssertEqual(reminders.map { calendar.component(.day, from: $0.date) }, [15, 16])
        XCTAssertEqual(reminders.map { calendar.component(.hour, from: $0.date) }, [9, 9])
    }

    private func decode(_ value: String) throws -> ProviderPrivateHolding {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ProviderPrivateHolding.self, from: Data(value.utf8))
    }

    private func saleRecord(remaining: Int, saleUnits: Int, exitSource: String? = nil,
                            includeNewMark: Bool = false) throws -> ProviderPrivateHolding {
        let source = exitSource.map { "\"\($0)\"" } ?? "null"
        let basis = remaining == 0 ? "null" : "300"
        return try decode("""
        {
          "id":"00000000-0000-0000-0000-000000000001", "name":"Example fund",
          "asset_class":"Venture fund", "currency":"AUD", "units":100, "ownership_percent":0.1,
          "remaining_units":\(remaining), "last_disposition_on":31536000, "disposition_revision_at":31795200,
          "exit_source":\(source),
          "settled_amount":1000, "settled_on":0, "settlement_source":"Opening statement",
          "confirmed_at":3600, "commitment":{"provider":"test","provider_reference":"fixture"},
          "marks":[
            {"id":"00000000-0000-0000-0000-000000000002","value":850,"valued_on":31622400,
             "source":"Later statement","methodology":"NAV","provider_event_at":\(includeNewMark ? "31881600" : "31708800")},
            {"id":"00000000-0000-0000-0000-000000000003","value":1450,"valued_on":31536000,
             "source":"Same-day statement","methodology":"NAV","provider_event_at":31881600}
          ],
          "calls":[], "distributions":[{"id":"00000000-0000-0000-0000-000000000004","amount":50,
           "received_on":31881600,"source":"Final distribution"}],
          "dispositions":[{"id":"00000000-0000-0000-0000-000000000005","sold_units":\(saleUnits),
           "net_proceeds":500,"disposed_cost":\(basis),"settled_on":31536000,"source":"Provider sale receipt"}]
        }
        """)
    }
}
