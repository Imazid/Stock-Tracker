import Foundation
import Supabase

enum CashIncomeKind: String, Decodable, CaseIterable {
    case dividend, distribution
    case substituteDividend = "substitute_dividend"

    var title: String {
        switch self {
        case .dividend: "Dividend"
        case .distribution: "Distribution"
        case .substituteDividend: "Payment in lieu of dividend"
        }
    }

    init?(brokerLabel: String) {
        switch brokerLabel {
        case "Dividend": self = .dividend
        case "Distribution": self = .distribution
        case "Substitute dividend": self = .substituteDividend
        default: return nil
        }
    }
}

struct CashIncomeBrokerPayment {
    let id: String
    let date: String
    let kind: CashIncomeKind
    let symbol: String?
    let amount: String
    let currency: String
    let account: String
}

struct CashIncomePayment: Decodable, Identifiable {
    let id: UUID
    let paid_on: String
    let kind: CashIncomeKind
    let payer: String
    let account_label: String
    let currency: String
    let cash_received: String
    let gross_amount: String?
    let withholding: String?
    let franking_credit_aud: String?
    let statement_reference: String
    let snaptrade_activity_id: String?
    let snaptrade_reported_on: String?
    let snaptrade_reported_amount: String?
    let snaptrade_reported_currency: String?
    let updated_at: String
}

struct CashIncomeTotal: Decodable, Identifiable {
    let currency: String
    let cash_received: String
    let payments: Int

    var id: String { currency }
}

enum CashIncomeDay {
    static let timeZone = TimeZone(identifier: "Australia/Sydney")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func string(_ date: Date) -> String { formatter().string(from: date) }
    static func date(_ string: String) -> Date? { formatter().date(from: string) }
    static var first: Date { calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))! }
}

let cashIncomeNotice = "Preliminary cash records for review. Check the payment details, withholding, franking credits and tax treatment against your statements. This report does not calculate tax."

func cashIncomeMoney(_ amount: String, _ currency: String) -> String {
    guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
    return "\(currency) \(value.formatted(.number.precision(.fractionLength(2...8))))"
}

struct CashIncomeDraft {
    var date = Date()
    var kind = CashIncomeKind.dividend
    var payer = ""
    var account = ""
    var currency = "AUD"
    var cash = ""
    var gross = ""
    var withheld = ""
    var credit = ""
    var reference = ""

    static func amount(_ text: String) -> Decimal? {
        guard text.wholeMatch(of: /(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,8})?/) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    func values() throws -> [String: String?] {
        let payer = payer.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payer.isEmpty, payer.count <= 100, account.count <= 100, reference.count <= 200,
              currency.wholeMatch(of: /[A-Z]{3}/) != nil, date >= CashIncomeDay.first,
              CashIncomeDay.string(date) <= CashIncomeDay.string(Date()) else {
            throw CashIncomeError.invalid("Check the payment date, payer, account label, reference and three-letter currency code.")
        }
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let cash = cash.replacingOccurrences(of: decimalSeparator, with: ".")
        let gross = gross.replacingOccurrences(of: decimalSeparator, with: ".")
        let withheld = withheld.replacingOccurrences(of: decimalSeparator, with: ".")
        let credit = credit.replacingOccurrences(of: decimalSeparator, with: ".")
        guard let received = Self.amount(cash), received > 0,
              [gross, withheld, credit].allSatisfy({ $0.isEmpty || Self.amount($0) != nil }) else {
            throw CashIncomeError.invalid("Enter a positive cash amount and use up to eight decimal places.")
        }
        if let grossAmount = Self.amount(gross), received + (Self.amount(withheld) ?? 0) > grossAmount {
            throw CashIncomeError.invalid("Gross payment must cover cash received plus any withholding.")
        }
        return [
            "paid_on": CashIncomeDay.string(date), "kind": kind.rawValue, "payer": payer, "account_label": account,
            "currency": currency, "cash_received": cash, "gross_amount": gross.isEmpty ? nil : gross,
            "withholding": withheld.isEmpty ? nil : withheld, "franking_credit_aud": credit.isEmpty ? nil : credit,
            "statement_reference": reference,
        ]
    }
}

enum CashIncomeError: LocalizedError {
    case invalid(String), changed
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .changed: "This payment changed elsewhere. Refresh the list and try again."
        }
    }
}

func requireIncomeOwner(_ userId: UUID) async throws {
    guard try await SupabaseManager.auth.session.user.id == userId else { throw CancellationError() }
    try Task.checkCancellation()
}

struct CashIncomeRecords {
    let userId: UUID
    private let table = "portfolio_cash_income"
    private let fields = """
    id,paid_on,kind,payer,account_label,currency,cash_received::text,gross_amount::text,withholding::text,franking_credit_aud::text,statement_reference,snaptrade_activity_id,snaptrade_reported_on,snaptrade_reported_amount::text,snaptrade_reported_currency,updated_at
    """

    func page(from: String?, through: String?, after: CashIncomePayment? = nil, limit: Int) async throws -> [CashIncomePayment] {
        try await requireIncomeOwner(userId)
        let query = SupabaseManager.client.from(table).select(fields).eq("user_id", value: userId.uuidString)
        if let from { query.gte("paid_on", value: from) }
        if let through { query.lte("paid_on", value: through) }
        if let after {
            query.or("paid_on.lt.\(after.paid_on),and(paid_on.eq.\(after.paid_on),id.lt.\(after.id.uuidString))")
        }
        return try await query.order("paid_on", ascending: false).order("id", ascending: false).limit(limit).execute().value
    }

