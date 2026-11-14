import Foundation
import Supabase

struct StockTransferHolding: Decodable, Identifiable {
    let id: UUID
    let asset_symbol: String
    let asset_exchange: String?
    let date_added: String
    let deleted_at: String?
    let broker_account: HoldingBrokerAccount?

    var title: String {
        [asset_symbol, asset_exchange, broker_account?.label, String(date_added.prefix(10)),
         deleted_at == nil ? nil : "Archived", String(id.uuidString.prefix(8))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func canSend(to destination: Self) -> Bool {
        guard id != destination.id, let venue = asset_exchange?.transferKey, !venue.isEmpty else { return false }
        if let sender = broker_account, sender.account_id == destination.broker_account?.account_id { return false }
        return venue == destination.asset_exchange?.transferKey && asset_symbol.transferKey == destination.asset_symbol.transferKey
    }
}

struct StockTransferBrokerReference: Decodable {
    let sentId: String
    let receivedId: String
    let sentOn: String
    let receivedOn: String
    let fromAccountId: String
    let toAccountId: String
    let symbol: String
    let exchange: String
    let shares: String

    var value: AnyJSON {
        .object([
            "sentId": sentId, "receivedId": receivedId, "sentOn": sentOn, "receivedOn": receivedOn,
            "fromAccountId": fromAccountId, "toAccountId": toAccountId, "symbol": symbol, "exchange": exchange, "shares": shares,
        ].mapValues(AnyJSON.string))
    }
}

struct StockTransferEntry: Decodable, Identifiable {
    let id: UUID
    let from_holding_id: UUID
    let to_holding_id: UUID
    let sent_on: String
    let received_on: String
    let shares: String
    let same_day_order: Int
    let from_account: String
    let to_account: String
    let statement_reference: String
    let receiving_snapshot_id: UUID?
    let updated_at: String
    let snaptrade_reference: StockTransferBrokerReference?
}

struct StockTransferSnapshot: Decodable, Identifiable {
    let id: UUID
    let transaction_date: String
    let shares: Double

    var day: String? {
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(transaction_date))
            ?? (try? Date.ISO8601FormatStyle().parse(transaction_date))
        guard let date else { return nil }
        return CashIncomeDay.string(date)
    }

    func matches(shares: String, received: Date) -> Bool {
        guard let day, day >= CashIncomeDay.string(received) else { return false }
        return Decimal(string: String(self.shares), locale: .init(identifier: "en_US_POSIX")) ==
            Decimal(string: shares, locale: .init(identifier: "en_US_POSIX"))
    }
}

struct StockTransferDraft {
    var source: UUID?
    var destination: UUID?
    var sent = Date()
    var received = Date()
    var shares = ""
    var order = 1
    var fromAccount = ""
    var toAccount = ""
    var statement = ""
    var snapshot: UUID?

    init(entry: StockTransferEntry? = nil) {
        guard let entry else { return }
        source = entry.from_holding_id
        destination = entry.to_holding_id
        sent = CashIncomeDay.date(entry.sent_on) ?? Date()
        received = CashIncomeDay.date(entry.received_on) ?? Date()
        shares = entry.shares
        order = entry.same_day_order
        fromAccount = entry.from_account
        toAccount = entry.to_account
        statement = entry.statement_reference
        snapshot = entry.receiving_snapshot_id
    }

    var normalizedShares: String {
        shares.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".").transferTrimmed
    }

    func values(holdings: [StockTransferHolding], reference: StockTransferBrokerReference?) throws -> [String: AnyJSON] {
        let from = fromAccount.transferTrimmed
        let to = toAccount.transferTrimmed
        let sentOn = CashIncomeDay.string(sent)
        let receivedOn = CashIncomeDay.string(received)
        guard let sender = holdings.first(where: { $0.id == source }),
              let receiver = holdings.first(where: { $0.id == destination }),
              sender.canSend(to: receiver), (1...100).contains(from.unicodeScalars.count),
              (1...100).contains(to.unicodeScalars.count), from.caseInsensitiveCompare(to) != .orderedSame,
              sentOn >= CashIncomeDay.string(CashIncomeDay.first), sentOn <= receivedOn,
              receivedOn <= CashIncomeDay.string(Date()), (1...999).contains(order),
              statement.transferTrimmed.unicodeScalars.count <= 200 else {
            throw StockTransferError.invalid("Check the holdings, account labels, Sydney dates, transfer order and statement reference.")
        }
        let shares = normalizedShares
        guard shares.wholeMatch(of: /(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,18})?/) != nil,
              shares.contains(where: { "123456789".contains($0) }) else {
            throw StockTransferError.invalid("Enter a positive share quantity with up to 18 decimal places.")
        }
        var values: [String: AnyJSON] = [
            "from_holding_id": .string(sender.id.uuidString), "to_holding_id": .string(receiver.id.uuidString),
            "sent_on": .string(sentOn), "received_on": .string(receivedOn), "shares": .string(shares),
            "same_day_order": .integer(order), "from_account": .string(from), "to_account": .string(to),
            "statement_reference": .string(statement.transferTrimmed),
            "receiving_snapshot_id": snapshot.map { .string($0.uuidString) } ?? .null,
        ]
        if let reference { values["snaptrade_reference"] = reference.value }
        return values
    }
}

