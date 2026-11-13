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
              access: "New Zealand provider. Registration and cross-border eligibility apply.",
              url: URL(string: "https://www.syndex.exchange/investors")!)
    ]
}

struct PrivateDeal: Codable, Identifiable {
    struct Company: Codable, Identifiable {
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
    }
    struct Round: Codable {
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
        let closesAt: Date?
        let sourceUrl: URL
        let verifiedAt: Date
        let traction: String?
        let company: Company
        let shareClasses: [ShareClass]
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

    var displayedStatus: String {
        if status == "closed" { return "Closed" }
        if let deadline = round.closesAt, deadline <= .now { return "Deadline passed" }
        let now = Date.now
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
    let findings: [Finding]
    let committee: Finding?
    let models: [String]
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
    let company: Company
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
    let currency: String
    let provider: String
    let providerReference: String?
    let confirmedAt: Date?
    let coolingOffEndsAt: Date?
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

enum PrivateMarketsAPI {
    struct Catalog: Decodable { let deals: [PrivateDeal] }
    struct Items: Decodable { let items: [PrivateSavedItem] }
    struct Updates: Decodable { let updates: [PrivateCompanyUpdate] }
    struct MonitorInbox: Decodable { let alerts: [PrivateMarketAlert] }
    struct PushRegistration: Decodable { let registered: Bool }
    struct Applications: Decodable { let applications: [PrivateApplication] }
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

    var allocationHoldings: [PrivateHolding] {
        PrivateFundSnapshot.allocation(manual: state.holdings, confirmed: providerHoldings.map(\.holding),
                                       snapshots: angelListSnapshots)
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

    func change(_ edit: (inout State) -> Void) throws {
        guard storageError == nil else { throw CocoaError(.fileReadNoPermission) }
        var next = state
        edit(&next)
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

    func saveAngelListSnapshot(_ snapshot: PrivateFundSnapshot, owner: UUID, connectionID: String) throws {
        guard scope == owner else { throw CancellationError() }
        guard AngelListLink.shared.isCurrentConnection(connectionID, owner: owner) else {
            throw AngelListLink.Failure.disconnected
        }
        if let manual = snapshot.replacesManualHoldingID {
            guard state.holdings.contains(where: { $0.id == manual && $0.currency == snapshot.currency }),
                  !angelListSnapshots.contains(where: { $0.reference != snapshot.reference && $0.replacesManualHoldingID == manual }) else {
                throw SecureBackend.FunctionError(status: 422, code: "PRIVATE_FUND_ALLOCATION",
                    message: "Choose an unlinked manual holding in the same currency.")
            }
        }
        guard angelListSnapshots.count < 100 || angelListSnapshots.contains(where: { $0.reference == snapshot.reference }),
              let updated = snapshot.replacing(in: angelListSnapshots) else {
            throw SecureBackend.FunctionError(status: 422, code: "PRIVATE_FUND_SNAPSHOT",
                message: "Check the reference, date and currency against the saved statement. You can keep up to 100 statements.")
        }
        try change { $0.angelListSnapshots = updated }
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

    func checkUpdates(for userID: UUID) async throws -> [PrivateCompanyUpdate] {
        guard scope == userID, storageError == nil else { return [] }
        let companyIDs = state.follows.map(\.id) + state.holdings.compactMap(\.catalogueCompanyID) + providerHoldings.compactMap(\.companyId)
        var seen = Set<UUID>()
        let ids = companyIDs.filter { seen.insert($0).inserted }.map(\.uuidString)
        guard !ids.isEmpty else { return [] }
        var updates: [PrivateCompanyUpdate] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let response: PrivateMarketsAPI.Updates = try await PrivateMarketsAPI.request(
                "updates", ["company_ids": Array(ids[start..<min(start + 100, ids.count)])], expectedUserID: userID)
            updates.append(contentsOf: response.updates)
        }
        try Task.checkCancellation()
        guard scope == userID else { return [] }
        updates.sort { $0.publishedAt > $1.publishedAt }
        if state.notify, state.monitorEnabled != true, !deliveringUpdates {
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
                content.body = update.kind == "open_round" || update.kind == "interest" ?
                    "A company you track has a funding update." : "A company you track has published an update."
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
        let now = Date.now
        let recent = alerts.filter { !seen.contains($0.id) && !state.seenUpdates.contains($0.subjectId) &&
            $0.kind != "capital_call" && now.timeIntervalSince($0.occurredAt) < 7 * 86_400 }
        var delivered: [UUID] = []
        for alert in recent.prefix(10) {
            guard scope == owner, state.notify, state.monitorEnabled == true, !Task.isCancelled else { break }
            let content = UNMutableNotificationContent()
            content.title = "Private Markets update"
            content.body = "There is a new update in your Private Markets inbox."
            content.userInfo = ["privateMarkets": true]
            do {
                try await UNUserNotificationCenter.current().add(.init(identifier: "private-markets.monitor.\(alert.id)",
                                                                        content: content, trigger: nil))
                delivered.append(alert.id)
            } catch { }
        }
        if !delivered.isEmpty, scope == owner {
            try? change { $0.seenMonitorAlerts = Array((($0.seenMonitorAlerts ?? []) + delivered).suffix(300)) }
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
        let positions = state.holdings + providerHoldings.map(\.holding)
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
