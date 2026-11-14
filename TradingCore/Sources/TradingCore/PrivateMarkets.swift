import Foundation

public enum PrivateAssetClass: String, CaseIterable, Codable, Sendable {
    case startupEquity = "Startup equity"
    case ventureFund = "Venture fund"
    case privateEquity = "Private equity"
    case syndicate = "Syndicate or SPV"
    case secondary = "Private secondary"
    case other = "Other alternative"

    public var isFund: Bool { self == .ventureFund || self == .privateEquity || self == .syndicate }
}

public struct PrivateCashFlow: Codable, Sendable, Equatable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case contribution = "Contribution"
        case distribution = "Distribution"
        case capitalCall = "Capital call"
        case sale = "Sale proceeds"

        public var isOutflow: Bool { self == .contribution || self == .capitalCall }
    }

    public var id: UUID
    public var kind: Kind
    public var amount: Decimal
    public var date: Date
    public var settled: Bool
    public var originalDueDate: Date?
    public var disposedCost: Decimal?
    public var disposedUnits: Decimal?
    public var source: String

    public init(id: UUID = UUID(), kind: Kind, amount: Decimal, date: Date, settled: Bool, source: String,
                disposedCost: Decimal? = nil, disposedUnits: Decimal? = nil) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.date = date
        self.settled = settled
        self.originalDueDate = kind == .capitalCall && !settled ? date : nil
        self.disposedCost = kind == .sale ? disposedCost : nil
        self.disposedUnits = kind == .sale ? disposedUnits : nil
        self.source = source
    }
}

public struct PrivateValuation: Codable, Sendable, Equatable {
    public var value: Decimal
    public var date: Date
    public var source: String
    public var method: String
    public var providerEventAt: Date?

    public init(value: Decimal, date: Date, source: String, method: String, providerEventAt: Date? = nil) {
        self.value = value
        self.date = date
        self.source = source
        self.method = method
        self.providerEventAt = providerEventAt
    }

    public func isStale(asOf: Date = .now) -> Bool { asOf.timeIntervalSince(date) > 90 * 86_400 }
}

public struct PrivateHolding: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var assetClass: PrivateAssetClass
    public var currency: String
    public var commitment: Decimal?
    public var units: Decimal?
    public var ownershipPercent: Decimal?
    public var shareClass: String
    public var lockupUntil: Date?
    public var catalogueCompanyID: UUID?
    public var ownershipEvidenceID: UUID?
    public var ownershipReviewedOn: Date?
    public var valuations: [PrivateValuation]
    public var cashFlows: [PrivateCashFlow]
    public var latestDispositionOn: Date?
    public var dispositionRevisionAt: Date?
    public var exitSource: String?

    public init(
        id: UUID = UUID(), name: String, assetClass: PrivateAssetClass, currency: String, commitment: Decimal? = nil,
        units: Decimal? = nil, ownershipPercent: Decimal? = nil, shareClass: String = "", lockupUntil: Date? = nil,
        valuations: [PrivateValuation] = [], cashFlows: [PrivateCashFlow] = [], catalogueCompanyID: UUID? = nil,
        ownershipEvidenceID: UUID? = nil, ownershipReviewedOn: Date? = nil,
        latestDispositionOn: Date? = nil, dispositionRevisionAt: Date? = nil, exitSource: String? = nil
    ) {
        self.id = id
        self.name = name
        self.assetClass = assetClass
        self.currency = currency
        self.commitment = commitment
        self.units = units
        self.ownershipPercent = ownershipPercent
        self.shareClass = shareClass
        self.lockupUntil = lockupUntil
        self.catalogueCompanyID = catalogueCompanyID
        self.ownershipEvidenceID = ownershipEvidenceID
        self.ownershipReviewedOn = ownershipReviewedOn
        self.valuations = valuations
        self.cashFlows = cashFlows
        self.latestDispositionOn = latestDispositionOn
        self.dispositionRevisionAt = dispositionRevisionAt
        self.exitSource = exitSource
    }

    public func valuation(asOf: Date = .now) -> PrivateValuation? {
        if let disposition = latestDispositionOn, disposition <= asOf, units == 0, let exitSource {
            return .init(value: 0, date: disposition, source: exitSource, method: "All units sold")
        }
        return valuations.filter { mark in
            guard mark.date <= asOf else { return false }
            if let disposition = latestDispositionOn, disposition <= asOf, mark.date <= disposition { return false }
            if let revision = dispositionRevisionAt, revision <= asOf {
                return mark.providerEventAt.map { $0 > revision && $0 <= asOf } ?? false
            }
            return true
        }.max { $0.date < $1.date }
    }

    public func metrics(asOf: Date = .now) -> PrivateMetrics {
        let settled = cashFlows.filter { $0.settled && $0.date <= asOf }
        let paid = settled.filter { $0.kind.isOutflow }.reduce(Decimal.zero) { $0 + $1.amount }
        let returned = settled.filter { !$0.kind.isOutflow }.reduce(Decimal.zero) { $0 + $1.amount }
        let valuation = valuation(asOf: asOf)
        let value = valuation?.value
        let hasExited = latestDispositionOn.map { $0 <= asOf } == true && units == 0 && exitSource != nil
        // Flows later than the valuation could already be included in a future mark.
        // Publish ratios and XIRR only when the mark covers all included flows.
        let comparable = valuation.map { mark in
            hasExited || settled.allSatisfy { $0.date <= mark.date }
        } ?? false
        let multiple = comparable && paid > 0 ? value.map { ($0 + returned) / paid } : nil
        let sales = settled.filter { $0.kind == .sale }
        let costOfSales = sales.compactMap(\.disposedCost)
        let disposed = costOfSales.reduce(Decimal.zero, +)
        let validBasis = paid > 0 && costOfSales.count == sales.count && disposed <= paid
        let realized = validBasis && !sales.isEmpty ? sales.reduce(Decimal.zero) { $0 + $1.amount } - disposed : nil
        let unrealized: Decimal? = hasExited ? 0 :
            validBasis && comparable && !settled.contains(where: { $0.kind == .distribution })
                ? value.map { $0 - (paid - disposed) } : nil
        let distributed = settled.filter { $0.kind == .distribution }.reduce(Decimal.zero) { $0 + $1.amount }
        let xirr = valuation.flatMap { mark in
            guard comparable else { return nil as Double? }
            return PrivateMath.xirr(
                settled.map { ($0.date, $0.kind.isOutflow ? -$0.amount : $0.amount) } + [(mark.date, mark.value)]
            )
        }
        return PrivateMetrics(paid: paid, returned: returned,
                              uncalled: commitment.map { max(0, $0 - paid) },
                              pendingCalls: cashFlows.filter { $0.kind == .capitalCall && !$0.settled }.reduce(0) { $0 + $1.amount },
                              netGain: comparable ? value.map { $0 + returned - paid } : nil,
                              realizedGain: realized, unrealizedGain: unrealized, multiple: multiple, xirr: xirr,
                              dpi: assetClass.isFund && paid > 0 ? distributed / paid : nil)
    }
}

