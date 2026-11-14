import Foundation

struct BrokerStockTransferMatch: Identifiable {
    let source: StockTransferHolding
    let destination: StockTransferHolding
    let reference: StockTransferBrokerReference

    var id: String { reference.sentId }
}

struct BrokerStockTransferSearch {
    let userId: UUID

    private struct Registration: Decodable { let registered: Bool }
    private struct Account: Decodable { let id: String }
    private struct Page: Decodable {
        let activities: [Movement]
        let omitted: Int
        let nextOffset: Int?
    }
    private struct Movement: Decodable {
        let id: String
        let date: String
        let stockTransfer: Details

        struct Details: Decodable {
            enum Direction: String, Decodable { case sent, received }
            let accountId: String
            let direction: Direction
            let symbol: String
            let exchange: String
            let shares: String

            var listing: Listing { Listing(symbol: symbol, exchange: exchange) }
        }
    }
    private struct Listing: Hashable {
        let ticker: String
        let exchange: String

        init(symbol: String, exchange: String) {
            let venue = exchange.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.exchange = ["XASX": "ASX", "XNAS": "NASDAQ", "XNYS": "NYSE"][venue] ?? venue
            let ticker = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.ticker = self.exchange == "ASX" && ticker.hasSuffix(".AX") ? String(ticker.dropLast(3)) : ticker
        }
    }
    private struct AccountListing: Hashable {
        let account: String
        let listing: Listing
    }

    func search(from start: Date, through end: Date, holdings: [StockTransferHolding]) async throws -> (accounts: Int, matches: [BrokerStockTransferMatch]) {
        let first = CashIncomeDay.string(start)
        let last = CashIncomeDay.string(end)
        guard first <= last else { throw StockTransferError.invalid("Choose a valid date range.") }
        let status: Registration = try await brokerage("status")
        guard status.registered else { return (0, []) }
        let accounts: [Account] = try await brokerage("listAccounts")
        let accountIds = Set(accounts.map { $0.id.lowercased() })
        guard accountIds.count > 1 else { return (accountIds.count, []) }

        var movements: [String: Movement] = [:]
        for account in accountIds.sorted() {
            var offset = 0
            for pageIndex in 0..<20 {
                try Task.checkCancellation()
                let page: Page = try await brokerage("accountActivities", params: [
                    "accountId": account, "startDate": first, "endDate": last, "offset": offset, "stockTransfersOnly": true,
                ])
                guard page.omitted == 0, page.activities.allSatisfy({ $0.stockTransfer.accountId == account }) else {
                    throw StockTransferError.brokerCoverage
                }
                for row in page.activities { movements[row.id] = row }
                guard let next = page.nextOffset else { break }
                guard next > offset, pageIndex < 19 else { throw StockTransferError.brokerCoverage }
                offset = next
            }
        }
        return (accountIds.count, matches(Array(movements.values), holdings: holdings))
    }

    private func brokerage<Response: Decodable>(_ operation: String, params: [String: Any] = [:]) async throws -> Response {
        let data = try await SecureBackend.invoke("snaptrade-proxy", body: ["operation": operation, "params": params], expectedUserID: userId)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func matches(_ movements: [Movement], holdings: [StockTransferHolding]) -> [BrokerStockTransferMatch] {
        let dates = Dictionary(uniqueKeysWithValues: Set(movements.map(\.date)).compactMap { day in
            CashIncomeDay.date(day).map { (day, $0) }
        })
        let incoming = Dictionary(grouping: movements.filter { $0.stockTransfer.direction == .received }) { $0.stockTransfer.listing }
        let outgoing = movements.filter { $0.stockTransfer.direction == .sent }
        var pairs: [(sent: Movement, received: Movement)] = []
        var receiverCounts: [String: Int] = [:]
        for sent in outgoing {
            guard let sentDate = dates[sent.date],
                  let last = CashIncomeDay.calendar.date(byAdding: .day, value: 7, to: sentDate) else { continue }
            let candidates = incoming[sent.stockTransfer.listing, default: []].filter { received in
                received.stockTransfer.accountId != sent.stockTransfer.accountId &&
                    received.stockTransfer.shares == sent.stockTransfer.shares &&
                    received.date >= sent.date && dates[received.date].map { $0 <= last } == true
            }
            for candidate in candidates { receiverCounts[candidate.id, default: 0] += 1 }
            if candidates.count == 1, let received = candidates.first { pairs.append((sent, received)) }
        }
        var holdingsByAccount: [AccountListing: [StockTransferHolding]] = [:]
        for holding in holdings {
            guard let account = holding.broker_account?.account_id, let exchange = holding.asset_exchange else { continue }
            holdingsByAccount[AccountListing(account: account, listing: Listing(symbol: holding.asset_symbol, exchange: exchange)), default: []]
                .append(holding)
        }
        return pairs.compactMap { sent, received -> BrokerStockTransferMatch? in
            let outgoing = sent.stockTransfer
            let incoming = received.stockTransfer
            let source = holdingsByAccount[AccountListing(account: outgoing.accountId, listing: outgoing.listing), default: []]
            let destination = holdingsByAccount[AccountListing(account: incoming.accountId, listing: incoming.listing), default: []]
            guard receiverCounts[received.id] == 1, source.count == 1, destination.count == 1,
                  let sender = source.first, let receiver = destination.first, sender.canSend(to: receiver) else { return nil }
            let reference = StockTransferBrokerReference(sentId: sent.id, receivedId: received.id, sentOn: sent.date,
                receivedOn: received.date, fromAccountId: outgoing.accountId, toAccountId: incoming.accountId,
                symbol: outgoing.symbol, exchange: outgoing.exchange, shares: outgoing.shares)
            return BrokerStockTransferMatch(source: sender, destination: receiver, reference: reference)
        }.sorted { ($0.reference.sentOn, $0.id) > ($1.reference.sentOn, $1.id) }
    }
}
