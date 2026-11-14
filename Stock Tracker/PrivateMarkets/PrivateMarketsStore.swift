import Auth
import Combine
import Foundation
import TradingCore
import UIKit
import UserNotifications

struct PrivateProvider: Identifiable {
    let id: String
    let name: String
    let categories: String
    let access: String
    let url: URL

    static let directory: [Self] = [
        .init(id: "birchal", name: "Birchal", categories: "Australian equity crowdfunding",
              access: "Retail and wholesale offers. Birchal handles investor checks and applications.",
              url: URL(string: "https://www.birchal.com/")!),
        .init(id: "onmarket", name: "OnMarket", categories: "Australian crowdfunding and IPOs",
              access: "Offer eligibility, application documents and investment accounts are managed by OnMarket.",
              url: URL(string: "https://www.onmarket.com.au/crowdfunding-investment/")!),
        .init(id: "angellist", name: "AngelList Meridian", categories: "Venture funds and startup SPVs",
              access: "Provider accreditation and deal-room permissions apply.",
              url: URL(string: "https://help.angellist.com/hc/en-us/articles/38089333472269-What-is-Meridian")!),
        .init(id: "syndex", name: "Syndex", categories: "Private funds, registries and secondary markets",
              access: "Registry services in Australia and New Zealand. Liquidity depends on the issuer and jurisdiction.",
              url: URL(string: "https://www.syndex.com.au/")!)
    ]
}

struct PrivateDeal: Codable, Identifiable {
    struct Company: Codable, Identifiable {
        struct Financials: Codable, Identifiable {
            enum PeriodKind: String, Codable { case financialYear = "financial_year", monthSnapshot = "month_snapshot" }
            enum Assurance: String, Codable { case audited, issuerReported = "issuer_reported" }

            let id: UUID
            let periodEndOn: String
            let periodKind: PeriodKind
            let assurance: Assurance
            let currency: String
            let revenue: Decimal?
            let annualRecurringRevenue: Decimal?
            let netProfitLoss: Decimal?
            let operatingCashFlow: Decimal?
            let cashAndEquivalents: Decimal?
            let publishedOn: String
            let sourceUrl: URL
            let verifiedAt: Date

            var reportingPeriod: String {
                if periodKind == .financialYear { return "Year ended \(Round.Listing.formattedDay(periodEndOn))" }
                guard let date = CashIncomeDay.date(periodEndOn) else { return periodEndOn }
                var style = Date.FormatStyle.dateTime.month(.wide).year()
                style.timeZone = CashIncomeDay.timeZone
                return date.formatted(style)
            }
        }

        let id: UUID
        let name: String
        let sector: String
        let country: String
        let location: String?
        let description: String?
        let logoUrl: URL?
        let founders: [String]?
        let investors: [String]?
        let sourceUrl: URL
        let verifiedAt: Date
        let financials: [Financials]?
    }
    struct Round: Codable {
        struct Listing: Codable {
            enum QuotationStatus: String, Codable {
                case proposed, anticipated, listed, withdrawn

                var label: String {
                    switch self {
                    case .proposed: "Proposed first quotation"
                    case .anticipated: "Anticipated first quotation"
                    case .listed: "First quotation confirmed"
                    case .withdrawn: "Listing application withdrawn"
                    }
                }
            }

            let exchange: String
            let symbol: String
            let quotationStatus: QuotationStatus
            let expectedOfferCloseOn: String?
            let quotationOn: String?
            let sourceUrl: URL
            let verifiedAt: Date

            var hasUpcomingQuotation: Bool {
                guard quotationStatus == .proposed || quotationStatus == .anticipated, let quotationOn else { return false }
                return quotationOn >= CashIncomeDay.string(.now)
            }

            static func formattedDay(_ day: String) -> String {
                guard let date = CashIncomeDay.date(day) else { return day }
                var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
                style.timeZone = CashIncomeDay.timeZone
                return date.formatted(style)
            }

            var displayStatus: String {
                switch quotationStatus {
                case .proposed, .anticipated:
                    guard hasUpcomingQuotation else { return "Quotation confirmation pending" }
                    return quotationStatus.label
                case .listed, .withdrawn:
                    return quotationStatus.label
                }
            }
        }

        struct ShareClass: Codable {
            let name: String
            let rights: String
            let sourceUrl: URL
        }
        let id: UUID
        let stage: String
        let raised: Decimal?
        let target: Decimal?
        let valuation: Decimal?
        let valuationMethod: String?
        let currency: String
        let announcedOn: Date?
        let closesAt: Date?
        let sourceUrl: URL
        let verifiedAt: Date
        let traction: String?
        let company: Company
        let shareClasses: [ShareClass]
        let listing: Listing?
    }
    let id: UUID
    let provider: String
    let category: String
    let status: String
    let minimum: Decimal?
    let eligibility: String
    let jurisdictions: [String]
    let sourceUrl: URL
    let offerDocumentUrl: URL?
    let verifiedAt: Date
    let round: Round