public struct PrivateMetrics: Sendable {
    public let paid: Decimal
    public let returned: Decimal
    public let uncalled: Decimal?
    public let pendingCalls: Decimal
    public let netGain: Decimal?
    public let realizedGain: Decimal?
    public let unrealizedGain: Decimal?
    public let multiple: Decimal?
    public let xirr: Double?
    public let dpi: Decimal?
}

public enum PrivateMath {
    public static func ownership(investment: Decimal, postMoney: Decimal, nextRoundPostMoney: Decimal?, nextRoundRaise: Decimal?) -> Decimal? {
        guard investment > 0, postMoney > 0, investment <= postMoney else { return nil }
        let initial = investment / postMoney
        switch (nextRoundPostMoney, nextRoundRaise) {
        case (nil, nil): return initial
        case let (post?, raise?):
            return dilutedOwnership(initial, newCapital: raise, postMoney: post)
        default: return nil
        }
    }

    public static func dilutedOwnership(_ existingShare: Decimal, newCapital: Decimal, postMoney: Decimal) -> Decimal? {
        guard existingShare >= 0, existingShare <= 1, postMoney > 0,
              newCapital >= 0, newCapital < postMoney else { return nil }
        return existingShare * (1 - newCapital / postMoney)
    }

    /// Reports a unique, bracketed annual rate for conventional dated cash flows.
    /// A later contribution after net positive proceeds can create multiple roots.
    public static func xirr(_ cashFlows: [(Date, Decimal)]) -> Double? {
        let grouped = Dictionary(grouping: cashFlows, by: { $0.0 })
            .map { (date: $0.key, amount: $0.value.reduce(Decimal.zero) { $0 + $1.1 }) }
            .filter { $0.amount != 0 }.sorted { $0.date < $1.date }
        guard let first = grouped.first, let last = grouped.last,
              first.amount < 0, last.amount > 0, last.date > first.date else { return nil }
        let positives = grouped.drop(while: { $0.amount < 0 })
        guard positives.allSatisfy({ $0.amount > 0 }) else { return nil }
        let series = grouped.map { ($0.date.timeIntervalSince(first.date) / (365 * 86_400), NSDecimalNumber(decimal: $0.amount).doubleValue) }
        func npv(_ logRate: Double) -> Double {
            series.reduce(0) { $0 + $1.1 * exp(-logRate * $1.0) }
        }
        var low = -16.0
        var high = 16.0
        guard npv(low) > 0, npv(high) < 0 else { return nil }
        for _ in 0..<100 {
            let middle = (low + high) / 2
            if npv(middle) > 0 { low = middle } else { high = middle }
        }
        return expm1((low + high) / 2)
    }
}

/// Position records returned by the authenticated provider-ledger read. The
/// opening settlement and later capital calls are separate cash-flow entries.
public struct ProviderPrivateHolding: Decodable, Identifiable, Sendable {
    public struct Commitment: Decodable, Sendable {
        public let provider: String
        public let providerReference: String
    }

    public struct Mark: Decodable, Sendable {
        public let id: UUID
        public let value: Decimal
        public let valuedOn: Date
        public let source: String
        public let methodology: String
        public let providerEventAt: Date?
    }

