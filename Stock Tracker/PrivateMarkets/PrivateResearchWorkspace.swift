import PDFKit
import SwiftUI
import TradingCore
import UniformTypeIdentifiers
import Vision

struct PrivateResearchWorkspace: View {
    let deals: [PrivateDeal]
    var selectedDealID: UUID?
    var announcements: [PrivateCompanyUpdate] = []
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var documents: [PrivateSavedItem] = []
    @State private var reports: [PrivateSavedItem] = []
    @State private var selectedDeals: Set<UUID> = []
    @State private var selectedDocuments: Set<UUID> = []
    @State private var selectedAnnouncements: Set<UUID> = []
    @State private var question = ""
    @State private var consent = false
    @State private var busy = false
    @State private var loading = false
    @State private var result: PrivateResearchReport?
    @State private var runTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        List {
            Section("Scenario calculator") {
                NavigationLink("Ownership, dilution and exit scenarios") { PrivateScenarioCalculator() }
            }
            if auth.userId == nil {
                Section("Research") {
                    Text("Sign in from Account to run and save AI research.")
                    Text("The scenario calculator works on this device.")
                }
            } else {
                Section("Research question") {
                    TextField("Ask about a company, valuation or risk", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Choose up to three sources. The committee runs five specialist reviews and a synthesis.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !deals.isEmpty {
                    Section("Published opportunities") {
                        ForEach(deals) { deal in
                            Toggle("\(deal.company.name) · \(deal.round.stage)",
                                   isOn: selection(deal.id, in: $selectedDeals))
                        }
                    }
                }
                if !announcements.isEmpty {
                    Section("Published company announcements") {
                        ForEach(announcements) { item in
                            Toggle("\(item.company.name) · \(item.title)",
                                   isOn: selection(item.id, in: $selectedAnnouncements))
                        }
                    }
                }
                Section("Private excerpts") {
                    if loading {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in SearchRowSkeleton() }
                        }
                        .privateLoadingLabel("Loading saved sources")
                    }
                    if documents.isEmpty && !loading {
                        Text("Add authorized text in the Deal Room.").foregroundStyle(.secondary)
                    }
                    ForEach(documents) { item in Toggle(item.title, isOn: selection(item.id, in: $selectedDocuments)) }
                    if !selectedDocuments.isEmpty {
                        Toggle("I have permission to send these excerpts to Stock Tracker’s configured AI provider", isOn: $consent)
                    }
                }
                Section {
                    Button("Ask a question") { run("question") }.disabled(!canRun)
                    Button("Run Investment Committee") { run("committee") }.disabled(!canRun)
                    if busy { SkeletonBlock(height: 12).privateLoadingLabel("Analyzing sources") }
                    if let result {
                        NavigationLink("Open latest report") { PrivateReportView(report: result) }
                    }
                }
                Section("Saved reports") {
                    if reports.isEmpty && !loading { Text("No saved reports").foregroundStyle(.secondary) }
                    ForEach(reports) { item in
                        NavigationLink(item.title) { PrivateSavedReportView(item: item) }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    guard let owner = auth.userId else { return }
                                    Task {
                                        do {
                                            try await PrivateMarketsAPI.send("delete_report", ["id": item.id.uuidString], expectedUserID: owner)
                                            guard auth.userId == owner else { return }
                                            reports.removeAll { $0.id == item.id }
                                            if result?.id == item.id { result = nil }
                                        } catch is CancellationError {
                                        } catch { self.error = error.localizedDescription }
                                    }
                                }
                            }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Color.orange) } }
            }
        }
        .onDisappear { runTask?.cancel() }
        .navigationTitle("AI Investment Research")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let selectedDealID, selectedDeals.isEmpty { selectedDeals.insert(selectedDealID) }
            if !announcements.isEmpty, question.isEmpty {
                selectedAnnouncements = Set(announcements.prefix(3).map(\.id))
                question = "Summarise these company announcements. Explain what changed and what the sources leave unanswered."
            }
            await load()
        }
        .refreshable { await load() }
    }

    private var sourceCount: Int { selectedDeals.count + selectedDocuments.count + selectedAnnouncements.count }

    private var canRun: Bool {
        !busy && sourceCount > 0 && sourceCount <= 3 && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            question.utf16.count <= 1_000 && (selectedDocuments.isEmpty || consent)
    }

    private func selection(_ id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { selected in
            if selected, sourceCount < 3 {
                set.wrappedValue.insert(id)
            } else if !selected {
                set.wrappedValue.remove(id)
            }
        })
    }

    private func load() async {
        guard let owner = auth.userId else { return }
        loading = true
        defer { loading = false }
        do {
            let documentList: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            let reportList: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("reports", expectedUserID: owner)
            try Task.checkCancellation()
            guard auth.userId == owner else { return }
            documents = documentList.items
            reports = reportList.items
            selectedDocuments.formIntersection(documents.map(\.id))
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ mode: String) {
        guard let owner = auth.userId else { return }
        let fields: [String: Any] = [
            "mode": mode, "question": question, "document_ids": selectedDocuments.map(\.uuidString),
            "opportunity_ids": selectedDeals.map(\.uuidString), "ai_consent": consent,
            "announcement_ids": selectedAnnouncements.map(\.uuidString)
        ]
        error = nil
        busy = true
        runTask = Task {
            defer { busy = false }
            do {
                let report: PrivateResearchReport
                if mode == "committee" {
                    report = try await runCommittee(fields, owner: owner)
                } else {
                    report = try await PrivateMarketsAPI.request("research", fields, expectedUserID: owner)
                }
                try Task.checkCancellation()
                guard auth.userId == owner else { return }
                result = report
                await load()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func runCommittee(_ fields: [String: Any], owner: UUID) async throws -> PrivateResearchReport {
        struct Started: Decodable { let id: UUID }
        struct Status: Decodable { let status: String; let failureMessage: String? }
        var request = fields
        request["background"] = true
        let run: Started = try await PrivateMarketsAPI.request("research", request, expectedUserID: owner)
        let target = ["id": run.id.uuidString]
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(3))
            let progress: Status = try await PrivateMarketsAPI.request("research_status", target, expectedUserID: owner)
            if progress.status == "complete" { return try await PrivateMarketsAPI.request("report", target, expectedUserID: owner) }
            if progress.status == "failed", let message = progress.failureMessage {
                throw SecureBackend.FunctionError(status: 502, code: "COMMITTEE_UNAVAILABLE", message: message)
            }
            if progress.status == "failed" { break }
        }
        throw SecureBackend.FunctionError(status: 502, code: "COMMITTEE_UNAVAILABLE",
                                          message: "The committee could not finish. Try again or ask one research question.")
    }

}

private struct PrivateSavedReportView: View {
    let item: PrivateSavedItem
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var report: PrivateResearchReport?
    @State private var error: String?

    var body: some View {
        Group {
            if let report { PrivateReportView(report: report) }
            else if let error { ContentUnavailableView("Report unavailable", systemImage: "exclamationmark.circle", description: Text(error)) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        SkeletonBlock(width: 180, height: 28)
                        ForEach(0..<3) { _ in SkeletonBlock(height: 12) }
                    }
                    .padding(DS.Space.gutter)
                    .privateLoadingLabel("Opening report")
                }
            }
        }
        .task {
            guard let owner = auth.userId else { return }
            do {
                let response: PrivateResearchReport = try await PrivateMarketsAPI.request(
                    "report", ["id": item.id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                if auth.userId == owner { report = response }
            } catch is CancellationError {
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct PrivateReportView: View {
    let report: PrivateResearchReport
    var body: some View {
        List {
            Section("Question") {
                Text(report.question)
                Text("AI-generated research · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let committee = report.committee { section(committee) }
            ForEach(report.findings) { section($0) }
            Section("Sources") {
                ForEach(report.sources) { source in
                    if let url = source.url, url.privateSourceIsSafe { Link(source.title, destination: url) }
                    else { Text(source.title) }
                }
                Text(report.models.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(report.committee == nil ? "Research Answer" : "Investment Committee")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ finding: PrivateResearchReport.Finding) -> some View {
        Section(finding.title) {
            Text(finding.analysis)
            LabeledContent("Evidence confidence", value: finding.confidence.capitalized)
            if let bull = finding.bull { LabeledContent("Bull assumption", value: bull) }
            if let base = finding.base { LabeledContent("Base assumption", value: base) }
            if let bear = finding.bear { LabeledContent("Bear assumption", value: bear) }
            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, citation in
                let source = report.sources.first { $0.id == citation.source }
                VStack(alignment: .leading, spacing: 4) {
                    Text(source?.title ?? citation.source).font(.caption.weight(.semibold))
                    Text(citation.quote).font(.subheadline)
                }
            }
            ForEach(Array(finding.missing.enumerated()), id: \.offset) { _, missing in
                Label(missing, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            ForEach(Array(finding.questions.enumerated()), id: \.offset) { _, question in
                Label(question, systemImage: "questionmark.bubble")
            }
        }
    }
}

private struct PrivateScenarioCalculator: View {
    @State private var investment = ""
    @State private var postMoney = ""
    @State private var nextRaise = ""
    @State private var nextPost = ""
    @State private var bear = ""
    @State private var base = ""
    @State private var bull = ""

    private var startingOwnership: Decimal? {
        guard let amount = PrivateInput.amount(investment), let post = PrivateInput.amount(postMoney) else { return nil }
        return PrivateMath.ownership(investment: amount, postMoney: post, nextRoundPostMoney: nil, nextRoundRaise: nil)
    }

    private var finalOwnership: Decimal? {
        if nextRaise.isEmpty && nextPost.isEmpty { return startingOwnership }
        guard let amount = PrivateInput.amount(investment), let post = PrivateInput.amount(postMoney),
              let raise = PrivateInput.amount(nextRaise), let next = PrivateInput.amount(nextPost) else { return nil }
        return PrivateMath.ownership(investment: amount, postMoney: post, nextRoundPostMoney: next, nextRoundRaise: raise)
    }

    var body: some View {
        Form {
            Section("Initial investment") {
                input("Investment amount", $investment)
                input("Post-money valuation", $postMoney)
                LabeledContent("Initial ownership", value: percent(startingOwnership))
            }
            Section("Next round") {
                input("New capital raised", $nextRaise)
                input("Next post-money valuation", $nextPost)
                LabeledContent("Ownership after round", value: percent(finalOwnership))
            }
            Section("Assumed exit equity values") {
                scenario("Bear", $bear)
                scenario("Base", $base)
                scenario("Bull", $bull)
            }
            Section {
                Text("Use one currency throughout. Proceeds assume pro rata ownership with no fees, taxes, preferences, option changes or further dilution.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Scenario Calculator")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func input(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.decimalPad)
    }

    private func scenario(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            input(title + " exit value", value)
            if let share = finalOwnership, let exit = PrivateInput.amount(value.wrappedValue),
               let amount = PrivateInput.amount(investment), amount > 0 {
                let proceeds = share * exit
                Text("Proceeds \(proceeds.formatted(.number.precision(.fractionLength(2)))) · \((proceeds / amount).formatted(.number.precision(.fractionLength(2))))×")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Decimal?) -> String {
        value?.formatted(.percent.precision(.fractionLength(2...4))) ?? "Unavailable"
    }
}

struct PrivateDealRoom: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var items: [PrivateSavedItem] = []
    @State private var loading = false
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Your authorized excerpts") {
                if auth.userId == nil {
                    Text("Sign in from Account to store private research excerpts.")
                } else {
                    if loading {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in SearchRowSkeleton() }
                        }
                        .privateLoadingLabel("Loading documents")
                    }
                    if items.isEmpty && !loading { Text("No excerpts saved").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        NavigationLink {
                            PrivateExcerptView(item: item)
                        } label: {
                            LabeledContent(item.title, value: item.createdAt.formatted(date: .abbreviated, time: .omitted))
                        }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    guard let owner = auth.userId else { return }
                                    Task {
                                        do {
                                            try await PrivateMarketsAPI.send("delete_document", ["id": item.id.uuidString], expectedUserID: owner)
                                            guard auth.userId == owner else { return }
                                            items.removeAll { $0.id == item.id }
                                            try store.removeOwnershipEvidence(item.id, owner: owner)
                                        } catch is CancellationError {
                                        } catch { self.error = error.localizedDescription }
                                    }
                                }
                            }
                    }
                    Button("Add research excerpt") { adding = true }
                }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
            Section("Provider deal rooms") {
                ForEach(PrivateProvider.directory) { provider in
                    Link(provider.name, destination: provider.url)
                }
                Text("Provider accounts and invitations control access to their documents.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Deal Room")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) { PrivateExcerptEditor() }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let owner = auth.userId else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            try Task.checkCancellation()
            guard auth.userId == owner else { return }
            items = response.items
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrivateExcerptView: View {
    let item: PrivateSavedItem
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var excerpt: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let excerpt {
                ScrollView {
                    Text(excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else if let error {
                ContentUnavailableView("Excerpt unavailable", systemImage: "doc.text", description: Text(error))
            } else {
                ProgressView("Opening excerpt")
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let owner = auth.userId else { return }
            struct Response: Decodable { let excerpt: String }
            do {
                let response: Response = try await PrivateMarketsAPI.request("document", ["id": item.id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                guard auth.userId == owner else { return }
                excerpt = response.excerpt
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct PrivateOwnershipEvidenceView: View {
    let holding: PrivateHolding
    let owner: UUID
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var items: [PrivateSavedItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let current = store.state.holdings.first(where: { $0.id == holding.id }), let id = current.ownershipEvidenceID {
                Section("Linked evidence") {
                    NavigationLink("Open ownership excerpt") {
                        review(id: id, title: "Ownership excerpt", reviewed: current.ownershipReviewedOn)
                    }
                    Button("Unlink excerpt", role: .destructive) { update(nil) }
                }
            }
            Section("Choose an excerpt") {
                if loading { ProgressView("Loading your Deal Room") }
                else if items.isEmpty { Text("Add an authorized ownership excerpt in Deal Room first.") }
                ForEach(items) { item in
                    NavigationLink(item.title) { review(id: item.id, title: item.title, reviewed: nil) }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Ownership Evidence")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func review(id: UUID, title: String, reviewed: Date?) -> some View {
        PrivateOwnershipReviewView(id: id, title: title, owner: owner, reviewed: reviewed) {
            try store.updateOwnershipEvidence(for: holding.id, owner: owner, documentID: id)
        }
    }

    private func update(_ documentID: UUID?) {
        do { try store.updateOwnershipEvidence(for: holding.id, owner: owner, documentID: documentID) }
        catch { self.error = error.localizedDescription }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            try Task.checkCancellation()
            if auth.userId == owner { items = response.items }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrivateOwnershipReviewView: View {
    let id: UUID
    let title: String
    let owner: UUID
    let reviewed: Date?
    let attach: () throws -> Void
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var excerpt: String?
    @State private var acknowledged = false
    @State private var error: String?

    var body: some View {
        List {
            if let excerpt {
                Section("Excerpt") { Text(excerpt).textSelection(.enabled) }
                Section("Review") {
                    if let reviewed {
                        LabeledContent("Reviewed by you", value: reviewed.formatted(date: .abbreviated, time: .omitted))
                    }
                    Toggle("I checked the excerpt against this holding", isOn: $acknowledged)
                    Text("Your review records supporting evidence for a self-reported holding.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save evidence review") {
                        do { try attach(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(!acknowledged)
                }
            } else if error == nil {
                ProgressView("Opening excerpt")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            struct Document: Decodable { let excerpt: String }
            do {
                let response: Document = try await PrivateMarketsAPI.request("document", ["id": id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                if auth.userId == owner { excerpt = response.excerpt }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PrivateExcerptEditor: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var excerpt = ""
    @State private var authorized = false
    @State private var importing = false
    @State private var extraction: Task<Void, Never>?
    @State private var usedOCR = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Document and page or section", text: $title)
                TextField("Text excerpt", text: $excerpt, axis: .vertical).lineLimit(6...12)
                Text("\(excerpt.utf16.count) / 4,500 characters").font(.footnote).foregroundStyle(.secondary)
                Button("Extract text from PDF or text file") { importing = true }.disabled(extraction != nil || saving)
                if extraction != nil { ProgressView("Extracting text on this device") }
                if usedOCR {
                    Text("Review the recognized text against the scan before saving, especially dates and amounts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("I have permission to store this excerpt", isOn: $authorized)
                Text("Only the selected text is saved. Remove personal identifiers and confidential material outside your permission.")
                    .font(.footnote).foregroundStyle(.secondary)
                if saving { ProgressView("Encrypting and saving") }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
            .navigationTitle("Research Excerpt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!authorized || saving || extraction != nil || !(40...4_500).contains(excerpt.utf16.count) ||
                                  title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf16.count > 160)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText]) { result in
                extraction = Task {
                    defer { extraction = nil }
                    await readFile(result)
                }
            }
            .onDisappear { extraction?.cancel() }
        }
    }

    private func readFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let worker = Task.detached(priority: .userInitiated) { try PrivateExcerptImport.read(url) }
            let imported = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            if title.isEmpty { title = String(imported.name.prefix(160)) }
            excerpt = imported.text
            usedOCR = imported.usedOCR
            authorized = false
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = "No readable text was extracted. Use an unlocked PDF or UTF-8 file under 10 MB, or paste an excerpt."
        }
    }

    private func save() {
        guard let owner = auth.userId else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await PrivateMarketsAPI.send("save_document", ["title": title, "excerpt": excerpt, "authorized": authorized],
                                                 expectedUserID: owner)
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum PrivateExcerptImport {
    nonisolated static func read(_ url: URL) throws -> (name: String, text: String, usedOCR: Bool) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        let name = url.deletingPathExtension().lastPathComponent
        var text = ""
        var usedOCR = false
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw CocoaError(.fileReadNoPermission) }
            var scansAttempted = 0
            for index in 0..<min(pdf.pageCount, 50) {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { continue }
                var extracted = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if extracted.isEmpty, scansAttempted < 8, let reference = page.pageRef {
                    scansAttempted += 1
                    extracted = (try? recognize(reference)) ?? ""
                    usedOCR = usedOCR || !extracted.isEmpty
                }
                if !extracted.isEmpty {
                    if !text.isEmpty { text += "\n\n" }
                    text += "[Page \(index + 1)]\n" + extracted
                }
                if text.utf16.count >= 4_500 { break }
            }
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return (name, String(decoding: text.utf16.prefix(4_500), as: UTF16.self), usedOCR)
    }

    nonisolated private static func recognize(_ page: CGPDFPage) throws -> String {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return "" }
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = 2_400 / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(rect)
        canvas.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(page)
        guard let image = canvas.makeImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
