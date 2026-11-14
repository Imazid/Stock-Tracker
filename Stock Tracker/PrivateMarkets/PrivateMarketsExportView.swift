import Supabase
import SwiftUI
import UniformTypeIdentifiers

struct PrivateMarketsExportView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @ObservedObject private var mfa = MFAManager.shared
    private let accountArchive: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var owner: UUID?
    @State private var includeCloud = true
    @State private var exportTask: Task<Void, Never>?
    @State private var document: PrivateMarketsExportDocument?
    @State private var exporting = false
    @State private var progress: String?
    @State private var error: String?
    @State private var saved = false
    @State private var needsVerification = false
    @State private var code = ""

    init(owner: UUID?, accountArchive: Bool = false) {
        _owner = State(initialValue: owner)
        self.accountArchive = accountArchive
    }

    private var title: String { accountArchive ? "Export Account Data" : "Export Private Markets" }
    private var canSave: Bool {
        exportTask == nil && !exporting && auth.userId == owner &&
            (!needsVerification || (code.count == 6 && code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber)))
    }

    var body: some View {
        Form {
            Section {
                if accountArchive {
                    Text("Save a JSON copy of your Stock Tracker account, watchlists, synced portfolios, brokerage and trading records, and Private Markets records from the cloud and this iPhone.")
                } else {
                    Text("Save a JSON file with manual holdings, valuations, cash flows, followed companies and imported AngelList records stored on this iPhone.")
                }
                if owner != nil && !accountArchive {
                    Toggle("Include cloud records", isOn: $includeCloud)
                        .accessibilityIdentifier("private.export.cloud")
                        .disabled(exportTask != nil || exporting)
                    if includeCloud {
                        Text("Adds investor eligibility, provider holdings and activity, applications, alerts, saved research and document excerpts for the current account.")
                    }
                }
                Text("The exported file contains readable financial information and any included excerpts. Choose a location you trust.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if accountArchive && needsVerification {
                    TextField("Authenticator code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .disabled(exportTask != nil)
                }
                Button {
                    exportTask = Task { await prepare() }
                } label: {
                    Label(accountArchive ? "Save Account Data JSON" : "Save Private Markets JSON", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(accountArchive ? "account.export.save" : "private.export.save")
                .disabled(!canSave)
                if let progress { ProgressView(progress) }
                if let error { Text(error).foregroundStyle(.red) }
                if saved { Label("Export saved", systemImage: "checkmark.circle") }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: accountArchive ? "stock-tracker-account" : "stock-tracker-private-markets", onCompletion: { result in
            document = nil
            switch result {
            case .success: saved = true
            case .failure: error = "Couldn’t save the export. Try again."
            }
        })
        .onChange(of: exporting) { _, presented in
            if !presented { document = nil }
        }
        .onChange(of: auth.userId) { _, id in
            if id != owner { clearExport(); dismiss() }
        }
        .onDisappear { clearExport() }
    }

    private func clearExport() {
        exportTask?.cancel()
        code = ""
        document = nil
        exporting = false
    }

    private func prepare() async {
        defer {
            progress = nil
            exportTask = nil
        }
        saved = false
        error = nil
        do {
            guard auth.userId == owner else { throw CancellationError() }
            if accountArchive, needsVerification {
                await mfa.checkMFAStatus()
                try Task.checkCancellation()
                guard auth.userId == owner else { throw CancellationError() }
                await mfa.verifyChallenge(code: code)
                code = ""
                guard mfa.currentAAL?.currentLevel == "aal2" else {
                    error = "Verify the current code from your authenticator and try again."
                    return
                }
                needsVerification = false
            }
            let device = try PrivateMarketsStore.shared.exportDeviceRecords(for: owner)
            let payload = try await PrivateMarketsExportDocument.create(
                device: device, cloudOwner: accountArchive || includeCloud ? owner : nil,
                accountArchive: accountArchive, progress: { progress = $0 })
            try Task.checkCancellation()
            guard auth.userId == owner else { throw CancellationError() }
            document = payload
            exporting = true
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where accountArchive && failure.code == "MFA_REQUIRED" {
            needsVerification = true
            error = failure.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PrivateMarketsExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    private let data: Data

    private init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func create(device: PrivateMarketsStore.State, cloudOwner: UUID?, accountArchive: Bool,
                       progress: (String) -> Void) async throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let preferences: [String: Bool] = [
            "notifications": device.notify,
            "capital_reminders": device.capitalReminders == true,
            "online_monitoring": device.monitorEnabled == true,
            "eligible_rounds": device.monitorEligible == true,
            "daily_summaries": device.monitorDigest == true,
        ]
        var archive: [String: Data] = [
            "schema_version": Data("1".utf8),
            "exported_at": try encoder.encode(Date.now),
            "description": try encoder.encode(accountArchive
                ? "Stock Tracker account records. Cloud sections were read during the export. On-device records cover Private Markets on this iPhone."
                : "Private Markets records for review. Calculations and values are preliminary and do not calculate tax."),
        ]
        let deviceValues: [String: Data] = [
            "manual_holdings": try encoder.encode(device.holdings),
            "angellist_capital_accounts": try encoder.encode(device.angelListSnapshots ?? []),
            "followed_companies": try encoder.encode(device.follows),
            "preferences": try encoder.encode(preferences),
        ]
        archive["on_this_iphone"] = try object(deviceValues, encoder: encoder)
        if let owner = cloudOwner {
            let cloud = try await cloudRecords(for: owner, accountArchive: accountArchive, progress: progress)
            archive["cloud_records"] = try JSONSerialization.data(withJSONObject: cloud, options: [.sortedKeys])
        }
        return .init(data: try object(archive, encoder: encoder))
    }

    private static func object(_ values: [String: Data], encoder: JSONEncoder) throws -> Data {
        var data = Data("{\n".utf8)
        for (index, entry) in values.sorted(by: { $0.key < $1.key }).enumerated() {
            if index != 0 { data.append(contentsOf: ",\n".utf8) }
            data.append(try encoder.encode(entry.key))
            data.append(contentsOf: ": ".utf8)
            data.append(entry.value)
        }
        data.append(contentsOf: "\n}\n".utf8)
        return data
    }

    private struct Section: Decodable {
        let id: String
        let label: String
    }

    private struct Manifest: Decodable {
        let sections: [Section]
    }

    private static func cloudRecords(for owner: UUID, accountArchive: Bool, progress: (String) -> Void) async throws -> [String: Any] {
        let sections: [(key: String, label: String)]
        if accountArchive {
            let data = try await SecureBackend.invoke("account-export", body: [:], expectedUserID: owner)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.sections.contains(where: { $0.id == "account" }),
                  Set(manifest.sections.map(\.id)).count == manifest.sections.count else { throw CocoaError(.fileReadCorruptFile) }
            sections = manifest.sections.map { ($0.id, $0.label) }
        } else {
            sections = [
                ("investor_profile", "Investor profile"), ("eligibility", "Investor eligibility"),
                ("provider_connections", "Provider connections"), ("applications", "Applications"),
                ("provider_holdings", "Provider holdings"), ("valuations", "Valuations"),
                ("capital_calls", "Capital calls"), ("distributions", "Distributions"),
                ("sales", "Sales"), ("monitor_preferences", "Monitoring preferences"),
                ("monitoring_alerts", "Monitoring alerts"), ("research_history", "Research history"),
                ("excerpts", "Document excerpts"), ("reports", "Saved reports"),
            ]
        }
        var result: [String: Any] = [:]
        for section in sections {
            progress("Reading \(section.label.lowercased())")
            var records: [[String: Any]] = []
            var offset = 0
            while true {
                try Task.checkCancellation()
                let fields: [String: Any] = ["section": section.key, "offset": offset]
                let data = if accountArchive {
                    try await SecureBackend.invoke("account-export", body: fields, expectedUserID: owner)
                } else {
                    try await PrivateMarketsAPI.send("export_records", fields, expectedUserID: owner)
                }
                guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = page["records"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                records += rows
                if page["next_offset"] is NSNull { break }
                guard let next = page["next_offset"] as? Int, next > offset,
                      next - offset == rows.count else { throw CocoaError(.fileReadCorruptFile) }
                offset = next
            }
            result[section.key] = records
        }
        return result
    }
}
