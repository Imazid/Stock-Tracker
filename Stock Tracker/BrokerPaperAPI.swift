import Auth
import Foundation
import Supabase
import TradingCore

struct BrokerPaperConnection: Decodable, Identifiable {
    struct Capabilities: Decodable {
        let executionAvailable: Bool
        let orders: [OrderCapability]
    }

    struct OrderCapability: Decodable {
        let assetClass: String
        let orderTypes: [String]
        let timeInForce: [String: [String]]
        let fractional: Bool
        let notional: Bool
    }

    struct Sync: Decodable {
        let state: String
        let lastError: String?
    }

    let id: String
    let provider: String
    let environment: String
    let label: String
    let permissions: [String]
    let status: String
    let sync: Sync
    let capabilities: Capabilities

    var isAlpacaPaper: Bool { provider == "alpaca" && environment == "paper" && status != "revoked" }

    func capability(for asset: BrokerPaperAsset) -> OrderCapability? {
        guard isAlpacaPaper, status == "active", permissions.contains("trade"),
              capabilities.executionAvailable else { return nil }
        return capabilities.orders.first { $0.assetClass == asset.assetClass }
    }
}

struct BrokerPaperAsset {
    let instrument: Instrument
    let assetClass: String

    init?(_ instrument: Instrument) {
        switch instrument.venue {
        case .us: assetClass = "us_equity"
        case .crypto: assetClass = "crypto"
        default: return nil
        }
        self.instrument = instrument
    }

    var symbol: String { assetClass == "crypto" ? "\(instrument.symbol)/USD" : instrument.symbol }
}

struct BrokerPaperIntent: Decodable, Identifiable {
    struct Estimate: Decodable {
        let notional: String?
        let fee: String?
        let feeCurrency: String?
        let currency: String
    }

    struct Risk: Decodable {
        struct Check: Decodable, Identifiable {
            let id: String
            let status: String
            let detail: String
        }

        struct Price: Decodable {
            let value: String
            let currency: String
            let source: String
            let observedAt: Date
            let status: String
        }

        let policyVersion: Int
        let result: String
        let checks: [Check]
        let price: Price
        let evaluatedAt: Date
    }

    struct Approval: Decodable {
        let expiresAt: Date
        let consumedAt: Date?
    }

    struct BrokerOrder: Decodable {
        let providerOrderID: String
        let status: String
        let filledQuantity: String
        let averageFillPrice: String?
        let submittedAt: Date?
        let updatedAt: Date?
    }

    struct Transition: Decodable {
        let to: String
        let at: Date
        let note: String?
    }

    let id: String
    let connectionID: String
    let provider: String
    let environment: String
    let status: String
    let intentHash: String
    let clientOrderID: String
    let symbol: String
    let side: String
    let type: String
    let timeInForce: String
    let quantity: String?
    let notional: String?
    let limitPrice: String?
    let stopPrice: String?
    let estimate: Estimate
    let risk: Risk?
    let approval: Approval?
    let brokerOrder: BrokerOrder?
    let transitions: [Transition]
    let createdAt: Date
    let expiresAt: Date

    var isAlpacaPaper: Bool { provider == "alpaca" && environment == "paper" }
    var canReconcile: Bool { ["submitting", "submitted", "partially_filled", "reconciliation_required"].contains(status) }
    var canCancel: Bool { ["submitted", "partially_filled"].contains(status) && brokerOrder?.status != "pending_cancel" }
    var canReject: Bool { ["draft", "risk_checked", "awaiting_approval", "approved"].contains(status) }
    var title: String { "\(side.capitalized) \(symbol)" }
    var statusLabel: String { Self.statusLabel(status) }

    static func statusLabel(_ value: String) -> String {
        switch value {
        case "risk_checked": return "Risk checked"
        case "awaiting_approval": return "Awaiting approval"
        case "submitting": return "Sending to Alpaca"
        case "submitted": return "Submitted to Alpaca"
        case "reconciliation_required": return "Checking with Alpaca"
        case "pending_new": return "Pending at Alpaca"
        case "pending_cancel": return "Cancellation pending"
        case "pending_replace": return "Replacement pending"
        case "partially_filled": return "Partially filled"
        case "canceled": return "Cancelled"
        case "unknown": return "Status unknown"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct BrokerPaperGate: Decodable {
    let enabled: Bool
    let reason: String

    static let unavailable = Self(enabled: false, reason: "Alpaca paper orders are unavailable on this deployment.")
}

struct BrokerPaperAPI {
    enum Action: String, Hashable {
        case riskCheck, approve, submit, reject, cancel, reconcile
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let data: Value
    }
    private struct Connections: Decodable { let connections: [BrokerPaperConnection] }
    private struct Connection: Decodable { let connection: BrokerPaperConnection }
    private struct Orders: Decodable { let intents: [BrokerPaperIntent] }
    private struct Order: Decodable { let intent: BrokerPaperIntent }

    let userID: UUID

    func gate() async throws -> BrokerPaperGate {
        try checkSession()
        let rows: [BrokerPaperGate] = try await SupabaseManager.client
            .from("platform_gates").select("enabled,reason").eq("id", value: "provider_paper_execution")
            .execute().value
        try checkSession()
        return rows.first ?? .unavailable
    }

    func connections() async throws -> [BrokerPaperConnection] {
        let result: Connections = try await call("broker-connections", ["action": "list"])
        return result.connections.filter(\.isAlpacaPaper)
    }

    func connect(label: String, keyID: String, secretKey: String, allowOrders: Bool) async throws -> BrokerPaperConnection {
        let result: Connection = try await call("broker-connections", [
            "action": "connect", "provider": "alpaca", "environment": "paper",
            "label": label, "permissions": allowOrders ? ["read", "trade"] : ["read"],
            "credentials": ["keyID": keyID, "secretKey": secretKey],
        ])
        return result.connection
    }

    func orders() async throws -> [BrokerPaperIntent] {
        let result: Orders = try await call("broker-orders", ["action": "list"])
        return result.intents.filter(\.isAlpacaPaper)
    }

    func order(_ id: String) async throws -> BrokerPaperIntent {
        let result: Order = try await call("broker-orders", ["action": "get", "intentID": id])
        return try paperOrder(result)
    }

    func draft(_ input: [String: Any], key: String) async throws -> BrokerPaperIntent {
        let result: Order = try await call("broker-orders", ["action": "draft", "intent": input], key: key)
        return try paperOrder(result)
    }

    func act(_ action: Action, on intent: BrokerPaperIntent, key: String) async throws -> BrokerPaperIntent {
        var body = ["action": action.rawValue, "intentID": intent.id]
        if action == .approve { body["intentHash"] = intent.intentHash }
        let result: Order = try await call("broker-orders", body, key: key)
        return try paperOrder(result)
    }

    private func call<Value: Decodable>(_ function: String, _ body: [String: Any], key: String? = nil) async throws -> Value {
        let data = try await SecureBackend.invoke(function, body: body, expectedUserID: userID, idempotencyKey: key)
        try checkSession()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
            return try Date.ISO8601FormatStyle().parse(value)
        }
        return try decoder.decode(Envelope<Value>.self, from: data).data
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        guard SupabaseManager.auth.currentUser?.id == userID else { throw CancellationError() }
    }

    private func paperOrder(_ result: Order) throws -> BrokerPaperIntent {
        guard result.intent.isAlpacaPaper else {
            throw SecureBackend.FunctionError(status: 404, code: "not_found", message: "This paper order is unavailable.")
        }
        return result.intent
    }
}