    var company: Company { round.company }
    var sourceName: String {
        if provider == "issuer" { return "Company announcement" }
        return PrivateProvider.directory.first { $0.id == provider }?.name ?? provider
    }

    var displayedStatus: String { displayedStatus(at: .now) }

    func displayedStatus(at now: Date) -> String {
        if status == "closed" { return "Closed" }
        if let deadline = round.closesAt, deadline <= now { return "Deadline passed" }
        if status == "unverified" || [verifiedAt, round.verifiedAt].contains(where: { $0 > now || now.timeIntervalSince($0) > 86_400 }) {
            return "Status unverified"
        }
        if status == "open", round.closesAt != nil { return "Open at verification" }
        if status == "interest" { return "Expression of interest" }
        return "Status unverified"
    }
}

struct PrivateSavedItem: Decodable, Identifiable {
    let id: UUID
    let title: String
    let createdAt: Date
}

struct PrivateResearchRun: Decodable, Identifiable {
    let id: UUID
    let status: String
    let createdAt: Date
    let failureMessage: String?
}

struct PrivateResearchReport: Decodable {
    struct Source: Decodable, Identifiable {
        let id: String
        let title: String
        let url: URL?
    }
    struct Finding: Decodable, Identifiable {
        struct Citation: Decodable {
            let source: String
            let quote: String
        }
        var id: String { title }
        let title: String
        let analysis: String
        let confidence: String
        let evidence: [Citation]
        let missing: [String]
        let questions: [String]
        let bull: String?
        let base: String?
        let bear: String?
    }
    let id: UUID
    let createdAt: Date
    let question: String
    let sources: [Source]
    let refreshAvailable: Bool?
    let previousReportId: UUID?
    let findings: [Finding]
    let committee: Finding?
    let models: [String]
}

struct PrivateResearchRefresh: Decodable {
    struct SourceChange: Decodable, Identifiable {
        struct Field: Decodable, Identifiable {
            var id: String { field }
            let field: String
            let previous: String?
            let current: String?
        }
        var id: UUID { sourceId }
        let sourceId: UUID
        let title: String
        let fields: [Field]
    }
    let question: String
    let unavailableSources: Int
    let documents: [PrivateSavedItem]
    let deals: [PrivateDeal]
    let announcements: [PrivateCompanyUpdate]
    let newerAnnouncements: [PrivateCompanyUpdate]
    let changedDealIds: [UUID]?
    let changedAnnouncementIds: [UUID]?
    let revisionTrackingAvailable: Bool?
    let sourceChanges: [SourceChange]?
}

struct PrivateCompanyUpdate: Decodable, Identifiable {
    struct Company: Decodable { let name: String }
    let id: UUID
    let title: String
    let significance: String
    let kind: String?
    let sourceUrl: URL
    let sourceLabel: String?
    let publishedAt: Date
    let roundAnnouncedOn: Date?
    let financialPublishedOn: Date?
    let revisedAt: Date?
    let company: Company

    var activityAt: Date { max(publishedAt, revisedAt ?? publishedAt) }
    var isResearchSource: Bool { kind == "announcement" || kind == "closed_round" || kind == "financial_disclosure" }
}

enum PrivateUpdateScope {
    case tracked, owned, followed

    var title: String {
        switch self {
        case .tracked: "Tracked private companies"
        case .owned: "Private companies you own"
        case .followed: "Private companies you follow"
        }
    }
}

struct PrivateMarketAlert: Decodable, Identifiable {
    let id: UUID
    let subjectId: UUID
    let kind: String
    let companyName: String
    let title: String
    let significance: String
    let sourceUrl: URL?
    let sourceLabel: String?
    let occurredAt: Date
    let revisedAt: Date?
}

struct PrivateApplication: Decodable, Identifiable {
    struct Offer: Decodable {
        struct Round: Decodable {
            struct Company: Decodable { let name: String }
            let stage: String
            let company: Company?
        }
        let round: Round?
    }
    let id: UUID
    let status: String
    let requestedAmount: Decimal
    let providerApplicationAmount: Decimal?
    let currency: String
    let provider: String
    let providerReference: String?
    let confirmedAt: Date?
    let coolingOffEndsAt: Date?
    let supplementaryNoticeAt: Date?
    let supplementaryWithdrawalEndsAt: Date?
    let supplementaryDocumentUrl: URL?
    let acknowledgedAt: Date
    let providerReceivedAt: Date?
    let withdrawalRequestedAt: Date?
    let withdrawalDeclinedAt: Date?
    let withdrawnAt: Date?
    let providerEventAt: Date?
    let offer: Offer?
}