    func totals(from: String?, through: String?) async throws -> [CashIncomeTotal] {
        try await requireIncomeOwner(userId)
        let params: [String: String?] = ["p_from": from, "p_through": through]
        return try await SupabaseManager.client.rpc("portfolio_cash_income_totals", params: params).execute().value
    }

    func save(_ draft: CashIncomeDraft, editing: CashIncomePayment?, source: CashIncomeBrokerPayment?) async throws {
        var values = try draft.values()
        try await requireIncomeOwner(userId)
        if let editing {
            let rows: [CashIncomePayment] = try await SupabaseManager.client.from(table).update(values)
                .eq("user_id", value: userId.uuidString).eq("id", value: editing.id.uuidString)
                .eq("updated_at", value: editing.updated_at).select(fields).execute().value
            guard !rows.isEmpty else { throw CashIncomeError.changed }
        } else {
            values["user_id"] = userId.uuidString
            if let source {
                values["snaptrade_activity_id"] = source.id
                values["snaptrade_reported_on"] = source.date
                values["snaptrade_reported_currency"] = source.currency
                values["snaptrade_reported_amount"] = source.amount
            }
            try await SupabaseManager.client.from(table).insert(values).execute()
        }
    }

    func remove(_ payment: CashIncomePayment) async throws {
        try await requireIncomeOwner(userId)
        struct Removed: Decodable { let id: UUID }
        let rows: [Removed] = try await SupabaseManager.client.from(table).delete()
            .eq("user_id", value: userId.uuidString).eq("id", value: payment.id.uuidString)
            .eq("updated_at", value: payment.updated_at).select("id").execute().value
        guard !rows.isEmpty else { throw CashIncomeError.changed }
    }

    func export(from: String?, through: String?) async throws -> Data {
        let cashColumns = [
            "Record type", "Payment ID", "Payment date (Sydney)", "Payment type", "Payer or ticker",
            "Account label", "Currency", "Cash received", "Gross payment", "Withholding", "Franking credit (AUD)",
            "Statement reference", "SnapTrade activity reference", "SnapTrade reported date", "SnapTrade reported currency",
            "SnapTrade reported amount", "Report note",
        ]
        let reinvestmentColumns = ["Reinvested amount", "Shares acquired", "Acquisition date (Sydney)", "Acquisition basis (USD)"]
        let brokerReinvestmentColumns = ["SnapTrade reported symbol", "SnapTrade reported units"]
        typealias ExportRow = (paidOn: String, id: String, fields: [String?])
        var output: [ExportRow] = []
        let pageSize = 500
        var afterPayment: CashIncomePayment?
        repeat {
            let rows = try await page(from: from, through: through, after: afterPayment, limit: pageSize)
            for row in rows {
                let id = row.id.uuidString.lowercased()
                output.append((row.paid_on, id, [
                    "Cash payment", id, row.paid_on, row.kind.title, row.payer, row.account_label,
                    row.currency, row.cash_received, row.gross_amount, row.withholding, row.franking_credit_aud,
                    row.statement_reference, row.snaptrade_activity_id, row.snaptrade_reported_on, row.snaptrade_reported_currency,
                    row.snaptrade_reported_amount, nil,
                ]))
            }
            afterPayment = rows.count == pageSize ? rows.last : nil
        } while afterPayment != nil

        let reinvestments = ReinvestmentRecords(userId: userId)
        var afterReinvestment: DividendReinvestment?
        var hasReinvestments = false
        var hasBrokerReinvestments = false
        repeat {
            let rows = try await reinvestments.page(from: from, through: through, after: afterReinvestment, limit: pageSize)
            hasReinvestments = hasReinvestments || !rows.isEmpty
            for row in rows {
                let id = row.id.uuidString.lowercased()
                hasBrokerReinvestments = hasBrokerReinvestments || row.snaptrade_activity_id != nil
                output.append((row.paid_on, id, [
                    "Dividend reinvestment", id, row.paid_on, "Dividend", row.portfolio_holdings?.asset_symbol,
                    nil, row.currency, nil, row.dividend_amount, nil, row.franking_credit_aud, row.statement_reference,
                    row.snaptrade_activity_id, row.snaptrade_reported_on, row.snaptrade_reported_currency,
                    row.snaptrade_reported_amount, "The gross dividend may include cash paid separately. Use the statement to reconcile both entries.",
                    row.reinvested_amount, row.shares, row.acquired_on, row.usdBasis,
                    row.snaptrade_reported_symbol, row.snaptrade_reported_units,
                ]))
            }
            afterReinvestment = rows.count == pageSize ? rows.last : nil
        } while afterReinvestment != nil

        let header = cashColumns + (hasReinvestments ? reinvestmentColumns : [])
            + (hasBrokerReinvestments ? brokerReinvestmentColumns : [])
        let note: [String?] = header.map { column in
            switch column {
            case "Record type": "Report information"
            case "Report note": cashIncomeNotice
            default: nil
            }
        }
        var data = Data((csvLine(header.map { Optional($0) }) + csvLine(note)).utf8)
        output.sort { ($0.paidOn, $0.id) > ($1.paidOn, $1.id) }
        for row in output {
            let fields = row.fields.prefix(header.count)
                + Array<String?>(repeating: nil, count: max(0, header.count - row.fields.count))
            data.append(contentsOf: csvLine(Array(fields)).utf8)
        }
        return data
    }

    private func csvLine(_ values: [String?]) -> String {
        values.map { value in
            guard var value else { return "" }
            let first = value.unicodeScalars.first(where: { $0.value > 32 })
            if value.hasPrefix("\t") || value.hasPrefix("\r") || value.hasPrefix("\n") ||
                (first.map { "=+-@".unicodeScalars.contains($0) } ?? false) { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }
}