enum StockTransferError: LocalizedError {
    case invalid(String), changed, duplicate, duplicateReference, brokerCoverage

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .changed: "This transfer changed elsewhere. Refresh and try again."
        case .duplicate: "This transfer, daily order number or receiving snapshot is already recorded."
        case .duplicateReference: "One of these SnapTrade movements is already attached to a transfer."
        case .brokerCoverage: "Some broker activity could not be checked. Narrow the date range or use both statements."
        }
    }
}

struct StockTransferRecords {
    let userId: UUID
    private let table = "portfolio_stock_transfers"
    private struct ChangedRow: Decodable { let id: UUID }

    func entries() async throws -> [StockTransferEntry] {
        try await pages { after, limit in
            let fields = """
            id,from_holding_id,to_holding_id,sent_on,received_on,shares::text,same_day_order,from_account,to_account,statement_reference,receiving_snapshot_id,updated_at,snaptrade_reference
            """
            let query = SupabaseManager.client.from(table).select(fields).eq("user_id", value: userId.uuidString)
            if let after { _ = query.gt("id", value: after.uuidString) }
            return try await query.order("id").limit(limit).execute().value
        }.sorted { ($0.sent_on, -$0.same_day_order) > ($1.sent_on, -$1.same_day_order) }
    }

    func holdings() async throws -> [StockTransferHolding] {
        try await pages { after, limit in
            let query = SupabaseManager.client.from("portfolio_holdings")
                .select("id,asset_symbol,asset_exchange,date_added,deleted_at,broker_account")
                .eq("user_id", value: userId.uuidString).eq("asset_kind", value: "Stock")
            if let after { _ = query.gt("id", value: after.uuidString) }
            return try await query.order("id").limit(limit).execute().value
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func snapshots(for holdingId: UUID) async throws -> [StockTransferSnapshot] {
        try await pages { after, limit in
            let query = SupabaseManager.client.from("transactions").select("id,transaction_date,shares")
                .eq("user_id", value: userId.uuidString).eq("holding_id", value: holdingId.uuidString)
                .eq("type", value: "Buy").is("deleted_at", value: nil)
                .in("trade_provenance->>source", values: ["broker_position", "csv_position"])
            if let after { _ = query.gt("id", value: after.uuidString) }
            return try await query.order("id").limit(limit).execute().value
        }.sorted { $0.transaction_date > $1.transaction_date }
    }

    private func pages<Row: Identifiable>(read: (UUID?, Int) async throws -> [Row]) async throws -> [Row] where Row.ID == UUID {
        var all: [Row] = []
        let pageSize = 500
        while true {
            try Task.checkCancellation()
            try await requireIncomeOwner(userId)
            let page = try await read(all.last?.id, pageSize)
            all.append(contentsOf: page)
            if page.count < pageSize { return all }
        }
    }

    func save(_ values: [String: AnyJSON], editing: StockTransferEntry?) async throws {
        try await requireIncomeOwner(userId)
        do {
            if let editing {
                let rows: [ChangedRow] = try await SupabaseManager.client.from(table).update(values)
                    .eq("user_id", value: userId.uuidString).eq("id", value: editing.id.uuidString)
                    .eq("updated_at", value: editing.updated_at).select("id").execute().value
                guard !rows.isEmpty else { throw StockTransferError.changed }
            } else {
                var payload = values
                payload["user_id"] = .string(userId.uuidString)
                try await SupabaseManager.client.from(table).insert(payload).execute()
            }
        } catch let error as PostgrestError where error.code == "23505" {
            if error.message.contains("portfolio_stock_transfer_broker_") { throw StockTransferError.duplicateReference }
            throw StockTransferError.duplicate
        } catch let error as PostgrestError where error.code == "23514" {
            throw StockTransferError.invalid("Check both holdings, their broker references and the receiving position snapshot.")
        }
    }

    func remove(_ entry: StockTransferEntry) async throws {
        try await requireIncomeOwner(userId)
        let rows: [ChangedRow] = try await SupabaseManager.client.from(table).delete()
            .eq("user_id", value: userId.uuidString).eq("id", value: entry.id.uuidString)
            .eq("updated_at", value: entry.updated_at).select("id").execute().value
        guard !rows.isEmpty else { throw StockTransferError.changed }
    }
}

private extension String {
    var transferTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var transferKey: String { transferTrimmed.uppercased() }
}