    public struct Call: Decodable, Sendable {
        public let id: UUID
        public let amount: Decimal
        public let dueOn: Date
        public let settledOn: Date?
        public let source: String
    }

    public struct CancelledCall: Decodable, Identifiable, Sendable {
        public let id: UUID
        public let amount: Decimal
        public let dueOn: Date
        public let source: String
        public let cancelledAt: Date
        public let cancellationSource: String
    }

    public struct Distribution: Decodable, Sendable {
        public let id: UUID
        public let amount: Decimal
        public let receivedOn: Date
        public let source: String
    }

    public struct Disposition: Decodable, Sendable {
        public let id: UUID
        public let soldUnits: Decimal
        public let netProceeds: Decimal
        public let disposedCost: Decimal?
        public let settledOn: Date
        public let source: String
    }

    public let id: UUID
    public let name: String
    public let assetClass: PrivateAssetClass
    public let currency: String
    public let companyId: UUID?
    public let units: Decimal?
    public let ownershipPercent: Decimal?
    public let committedAmount: Decimal?
    public let settledAmount: Decimal
    public let settledOn: Date?
    public let settlementSource: String?
    public let confirmedAt: Date
    public let commitment: Commitment
    public let marks: [Mark]?
    public let calls: [Call]?
    public let cancelledCalls: [CancelledCall]?
    public let distributions: [Distribution]?
    public let dispositions: [Disposition]?
    public let remainingUnits: Decimal?
    public let lastDispositionOn: Date?
    public let dispositionRevisionAt: Date?
    public let exitSource: String?

    public var hasExited: Bool { remainingUnits == 0 && lastDispositionOn.map { $0 <= .now } == true && exitSource != nil }

    public var hasCompleteActivity: Bool {
        guard let marks, let calls, let distributions else { return false }
        return max(marks.count, calls.count, distributions.count, dispositions?.count ?? 0) <= 100 &&
            (lastDispositionOn == nil || dispositions?.isEmpty == false)
    }

    public var canCalculatePerformance: Bool {
        hasCompleteActivity && settledOn != nil && settlementSource != nil
    }

    public var holding: PrivateHolding {
        var flows = (calls ?? []).prefix(100).map { call in
            var flow = PrivateCashFlow(id: call.id, kind: .capitalCall, amount: call.amount,
                                       date: call.settledOn ?? call.dueOn, settled: call.settledOn != nil, source: call.source)
            flow.originalDueDate = call.dueOn
            return flow
        }
        flows += (distributions ?? []).prefix(100).map {
            .init(id: $0.id, kind: .distribution, amount: $0.amount, date: $0.receivedOn, settled: true, source: $0.source)
        }
        flows += (dispositions ?? []).prefix(100).map {
            .init(id: $0.id, kind: .sale, amount: $0.netProceeds, date: $0.settledOn, settled: true, source: $0.source,
                  disposedCost: $0.disposedCost, disposedUnits: $0.soldUnits)
        }
        if let settledOn, let settlementSource {
            flows.append(.init(id: id, kind: .contribution, amount: settledAmount, date: settledOn,
                               settled: true, source: settlementSource))
        }
        // Marks arrive newest first, with provider revision order as the tiebreak.
        var markedDays = Set<Date>()
        let valuations = (marks ?? []).prefix(100).compactMap { mark -> PrivateValuation? in
            guard markedDays.insert(mark.valuedOn).inserted else { return nil }
            return .init(value: mark.value, date: mark.valuedOn, source: mark.source, method: mark.methodology,
                         providerEventAt: mark.providerEventAt)
        }
        return .init(id: id, name: name, assetClass: assetClass, currency: currency, commitment: committedAmount,
                     units: remainingUnits ?? units, ownershipPercent: lastDispositionOn == nil ? ownershipPercent : nil,
                     valuations: valuations, cashFlows: flows, latestDispositionOn: lastDispositionOn,
                     dispositionRevisionAt: dispositionRevisionAt, exitSource: exitSource)
    }
}

public struct PrivateCapitalCallReminder: Equatable, Sendable {
    public let holdingID: UUID
    public let callID: UUID
    public let date: Date

    public var id: String { holdingID.uuidString + "." + callID.uuidString }
}

extension PrivateMath {
    /// Device-local notification time. Due dates are civil dates in the
    /// investor's calendar, and a reminder never schedules after its deadline.
    public static func capitalCallReminders(in holdings: [PrivateHolding], now: Date = .now,
                                           calendar: Calendar = .current) -> [PrivateCapitalCallReminder] {
        holdings.flatMap { holding in
            holding.cashFlows.compactMap { flow -> PrivateCapitalCallReminder? in
                guard flow.kind == .capitalCall, !flow.settled,
                      let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: flow.date),
                      due > now else { return nil }
                let earlier = calendar.date(byAdding: .day, value: -1, to: due) ?? due
                return .init(holdingID: holding.id, callID: flow.id, date: earlier > now ? earlier : due)
            }
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        .prefix(20).map { $0 }
    }
}
