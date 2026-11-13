import XCTest
@testable import TradingCore

// The contract between the server and the app in cloud mode: what trading-api's `state`
// action returns must decode with `TradingCodec.decoder()` straight into `TradingState`,
// verify as an audit chain, and drive a `TradingEngine` on the phone.
//
// Tests/Vectors/server-state.json is a real `state` answer from the local stack, written by
// the server's contract test (supabase/functions/tests/integration/state.test.ts) after a
// realistic scenario: a practice portfolio with a manual buy and a cancelled limit order,
// the kill switch on and off, and an agent with one approved-and-filled proposal and one
// still waiting. Regenerate it with
//
//     WRITE_SERVER_STATE=1 npx -y deno test --allow-net --allow-env --allow-read \
//       --allow-write=TradingCore/Tests/Vectors/server-state.json supabase/functions/tests/integration/state.test.ts

final class ServerStateContractTests: XCTestCase {
    /// The whole response body, exactly as the app receives it.
    private struct Response: Decodable {
        struct Payload: Decodable {
            let state: TradingState
            let asOf: Date
            let truncated: [String: Bool]
        }
        let ok: Bool
        let data: Payload
    }

    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vectors/server-state.json")

    private func load() throws -> Response {
        let data = try Data(contentsOf: Self.file)
        return try TradingCodec.decoder().decode(Response.self, from: data)
    }

    func testTheServersStateDecodesAsTradingState() throws {
        let response = try load()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data.truncated, ["runs": false, "signals": false, "proposals": false, "orders": false, "fills": false, "audit": false])
        XCTAssertGreaterThan(response.data.asOf.timeIntervalSince1970, 1_790_000_000)

        let state = response.data.state
        XCTAssertEqual(state.schemaVersion, TradingState.currentSchemaVersion)
        // Live trading is always off; the local stack serves fixtures, so the flag says so.
        XCTAssertFalse(state.accountPolicy.live.manualOrdersEnabled)
        XCTAssertFalse(state.accountPolicy.live.approvalAgentsEnabled)
        XCTAssertFalse(state.accountPolicy.live.autonomousAgentsEnabled)
        XCTAssertTrue(state.accountPolicy.allowFixtureData)
        XCTAssertFalse(state.accountPolicy.killSwitchEngaged, "turned on, then off again")
        XCTAssertNil(state.accountPolicy.killSwitchAt)

        XCTAssertEqual(state.ledgers.map(\.kind.rawValue).sorted(), ["agentPaper", "manualPaper"])
        XCTAssertEqual(state.agents.count, 1)
        XCTAssertEqual(state.agents.first?.status, .active)
        XCTAssertEqual(state.agents.first?.mode, .paper)
        XCTAssertEqual(state.orders.map(\.status.rawValue).sorted(), ["canceled", "filled", "filled"])
        XCTAssertEqual(state.fills.count, 2)
        XCTAssertEqual(state.proposals.map(\.status.rawValue).sorted(), ["pending", "submitted"])
        XCTAssertEqual(state.pendingProposals.count, 1)
        XCTAssertEqual(state.signals.count, 2)
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.knownClientOrderIDs, Set(state.orders.map(\.clientOrderID)))
        XCTAssertTrue(state.quotes.isEmpty)
        XCTAssertTrue(state.orders.allSatisfy { $0.mode == .paper })

        // The approved proposal points at its filled order, and that order's fill is in the list.
        let submitted = try XCTUnwrap(state.proposals.first { $0.status == .submitted })
        let order = try XCTUnwrap(state.orders.first { $0.id == submitted.orderID })
        XCTAssertEqual(order.status, .filled)
        XCTAssertTrue(state.fills.contains { $0.orderID == order.id })

        // The manual portfolio holds the bought BTC; cash went down by what it cost.
        let manual = try XCTUnwrap(state.manualLedgers.first)
        XCTAssertEqual(manual.positions.map(\.instrument.symbol), ["BTC"])
        XCTAssertLessThan(manual.cash, manual.startingCash)
    }

    func testTheAuditWindowVerifiesWithTheCoresOwnRule() throws {
        let state = try load().data.state
        XCTAssertEqual(state.audit.verify(), AuditVerification(isIntact: true, brokenAtSequence: nil, eventCount: state.audit.events.count))
        XCTAssertEqual(state.audit.events.map(\.sequence), Array((state.audit.baseSequence + 1)...(state.audit.baseSequence + state.audit.events.count)))
        let kinds = Set(state.audit.events.map(\.kind))
        for kind: AuditKind in [.portfolioCreated, .orderFilled, .orderCanceled, .killSwitchEngaged, .killSwitchReleased, .agentCreated, .proposalApproved] {
            XCTAssertTrue(kinds.contains(kind), "\(kind) is in the window")
        }
    }

    func testAnEngineBuiltFromItCanPreviewAnOrder() throws {
        let state = try load().data.state
        let engine = TradingEngine(state: state)
        let ledger = try XCTUnwrap(state.manualLedgers.first)
        let request = OrderRequest(ledgerID: ledger.id, instrument: .crypto("BTC", name: "Bitcoin"), side: .buy, notional: 100)
        let preview = try XCTUnwrap(engine.preview(request, now: Date()))
        XCTAssertEqual(preview.ledgerName, ledger.name)
        XCTAssertEqual(preview.mode, .paper)
        XCTAssertFalse(preview.risk.checks.isEmpty)
        // The server sends no quotes, so the phone can't approve the order on its own: it needs a price first.
        XCTAssertFalse(preview.canSubmit)
    }
}
