import Foundation
import Supabase

struct ReinvestmentHolding: Decodable, Identifiable {
    let id: UUID
    let asset_symbol: String
    let asset_name: String
    let asset_exchange: String?
    let deleted_at: String?

    var title: String {
        [asset_symbol, asset_exchange ?? "", deleted_at == nil ? "" : "Archived"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct DividendReinvestment: Decodable, Identifiable {
    let id: UUID
    let holding_id: UUID
    let paid_on: String
    let acquired_on: String
    let currency: String
    let dividend_amount: String
    let reinvested_amount: String
    let shares: String
    let basis_usd: String?
    let franking_credit_aud: String?
    let statement_reference: String
    let updated_at: String
    let portfolio_holdings: ReinvestmentHolding?

    var usdBasis: String? { currency == "USD" ? reinvested_amount : basis_usd }
}

struct ReinvestmentDraft {
    var holding: ReinvestmentHolding?
    var paid = Date()
    var acquired = Date()
    var currency = "AUD"
    var dividend = ""
    var reinvested = ""
    var shares = ""
    var basis = ""
    var credit = ""
    var reference = ""

    init(entry: DividendReinvestment?) {
        guard let entry else { return }
        holding = entry.portfolio_holdings
        paid = CashIncomeDay.date(entry.paid_on) ?? Date()
        acquired = CashIncomeDay.date(entry.acquired_on) ?? Date()
        currency = entry.currency
        dividend = entry.dividend_amount
        reinvested = entry.reinvested_amount
        shares = entry.shares
        basis = entry.basis_usd ?? ""
        credit = entry.franking_credit_aud ?? ""
        reference = entry.statement_reference
    }

    var currencyCode: String { currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    func values() throws -> [String: String?] {
        let today = CashIncomeDay.string(Date())
        let first = CashIncomeDay.string(CashIncomeDay.first)
        let paid = CashIncomeDay.string(paid)
        let acquired = CashIncomeDay.string(acquired)
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let holding, (first...today).contains(paid), (first...today).contains(acquired),
              currencyCode.wholeMatch(of: /[A-Z]{3}/) != nil, reference.unicodeScalars.count <= 200 else {
            throw ReinvestmentError.invalid("Choose a stock holding, valid statement dates and a three-letter currency. Use up to 200 characters for the reference.")
        }
        let separator = Locale.current.decimalSeparator ?? "."
        func normalized(_ value: String) -> String { value.replacingOccurrences(of: separator, with: ".") }
        let dividend = normalized(dividend)
        let reinvested = normalized(reinvested)
        let shares = normalized(shares)
        let basis = currencyCode == "USD" ? "" : normalized(basis)
        let credit = normalized(credit)
        guard (CashIncomeDraft.amount(dividend) ?? 0) > 0, (CashIncomeDraft.amount(reinvested) ?? 0) > 0,
              shares.wholeMatch(of: /(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,18})?/) != nil,
              shares.contains(where: { "123456789".contains($0) }),
              basis.isEmpty || (CashIncomeDraft.amount(basis) ?? 0) > 0,
              credit.isEmpty || CashIncomeDraft.amount(credit) != nil else {
            throw ReinvestmentError.invalid("Enter positive amounts and shares. Use up to eight decimal places for amounts and 18 for shares.")
        }
        return [
            "holding_id": holding.id.uuidString, "paid_on": paid, "acquired_on": acquired, "currency": currencyCode,
            "dividend_amount": dividend, "reinvested_amount": reinvested, "shares": shares,
            "basis_usd": basis.isEmpty ? nil : basis, "franking_credit_aud": credit.isEmpty ? nil : credit,
            "statement_reference": reference,
        ]
    }
}

enum ReinvestmentError: LocalizedError {
    case invalid(String), changed, duplicate

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .changed: "This reinvestment changed elsewhere. Refresh the list and try again."
        case .duplicate: "This reinvestment is already recorded. Edit the existing record to correct it."
        }
    }
}

struct ReinvestmentRecords {
    let userId: UUID

    private struct ChangedRow: Decodable { let id: UUID }
    private let table = "portfolio_dividend_reinvestments"
    private let holdingFields = "id,asset_symbol,asset_name,asset_exchange,deleted_at"

    func page(from: String? = nil, through: String? = nil, after: DividendReinvestment? = nil,
              limit: Int) async throws -> [DividendReinvestment] {
        try await requireIncomeOwner(userId)
        let fields = """
        id,holding_id,paid_on,acquired_on,currency,dividend_amount::text,reinvested_amount::text,shares::text,basis_usd::text,franking_credit_aud::text,statement_reference,updated_at,portfolio_holdings(\(holdingFields))
        """
        let query = SupabaseManager.client.from(table).select(fields).eq("user_id", value: userId.uuidString)
        if let from { query.gte("paid_on", value: from) }
        if let through { query.lte("paid_on", value: through) }
        if let after {
            query.or("paid_on.lt.\(after.paid_on),and(paid_on.eq.\(after.paid_on),id.lt.\(after.id.uuidString))")
        }
        return try await query.order("paid_on", ascending: false).order("id", ascending: false).limit(limit).execute().value
    }

    func holdings() async throws -> [ReinvestmentHolding] {
        var all: [ReinvestmentHolding] = []
        let pageSize = 500
        while true {
            try await requireIncomeOwner(userId)
            let query = SupabaseManager.client.from("portfolio_holdings").select(holdingFields)
                .eq("user_id", value: userId.uuidString).eq("asset_kind", value: "Stock")
            if let after = all.last { query.gt("id", value: after.id.uuidString) }
            let page: [ReinvestmentHolding] = try await query.order("id").limit(pageSize).execute().value
            all.append(contentsOf: page)
            if page.count < pageSize { break }
        }
        return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func save(_ draft: ReinvestmentDraft, editing: DividendReinvestment?) async throws {
        var values = try draft.values()
        try await requireIncomeOwner(userId)
        do {
            if let editing {
                let rows: [ChangedRow] = try await SupabaseManager.client.from(table).update(values)
                    .eq("user_id", value: userId.uuidString).eq("id", value: editing.id.uuidString)
                    .eq("updated_at", value: editing.updated_at).select("id").execute().value
                guard !rows.isEmpty else { throw ReinvestmentError.changed }
            } else {
                values["user_id"] = userId.uuidString
                try await SupabaseManager.client.from(table).insert(values).execute()
            }
        } catch let error as PostgrestError where error.code == "23505" {
            throw ReinvestmentError.duplicate
        }
    }

    func remove(_ entry: DividendReinvestment) async throws {
        try await requireIncomeOwner(userId)
        let rows: [ChangedRow] = try await SupabaseManager.client.from(table).delete()
            .eq("user_id", value: userId.uuidString).eq("id", value: entry.id.uuidString)
            .eq("updated_at", value: entry.updated_at).select("id").execute().value
        guard !rows.isEmpty else { throw ReinvestmentError.changed }
    }
}
