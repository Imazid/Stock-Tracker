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
}
