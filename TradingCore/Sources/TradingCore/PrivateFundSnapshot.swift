import CoreFoundation
import Foundation

/// Values explicitly selected from one provider capital account. Aggregate
/// balances are not dated cash flows or proof of an opening settlement.
public struct PrivateFundSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: String
    public let name: String
    public let assetClass: PrivateAssetClass
    public let currency: String
    public let asOf: Date
    public let netAssetValue: Decimal?
    public let commitment: Decimal?
    public let paidIn: Decimal?
    public let distributions: Decimal?
    public let replacesManualHoldingID: UUID?
    public let retrievedAt: Date

    public static let source = "AngelList capital account"

    public var allocationHolding: PrivateHolding {
        PrivateHolding(id: id, name: name, assetClass: assetClass, currency: currency, commitment: commitment,
                       valuations: netAssetValue.map { [.init(value: $0, date: asOf, source: Self.source,
                                                              method: "Reported capital account NAV")] } ?? [])
    }

    public struct Record: Identifiable, Equatable, Sendable {
        public struct Field: Identifiable, Equatable, Sendable {
            public let id: String
            public let value: String
        }
        public let id: String
        public let fields: [Field]
    }

    public static func statementRecords(structured: Data?, text: [String]) -> [Record] {
        let candidates = structured.map(records(in:)) ?? []
        if !candidates.isEmpty { return candidates }
        return text.prefix(10).enumerated().flatMap { index, block in
            records(in: Data(block.utf8)).map { record in
                Record(id: "Response \(index + 1) › " + record.id, fields: record.fields)
            }
        }.prefix(100).map { $0 }
    }

    /// Discover scalar fields from the actual response without guessing a
    /// provider schema or combining different rows in an array.
    public static func records(in json: Data) -> [Record] {
        guard json.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: json) else { return [] }
        var result: [Record] = []
        func visit(_ value: Any, path: String, depth: Int) {
            guard depth <= 8, result.count < 100 else { return }
            if let array = value as? [Any] {
                for (index, item) in array.prefix(100).enumerated() {
                    visit(item, path: path + "[\(index + 1)]", depth: depth + 1)
                }
                return
            }
            guard let object = value as? [String: Any] else { return }
            var fields: [Record.Field] = []
            func collect(_ object: [String: Any], prefix: String, depth: Int) {
                guard depth <= 8, fields.count < 80 else { return }
                for key in object.keys.sorted().prefix(100) where fields.count < 80 {
                    guard !key.isEmpty, key.utf8.count <= 80, let value = object[key] else { continue }
                    let label = prefix.isEmpty ? key : prefix + " › " + key
                    if let nested = value as? [String: Any] {
                        collect(nested, prefix: label, depth: depth + 1)
                    } else if let text = value as? String, !text.isEmpty, text.utf8.count <= 180 {
                        fields.append(.init(id: label, value: text))
                    } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                        fields.append(.init(id: label, value: number.stringValue))
                    }
                }
            }
            collect(object, prefix: "", depth: depth)
            if fields.count >= 4, Set(fields.map(\.id)).count == fields.count {
                result.append(.init(id: path, fields: fields))
            }
            // Nested objects can be valid standalone records. Walk arrays from
            // their actual path and never inherit parent balances or identifiers.
            for key in object.keys.sorted().prefix(100) where result.count < 100 {
                if let item = object[key], item is [Any] || item is [String: Any] {
                    visit(item, path: path + " › " + key, depth: depth + 1)
                }
            }
        }
        visit(root, path: "Response", depth: 0)
        return result
    }

    public static func make(
        id: UUID = UUID(), reference: String, name: String, assetClass: PrivateAssetClass, currency: String,
        asOf: String, netAssetValue: String?, commitment: String?, paidIn: String?, distributions: String?,
        replacesManualHoldingID: UUID? = nil, retrievedAt: Date
    ) -> Self? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = currency.uppercased()
        let controls = CharacterSet.controlCharacters
        guard !reference.isEmpty, reference.utf8.count <= 160, reference.rangeOfCharacter(from: controls) == nil,
              !name.isEmpty, name.utf8.count <= 160, name.rangeOfCharacter(from: controls) == nil,
              assetClass.isFund, Locale.commonISOCurrencyCodes.contains(currency), currency != "XXX",
              let date = statementDate(asOf), date <= retrievedAt else { return nil }
        let inputs = [netAssetValue, commitment, paidIn, distributions]
        let amounts = inputs.map { $0.flatMap(statementAmount) }
        guard zip(inputs, amounts).allSatisfy({ $0 == nil || $1 != nil }),
              amounts.contains(where: { $0 != nil }) else { return nil }
        return Self(id: id, reference: reference, name: name, assetClass: assetClass, currency: currency, asOf: date,
                    netAssetValue: amounts[0], commitment: amounts[1], paidIn: amounts[2],
                    distributions: amounts[3], replacesManualHoldingID: replacesManualHoldingID, retrievedAt: retrievedAt)
    }

    public func replacing(in snapshots: [Self]) -> [Self]? {
        guard let previous = snapshots.first(where: { $0.reference == reference }) else {
            return snapshots + [self]
        }
        guard previous.asOf <= asOf, previous.retrievedAt <= retrievedAt, previous.currency == currency else { return nil }
        let updated = Self(id: previous.id, reference: reference, name: name, assetClass: assetClass, currency: currency,
                           asOf: asOf, netAssetValue: netAssetValue, commitment: commitment, paidIn: paidIn,
                           distributions: distributions, replacesManualHoldingID: replacesManualHoldingID, retrievedAt: retrievedAt)
        return snapshots.map { $0.reference == reference ? updated : $0 }
    }

    public static func allocation(
        manual: [PrivateHolding], confirmed: [PrivateHolding], snapshots: [Self], asOf: Date = .now
    ) -> [PrivateHolding] {
        let manualByID = Dictionary(manual.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var replaced = Set<UUID>()
        let fundHoldings = snapshots.compactMap { snapshot -> PrivateHolding? in
            if let manualID = snapshot.replacesManualHoldingID, let holding = manualByID[manualID] {
                guard snapshot.currency == holding.currency, snapshot.netAssetValue != nil, snapshot.asOf <= asOf,
                      holding.valuation(asOf: asOf).map({ $0.date <= snapshot.asOf }) ?? true else { return nil }
                replaced.insert(manualID)
            }
            return snapshot.allocationHolding
        }
        return manual.filter { !replaced.contains($0.id) } + confirmed + fundHoldings
    }

    private static func statementAmount(_ text: String) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{1,15}(\.[0-9]{1,8})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func statementDate(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
            return date
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