struct PrivateInvestorProfile: Codable {
    var country: String
    var declaredClass: String
}

struct PrivateProviderEligibility: Decodable, Identifiable {
    struct Connection: Decodable { let revokedAt: Date? }

    let provider: String
    let jurisdiction: String
    let verifiedClass: String
    let verifiedAt: Date
    let expiresAt: Date
    let accountantCertificateReviewedAt: Date?
    let connection: Connection

    var id: String { provider + ":" + jurisdiction }
    var providerName: String { PrivateProvider.directory.first { $0.id == provider }?.name ?? provider }

    func status(asOf now: Date) -> String {
        if connection.revokedAt != nil { return "Connection revoked" }
        if expiresAt <= now { return "Verification expired" }
        if verifiedAt > now { return "Verification pending" }
        return "Verification current"
    }
}

enum PrivateMarketsAPI {
    struct Catalog: Decodable { let deals: [PrivateDeal] }
    struct Items: Decodable { let items: [PrivateSavedItem] }
    struct ResearchRuns: Decodable { let runs: [PrivateResearchRun] }
    struct Updates: Decodable { let updates: [PrivateCompanyUpdate] }
    struct MonitorInbox: Decodable { let alerts: [PrivateMarketAlert] }
    struct PushRegistration: Decodable { let registered: Bool }
    struct Applications: Decodable { let applications: [PrivateApplication] }
    struct InvestorProfile: Decodable {
        let profile: PrivateInvestorProfile?
        let eligibility: [PrivateProviderEligibility]?
    }
    struct ConfirmedHoldings: Decodable {
        let holdings: [ProviderPrivateHolding]
        let nextOffset: Int?
    }
    struct Handoff: Decodable { let commitmentId: UUID; let handoffUrl: URL }

    static func request<Response: Decodable>(_ action: String, _ fields: [String: Any] = [:],
                                              expectedUserID: UUID? = nil) async throws -> Response {
        let data = try await send(action, fields, expectedUserID: expectedUserID)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let standard = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            let day = value.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
            if value.utf8.count == 10, day.count == 3,
               let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: day[0], month: day[1], day: day[2])) {
                return date
            }
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
            }
            return date
        }
        return try decoder.decode(Response.self, from: data)
    }

    @discardableResult
    static func send(_ action: String, _ fields: [String: Any], expectedUserID: UUID? = nil) async throws -> Data {
        let body = fields.merging(["action": action]) { _, action in action }
        return try await SecureBackend.invoke("private-markets", body: body, requiresSession: action != "catalog",
                                              expectedUserID: expectedUserID)
    }
}

@MainActor
final class PrivateMarketsStore: ObservableObject {
    static let shared = PrivateMarketsStore()

    struct Follow: Codable, Identifiable {
        let id: UUID
        let name: String
        let source: URL
    }

    struct State: Codable {
        var holdings: [PrivateHolding] = []
        var angelListSnapshots: [PrivateFundSnapshot]?
        var follows: [Follow] = []
        var notify = false
        var seenUpdates: [UUID] = []
        var capitalReminders: Bool?
        var monitorEnabled: Bool?
        var monitorEligible: Bool?
        var monitorDigest: Bool?
        var seenMonitorAlerts: [UUID]?
        var seenMonitorRevisions: [String]?
    }

    @Published private(set) var state = State()
    @Published private(set) var storageError: String?
    @Published private(set) var providerHoldings: [ProviderPrivateHolding] = []
    @Published private(set) var providerError: String?
    @Published private(set) var loadingProviderHoldings = false
    @Published private(set) var monitorAlerts: [PrivateMarketAlert] = []
    @Published private(set) var monitorError: String?
    @Published private(set) var remotePushActive = false
    private var pushToken: String?
    private var pushPermissionDenied = false
    private var monitorSettingsTask: Task<Void, Error>?
    private var monitorSettingsRevision = UUID()
    private var monitorLastSync: Date?
    private var providerLoadTask: Task<Void, Never>?
    private var providerRefreshID = UUID()
    private var hasLoadedProviderHoldings = false
    private var scope: UUID?
    private var didLoad = false
    private var deliveringUpdates = false

    var angelListSnapshots: [PrivateFundSnapshot] { state.angelListSnapshots ?? [] }

    var independentManualHoldings: [PrivateHolding] { state.holdings.filter { $0.matchingProviderHoldingID == nil } }
    var activeManualHoldings: [PrivateHolding] { independentManualHoldings.filter { $0.closedOn() == nil } }

    var unavailableLinkedProviderCount: Int {
        let available = Set(providerHoldings.map(\.id))
        return state.holdings.compactMap(\.matchingProviderHoldingID).filter { !available.contains($0) }.count
    }

    var allocationHoldings: [PrivateHolding] {
        PrivateFundSnapshot.allocation(manual: state.holdings, confirmed: providerHoldings.filter { !$0.hasExited }.map(\.holding),
                                       snapshots: angelListSnapshots)
    }

