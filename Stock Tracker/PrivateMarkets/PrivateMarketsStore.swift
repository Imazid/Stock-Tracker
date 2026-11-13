import Auth
import Combine
import Foundation
import TradingCore
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
    let publishedAt: Date
    let company: Company
}

struct PrivateApplication: Decodable, Identifiable {
    let id: UUID
    let status: String
    let requestedAmount: Decimal
    let currency: String
    let provider: String
    let providerReference: String?
    let confirmedAt: Date?
    let coolingOffEndsAt: Date?
    let acknowledgedAt: Date
}


struct PrivateInvestorProfile: Codable {
    var country: String
    var declaredClass: String
}

enum PrivateMarketsAPI {
    struct Catalog: Decodable { let deals: [PrivateDeal] }
    struct Items: Decodable { let items: [PrivateSavedItem] }
    struct Updates: Decodable { let updates: [PrivateCompanyUpdate] }
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
        var follows: [Follow] = []
        var notify = false
        var seenUpdates: [UUID] = []
        var capitalReminders: Bool?
    }

    @Published private(set) var state = State()
    @Published private(set) var storageError: String?
    @Published private(set) var providerHoldings: [ProviderPrivateHolding] = []
    @Published private(set) var providerError: String?
    @Published private(set) var loadingProviderHoldings = false
    private var providerLoadTask: Task<Void, Never>?
    private var providerRefreshID = UUID()
    private var hasLoadedProviderHoldings = false
    private var scope: UUID?
    private var didLoad = false
    private var deliveringUpdates = false

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
        state = next
        syncCapitalReminders()
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
        if state.notify, !deliveringUpdates {
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
        guard let id = scope, state.capitalReminders == true || state.notify else { return }
        // Session restoration can lag a cold background launch. Never load or notify another account.
        guard let sessionID = try? await SupabaseManager.auth.session.user.id, sessionID == id else { return }
        await refreshProviderHoldings(for: id)
        if state.notify { _ = try? await checkUpdates(for: id) }
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
