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
    var sourceName: String { PrivateProvider.directory.first { $0.id == provider }?.name ?? provider }

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

struct ProviderPrivateHolding: Decodable, Identifiable {
    struct Commitment: Decodable {
        let provider: String
        let providerReference: String
    }
    let id: UUID
    let name: String
    let assetClass: PrivateAssetClass
    let currency: String
    let units: Decimal
    let settledAmount: Decimal
    let confirmedAt: Date
    let commitment: Commitment
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
    struct ConfirmedHoldings: Decodable { let holdings: [ProviderPrivateHolding] }
    struct Handoff: Decodable { let commitmentId: UUID; let handoffUrl: URL }

    static func request<Response: Decodable>(_ action: String, _ fields: [String: Any] = [:]) async throws -> Response {
        let data = try await send(action, fields)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let standard = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
            }
            return date
        }
        return try decoder.decode(Response.self, from: data)
    }

    @discardableResult
    static func send(_ action: String, _ fields: [String: Any]) async throws -> Data {
        let body = fields.merging(["action": action]) { _, action in action }
        return try await SecureBackend.invoke("private-markets", body: body, requiresSession: action != "catalog")
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
    }

    @Published private(set) var state = State()
    @Published private(set) var storageError: String?
    private var scope: UUID?
    private var didLoad = false
    private var deliveringUpdates = false

    func selectAccount(_ id: UUID?) {
        guard !didLoad || scope != id else { return }
        scope = id
        didLoad = true
        state = State()
        storageError = nil
        do {
            let file = try Self.file(for: id)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            }
        } catch {
            storageError = "Private records could not be opened. Try again after unlocking your device."
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
        let ids = state.follows.map { $0.id.uuidString }
        let response: PrivateMarketsAPI.Updates = try await PrivateMarketsAPI.request("updates", ["company_ids": ids])
        try Task.checkCancellation()
        guard scope == userID else { return [] }
        if state.notify, !deliveringUpdates {
            deliveringUpdates = true
            defer { deliveringUpdates = false }
            let now = Date.now
            let fresh = response.updates.filter {
                now.timeIntervalSince($0.publishedAt) < 7 * 86_400 && !state.seenUpdates.contains($0.id)
            }
            var delivered: [UUID] = []
            for update in fresh {
                guard scope == userID, state.notify, !Task.isCancelled else { break }
                let content = UNMutableNotificationContent()
                content.title = "Private Markets update"
                content.body = "A followed company has published an update."
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
        return response.updates
    }

    func checkUpdatesInBackground() async {
        guard let id = scope, state.notify, !state.follows.isEmpty else { return }
        // Session restoration can lag a cold background launch. Never load or notify another account.
        guard let sessionID = try? await SupabaseManager.auth.session.user.id, sessionID == id else { return }
        _ = try? await checkUpdates(for: id)
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