    func linkedFundValuation(for holding: PrivateHolding) -> (statement: PrivateFundSnapshot, holding: PrivateHolding)? {
        PrivateFundSnapshot.linkedValuation(for: holding, snapshots: angelListSnapshots)
    }

    func selectAccount(_ id: UUID?) {
        guard !didLoad || scope != id else { return }
        let previous = scope
        scope = id
        didLoad = true
        if previous != id {
            reminderTask?.cancel()
            cancelCapitalReminders(scope: previous)
        }
        state = State()
        storageError = nil
        providerHoldings = []
        providerError = nil
        loadingProviderHoldings = false
        monitorSettingsTask?.cancel()
        monitorSettingsTask = nil
        monitorSettingsRevision = UUID()
        monitorLastSync = nil
        monitorAlerts = []
        monitorError = nil
        remotePushActive = false
        providerLoadTask?.cancel()
        providerLoadTask = nil
        providerRefreshID = UUID()
        hasLoadedProviderHoldings = false
        do {
            let file = try Self.file(for: id)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            }
            syncCapitalReminders()
        } catch {
            storageError = "Private records could not be opened. Try again after unlocking your device."
        }
    }

    func refreshProviderHoldings(for userID: UUID) async {
        guard scope == userID, SecureBackend.isConfigured else { return }
        if let providerLoadTask {
            await providerLoadTask.value
            return
        }
        loadingProviderHoldings = true
        providerError = nil
        let refreshID = UUID()
        providerRefreshID = refreshID
        let task = Task { await loadProviderHoldings(for: userID, refreshID: refreshID) }
        providerLoadTask = task
        await task.value
    }

    private func loadProviderHoldings(for userID: UUID, refreshID: UUID) async {
        defer {
            if providerRefreshID == refreshID {
                loadingProviderHoldings = false
                providerLoadTask = nil
            }
        }

        do {
            var holdings: [ProviderPrivateHolding] = []
            var offset = 0
            for _ in 0..<50 {
                let page: PrivateMarketsAPI.ConfirmedHoldings = try await PrivateMarketsAPI.request(
                    "confirmed_holdings", ["offset": offset], expectedUserID: userID)
                try Task.checkCancellation()
                guard providerRefreshID == refreshID, scope == userID else { return }
                holdings.append(contentsOf: page.holdings)
                guard let next = page.nextOffset else {
                    var ids = Set<UUID>()
                    hasLoadedProviderHoldings = true
                    providerHoldings = holdings.filter { ids.insert($0.id).inserted }
                    syncCapitalReminders()
                    return
                }
                guard next > offset else { break }
                offset = next
            }
            providerError = "The provider returned an incomplete portfolio."
        } catch is CancellationError {
        } catch {
            if providerRefreshID == refreshID, scope == userID { providerError = error.localizedDescription }
        }
    }

    func retryStorage() {
        didLoad = false
        selectAccount(scope)
    }

    func exportDeviceRecords(for owner: UUID?) throws -> State {
        guard didLoad, scope == owner else { throw CancellationError() }
        guard storageError == nil else { throw CocoaError(.fileReadNoPermission) }
        return state
    }

    func change(_ edit: (inout State) throws -> Void) throws {
        guard storageError == nil else { throw CocoaError(.fileReadNoPermission) }
        var next = state
        try edit(&next)
        let data = try JSONEncoder().encode(next)
        try data.write(to: Self.file(for: scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let monitorScopeChanged = monitoredCompanies(in: next) != monitoredCompanies(in: state)
        state = next
        syncCapitalReminders()
        if monitorScopeChanged, state.monitorEnabled == true, let scope { queueMonitorSettings(for: scope) }
    }

    func save(_ holding: PrivateHolding) throws {
        try change { next in
            if let index = next.holdings.firstIndex(where: { $0.id == holding.id }) {
                next.holdings[index] = holding
            } else {
                next.holdings.append(holding)
            }
        }
    }

    func availableProviderMatches(for holding: PrivateHolding) -> [ProviderPrivateHolding] {
        guard holding.closedOn() == nil, !loadingProviderHoldings, providerError == nil,
              !angelListSnapshots.contains(where: { $0.replacesManualHoldingID == holding.id }) else { return [] }
        let linkedIDs = Set(state.holdings.filter { $0.id != holding.id }.compactMap(\.matchingProviderHoldingID))
        return providerHoldings.filter { !linkedIDs.contains($0.id) && holding.canLinkProviderHolding($0.holding) }
    }

    func setProviderMatch(_ providerID: UUID?, for holdingID: UUID, owner: UUID) throws {
        guard scope == owner, var holding = state.holdings.first(where: { $0.id == holdingID }) else {
            throw CancellationError()
        }
        if let providerID {
            guard let position = availableProviderMatches(for: holding).first(where: { $0.id == providerID }),
                  holding.linkProviderHolding(position.holding) else {
                throw SecureBackend.FunctionError(status: 422, code: "PRIVATE_HOLDING_MATCH",
                    message: "Choose an available provider record for the same position.")
            }
        } else {
            holding.unlinkProviderHolding()
        }
        try save(holding)
    }

    func saveAngelListSnapshot(_ snapshot: PrivateFundSnapshot, owner: UUID, connectionID: String) throws {
        guard scope == owner else { throw CancellationError() }
        guard AngelListLink.shared.isCurrentConnection(connectionID, owner: owner) else {
            throw AngelListLink.Failure.disconnected
        }
        let existing = angelListSnapshots.contains { $0.reference == snapshot.reference }
        if !existing, case .linked(let id) = snapshot.placement,
           !eligibleFundHoldings(currency: snapshot.currency, excludingReference: snapshot.reference).contains(where: { $0.id == id }) {
            throw invalidFundPlacement()
        }
        guard angelListSnapshots.count < 100 || existing,
              let updated = snapshot.replacing(in: angelListSnapshots) else {
            throw SecureBackend.FunctionError(status: 422, code: "PRIVATE_FUND_SNAPSHOT",
                message: "Check the reference, date and currency against the saved statement. You can keep up to 100 statements.")
        }
        try change { $0.angelListSnapshots = updated }
    }

    func eligibleFundHoldings(currency: String, excludingReference reference: String) -> [PrivateHolding] {
        let taken = Set(angelListSnapshots.filter { $0.reference != reference }.compactMap(\.replacesManualHoldingID))
        return activeManualHoldings.filter { $0.currency == currency && !taken.contains($0.id) }
    }

    func setAngelListPlacement(_ placement: PrivateFundSnapshot.Placement, for id: UUID, owner: UUID) throws {
        guard scope == owner, let statement = angelListSnapshots.first(where: { $0.id == id }) else { throw CancellationError() }
        if case .linked(let holdingID) = placement,
           !eligibleFundHoldings(currency: statement.currency, excludingReference: statement.reference).contains(where: { $0.id == holdingID }) {
            throw invalidFundPlacement()
        }
        try change { state in
            state.angelListSnapshots = state.angelListSnapshots?.map { $0.id == id ? $0.placed(placement) : $0 }
        }
    }

    private func invalidFundPlacement() -> SecureBackend.FunctionError {
        .init(status: 422, code: "PRIVATE_FUND_ALLOCATION", message: "Choose an available manual holding in the same currency.")
    }

    func removeAngelListSnapshot(_ id: UUID, owner: UUID) throws {
        guard scope == owner else { throw CancellationError() }
        try change { $0.angelListSnapshots?.removeAll { $0.id == id } }
    }

    func removeAngelListSnapshots(owner: UUID) throws {
        guard scope == owner else { throw CancellationError() }
        try change { $0.angelListSnapshots = nil }
    }

    func updateOwnershipEvidence(for holdingID: UUID, owner: UUID, documentID: UUID?) throws {
        guard scope == owner, state.holdings.contains(where: { $0.id == holdingID }) else { throw CancellationError() }
        try change { next in
            guard let index = next.holdings.firstIndex(where: { $0.id == holdingID }) else { return }
            next.holdings[index].ownershipEvidenceID = documentID
            next.holdings[index].ownershipReviewedOn = documentID == nil ? nil : .now
        }
    }

    func removeOwnershipEvidence(_ documentID: UUID, owner: UUID) throws {
        guard scope == owner else { throw CancellationError() }
        guard state.holdings.contains(where: { $0.ownershipEvidenceID == documentID }) else { return }
        try change { next in
            for index in next.holdings.indices where next.holdings[index].ownershipEvidenceID == documentID {
                next.holdings[index].ownershipEvidenceID = nil
                next.holdings[index].ownershipReviewedOn = nil
            }
        }
    }

    func toggleFollow(_ deal: PrivateDeal) throws {
        guard state.follows.count < 100 || state.follows.contains(where: { $0.id == deal.company.id }) else {
            throw NSError(domain: "PrivateMarkets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your watchlist can hold up to 100 companies."])
        }
        try change { next in
            if next.follows.contains(where: { $0.id == deal.company.id }) {
                next.follows.removeAll { $0.id == deal.company.id }
            } else {
                next.follows.append(.init(id: deal.company.id, name: deal.company.name, source: deal.company.sourceUrl))
            }
        }
    }

    func checkUpdates(for userID: UUID, companyScope: PrivateUpdateScope = .tracked,
                      deliverNotifications: Bool = true) async throws -> [PrivateCompanyUpdate] {
        guard scope == userID else { throw CancellationError() }
        if let storageError {
            throw NSError(domain: "PrivateMarkets", code: 1, userInfo: [NSLocalizedDescriptionKey: storageError])
        }
        let followed = state.follows.map(\.id)
        let companyIDs: [UUID]
        switch companyScope {
        case .tracked:
            companyIDs = followed + state.holdings.compactMap(\.catalogueCompanyID) + providerHoldings.compactMap(\.companyId)
        case .owned:
            companyIDs = activeManualHoldings.compactMap(\.catalogueCompanyID) +
                providerHoldings.filter { !$0.hasExited }.compactMap(\.companyId)
        case .followed:
            companyIDs = followed
        }
        let ids = Set(companyIDs).map(\.uuidString).sorted()
        var updates: [PrivateCompanyUpdate] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let response: PrivateMarketsAPI.Updates = try await PrivateMarketsAPI.request(
                "updates", ["company_ids": Array(ids[start..<min(start + 100, ids.count)])], expectedUserID: userID)
            updates.append(contentsOf: response.updates)
        }
        try Task.checkCancellation()
        guard scope == userID else { throw CancellationError() }
        updates.sort { ($0.activityAt, $0.id.uuidString) > ($1.activityAt, $1.id.uuidString) }
        if deliverNotifications, state.notify, state.monitorEnabled != true, !deliveringUpdates {
            deliveringUpdates = true
            defer { deliveringUpdates = false }
            let now = Date.now
            let fresh = updates.filter {
                now.timeIntervalSince($0.publishedAt) < 7 * 86_400 && !state.seenUpdates.contains($0.id)
            }
            var delivered: [UUID] = []
            for update in fresh {
                guard scope == userID, state.notify, !Task.isCancelled else { break }
                let content = UNMutableNotificationContent()
                content.title = "Private Markets update"
                content.body = switch update.kind {
                case "open_round", "interest", "closed_round": "A company you track has a funding update."
                default: "A company you track has published an update."
                }
                content.userInfo = ["privateMarkets": true]
                do {
                    try await UNUserNotificationCenter.current().add(.init(
                        identifier: "private-markets.\(update.id)", content: content, trigger: nil))
                    delivered.append(update.id)
                } catch {
                    // Keep failed notifications eligible for the next background refresh.
                }
            }
            if !delivered.isEmpty, scope == userID {
                try change { $0.seenUpdates = Array(($0.seenUpdates + delivered).suffix(300)) }
            }
        }
        return updates
    }

    func checkUpdatesInBackground() async {
        // Session restoration can lag a cold background launch.
        guard let id = try? await SupabaseManager.auth.session.user.id else { return }
        if scope == nil { selectAccount(id) }
        guard scope == id, state.capitalReminders == true || state.notify || state.monitorEnabled != nil else { return }
        await refreshProviderHoldings(for: id)
        if state.notify && state.monitorEnabled != true { _ = try? await checkUpdates(for: id) }
        await refreshMonitor(for: id)
    }

    func setMonitor(enabled: Bool, eligible: Bool, digest: Bool, owner: UUID) async throws {
        guard scope == owner else { throw CancellationError() }
        try change {
            $0.monitorEnabled = enabled
            $0.monitorEligible = enabled && eligible
            $0.monitorDigest = enabled && digest
        }
        if !enabled {
            monitorAlerts = []
            remotePushActive = false
        }
        try await queueMonitorSettings(for: owner)?.value
    }

    private static var pushEnvironment: String? {
        switch Bundle.main.object(forInfoDictionaryKey: "PrivateMarketAPSEnvironment") as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    func setUpdateNotifications(_ enabled: Bool, owner: UUID) async throws {
        guard scope == owner else { throw CancellationError() }
        try change { $0.notify = enabled }
        if !enabled { remotePushActive = false }
        if state.monitorEnabled == true {
            await refreshPushPermission(for: owner)
            guard scope == owner else { throw CancellationError() }
            try await queueMonitorSettings(for: owner)?.value
        }
    }

    func receivedPushToken(_ value: Data) {
        guard !pushPermissionDenied else { return }
        let token = value.map { String(format: "%02x", $0) }.joined()
        if token != pushToken || !remotePushActive {
            pushToken = token
            if let scope, state.monitorEnabled == true, state.notify {
                remotePushActive = false
                queueMonitorSettings(for: scope)
            }
        }
    }

    func pushRegistrationFailed() {
        guard pushToken != nil || remotePushActive else { return }
        pushToken = nil
        remotePushActive = false
        if let scope, state.monitorEnabled == true { queueMonitorSettings(for: scope) }
    }

    private func refreshPushPermission(for owner: UUID) async {
        guard Self.pushEnvironment != nil, state.monitorEnabled == true, state.notify else { return }
        let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard scope == owner, state.monitorEnabled == true, state.notify else { return }
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            pushPermissionDenied = false
            if UIApplication.shared.applicationState == .active,
               !UIApplication.shared.isRegisteredForRemoteNotifications || pushToken == nil {
                UIApplication.shared.registerForRemoteNotifications()
            }
        default:
            if !pushPermissionDenied {
                pushPermissionDenied = true
                pushToken = nil
                remotePushActive = false
                queueMonitorSettings(for: owner)
            }
        }
    }

    func refreshMonitor(for owner: UUID) async {
        guard scope == owner, let enabled = state.monitorEnabled else { return }
        await refreshPushPermission(for: owner)
        guard scope == owner, state.monitorEnabled == enabled else { return }
        if monitorSettingsTask == nil && (monitorLastSync == nil ||
            (enabled && Date.now.timeIntervalSince(monitorLastSync ?? .distantPast) >= 86_400)) {
            queueMonitorSettings(for: owner)
        }
        let revision = monitorSettingsRevision
        do {
            try await monitorSettingsTask?.value
            try Task.checkCancellation()
            guard scope == owner, revision == monitorSettingsRevision else { return }
            guard enabled else {
                monitorAlerts = []
                return
            }
            let inbox: PrivateMarketsAPI.MonitorInbox = try await PrivateMarketsAPI.request("monitor_inbox", expectedUserID: owner)
            try Task.checkCancellation()
            guard scope == owner, state.monitorEnabled == true, revision == monitorSettingsRevision else { return }
            monitorAlerts = inbox.alerts
            await deliverMonitorNotifications(inbox.alerts, owner: owner)
        } catch is CancellationError {
        } catch {
            if scope == owner, revision == monitorSettingsRevision { monitorError = error.localizedDescription }
        }
    }

    @discardableResult
    private func queueMonitorSettings(for owner: UUID) -> Task<Void, Error>? {
        guard scope == owner, let enabled = state.monitorEnabled else { return nil }
        let previous = monitorSettingsTask
        let revision = UUID()
        monitorSettingsRevision = revision
        monitorLastSync = nil
        let fields: [String: Any] = [
            "enabled": enabled,
            "device_id": Self.monitorDeviceID.uuidString,
            "eligible_opportunities": state.monitorEligible == true,
            "digest": state.monitorDigest == true,
            "company_ids": enabled ? monitoredCompanies(in: state).map(\.uuidString) : [],
        ]
        let environment = Self.pushEnvironment
        let token = state.notify ? pushToken : nil
        let updatePush = !state.notify || pushPermissionDenied || token != nil
        monitorError = nil
        let task = Task {
            _ = await previous?.result
            defer {
                if monitorSettingsRevision == revision { monitorSettingsTask = nil }
            }
            guard scope == owner, monitorSettingsRevision == revision else { return }
            try Task.checkCancellation()
            do {
                try await PrivateMarketsAPI.send("monitor_settings", fields, expectedUserID: owner)
                guard scope == owner, monitorSettingsRevision == revision else { return }
                if enabled, updatePush, let environment {
                    let push: PrivateMarketsAPI.PushRegistration = try await PrivateMarketsAPI.request("monitor_push", [
                        "device_id": Self.monitorDeviceID.uuidString,
                        "environment": environment,
                        "token": token as Any? ?? NSNull(),
                    ], expectedUserID: owner)
                    guard scope == owner, monitorSettingsRevision == revision else { return }
                    remotePushActive = push.registered
                }
                monitorLastSync = .now
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if scope == owner, monitorSettingsRevision == revision { monitorError = error.localizedDescription }
                throw error
            }
        }
        monitorSettingsTask = task
        return task
    }

    private func monitoredCompanies(in records: State) -> [UUID] {
        var seen = Set<UUID>()
        return Array((records.follows.map(\.id) + records.holdings.compactMap(\.catalogueCompanyID))
            .filter { seen.insert($0).inserted }.prefix(250))
    }

    private static var monitorDeviceID: UUID {
        let key = "privateMarketMonitorDeviceID"
        if let value = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) { return value }
        let value = UUID()
        UserDefaults.standard.set(value.uuidString, forKey: key)
        return value
    }

    private func deliverMonitorNotifications(_ alerts: [PrivateMarketAlert], owner: UUID) async {
        guard state.notify, !remotePushActive, !deliveringUpdates else { return }
        deliveringUpdates = true
        defer { deliveringUpdates = false }
        let seen = Set(state.seenMonitorAlerts ?? [])
        let seenRevisions = Set(state.seenMonitorRevisions ?? [])
        let now = Date.now
        let recent = alerts.compactMap { alert -> (PrivateMarketAlert, String?)? in
            if let revised = alert.revisedAt {
                let key = "\(alert.id.uuidString).\(revised.timeIntervalSince1970)"
                return !seenRevisions.contains(key) && now.timeIntervalSince(revised) < 7 * 86_400 ? (alert, key) : nil
            }
            guard !seen.contains(alert.id), !state.seenUpdates.contains(alert.subjectId), alert.kind != "capital_call",
                  now.timeIntervalSince(alert.occurredAt) < 7 * 86_400 else { return nil }
            return (alert, nil)
        }
        var delivered: [UUID] = []
        var deliveredRevisions: [String] = []
        for (alert, revision) in recent.prefix(10) {
            guard scope == owner, state.notify, state.monitorEnabled == true, !Task.isCancelled else { break }
            let content = UNMutableNotificationContent()
            content.title = "Private Markets update"
            content.body = "There is a new update in your Private Markets inbox."
            content.userInfo = ["privateMarkets": true]
            do {
                try await UNUserNotificationCenter.current().add(.init(identifier: "private-markets.monitor.\(revision ?? alert.id.uuidString)",
                                                                        content: content, trigger: nil))
                delivered.append(alert.id)
                if let revision { deliveredRevisions.append(revision) }
            } catch { }
        }
        if !delivered.isEmpty, scope == owner {
            try? change {
                $0.seenMonitorAlerts = Array((($0.seenMonitorAlerts ?? []) + delivered).suffix(300))
                $0.seenMonitorRevisions = Array((($0.seenMonitorRevisions ?? []) + deliveredRevisions).suffix(300))
            }
        }
    }

    func setCapitalReminders(_ enabled: Bool) async throws {
        let owner = scope
        if enabled {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard allowed else {
                throw NSError(domain: "PrivateMarkets", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Allow notifications in iOS Settings to receive capital call reminders."])
            }
        }
        guard scope == owner else { return }
        try change { $0.capitalReminders = enabled }
    }

    private var reminderTask: Task<Void, Never>?

    private func syncCapitalReminders() {
        let previousTask = reminderTask
        previousTask?.cancel()
        let owner = scope
        guard state.capitalReminders == true else {
            cancelCapitalReminders(scope: owner)
            return
        }
        let positions = independentManualHoldings + providerHoldings.map(\.holding)
        let reminders = PrivateMath.capitalCallReminders(in: positions)
        reminderTask = Task {
            await previousTask?.value
            guard !Task.isCancelled, scope == owner else { return }
            let center = UNUserNotificationCenter.current()
            let prefix = reminderPrefix(owner)
            let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
            guard !Task.isCancelled, scope == owner else { return }
            // Preserve previously scheduled provider reminders when a new sign-in has
            // yet to retrieve the provider's ledger.
            let desired = Set(reminders.map { prefix + $0.id })
            let obsolete = pending.filter { item in
                let provider = item.content.userInfo["providerRecord"] as? Bool == true
                return !desired.contains(item.identifier) && (!provider || hasLoadedProviderHoldings)
            }
            center.removePendingNotificationRequests(withIdentifiers: obsolete.map(\.identifier))
            let providerIDs = Set(providerHoldings.map(\.id))
            for reminder in reminders {
                guard !Task.isCancelled, scope == owner else { return }
                let content = UNMutableNotificationContent()
                content.title = "Capital call reminder"
                content.body = "Review the payment deadline and source in Private Markets."
                content.userInfo = ["privateMarkets": true, "capitalCalls": true,
                                    "providerRecord": providerIDs.contains(reminder.holdingID)]
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try? await center.add(.init(identifier: prefix + reminder.id, content: content, trigger: trigger))
                if Task.isCancelled || scope != owner {
                    center.removePendingNotificationRequests(withIdentifiers: [prefix + reminder.id])
                    return
                }
            }
        }
    }

    private func reminderPrefix(_ owner: UUID?) -> String {
        "private-markets.capital." + (owner?.uuidString ?? "device") + "."
    }

    private func cancelCapitalReminders(scope owner: UUID?) {
        let prefix = reminderPrefix(owner)
        let previousTask = reminderTask
        Task {
            await previousTask?.value
            let center = UNUserNotificationCenter.current()
            let requests = await center.pendingNotificationRequests()
            guard scope != owner || state.capitalReminders != true else { return }
            center.removePendingNotificationRequests(withIdentifiers: requests.filter {
                $0.identifier.hasPrefix(prefix)
            }.map(\.identifier))
        }
    }

    func removeAccountRecords(_ owner: UUID) throws {
        if scope == owner { selectAccount(nil) }
        let file = try Self.file(for: owner)
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    static func clearTestRecords() {
        guard let file = try? file(for: nil) else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func file(for id: UUID?) throws -> URL {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("PrivateMarkets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        return directory.appendingPathComponent(id?.uuidString ?? "device").appendingPathExtension("json")
    }
}

extension URL {
    var privateSourceIsSafe: Bool {
        scheme == "https" && host?.isEmpty == false && user == nil && password == nil
    }
}
