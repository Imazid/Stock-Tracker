import SwiftUI
import TradingCore

struct CompanyQuestionView: View {
    let instrument: Instrument
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var question = ""
    @State private var consent = false
    @State private var submitted: String?
    @State private var reply: CompanyQuestionReply?
    @State private var problem: String?
    @FocusState private var editing: Bool

    private var trimmed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            if auth.userId == owner {
                Section {
                    TextField("Question about \(instrument.symbol)", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($editing)
                        .accessibilityIdentifier("companyQuestion.input")
                    Toggle("Send my question and public filing evidence to the AI provider", isOn: $consent)
                        .disabled(submitted != nil)
                        .accessibilityIdentifier("companyQuestion.consent")
                    Button {
                        editing = false
                        submitted = trimmed
                    } label: {
                        if submitted == nil { Label("Ask AI", systemImage: "sparkles") }
                        else { ProgressView("Reading filing evidence…") }
                    }
                    .disabled(!consent || trimmed.isEmpty || trimmed.utf16.count > 500 || submitted != nil)
                    .accessibilityIdentifier("companyQuestion.ask")
                } footer: {
                    Text(trimmed.utf16.count > 500 ? "Keep the question to 500 characters." :
                            "Company research only. Keep personal information out of your question.")
                }

                if let reply {
                    Section("AI answer") {
                        Text(reply.answer)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("companyQuestion.answer")
                    }
                    if !reply.citations.isEmpty {
                        Section("Filing sources") {
                            ForEach(reply.citations) { citation in
                                Link(destination: citation.url) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(citation.title)
                                        Text(citation.excerpt).font(.footnote).foregroundStyle(Color.secondary)
                                    }
                                }
                                .accessibilityIdentifier("companyQuestion.citation")
                            }
                        }
                    }
                    if !reply.missing.isEmpty {
                        Section("Evidence gaps") {
                            ForEach(Array(reply.missing.enumerated()), id: \.offset) { _, item in Text(item) }
                        }
                    }
                } else if let problem {
                    Section { Text(problem).accessibilityIdentifier("companyQuestion.error") }
                }
            } else {
                Text("Sign in to Stock Tracker to ask about this company.")
            }
        }
        .navigationTitle("Ask about \(instrument.symbol)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: submitted) {
            if let submitted { await ask(submitted) }
        }
        .onChange(of: auth.userId) { _, value in
            if value != owner {
                submitted = nil
                reply = nil
                question = ""
                consent = false
                problem = nil
            }
        }
    }

    private func ask(_ text: String) async {
        problem = nil
        reply = nil
        do {
            let data = try await SecureBackend.invoke("market-workspace", body: [
                "action": "companyQuestion", "instrumentId": instrument.id, "question": text, "consent": consent,
            ], expectedUserID: owner)
            let result = try JSONDecoder().decode(CompanyQuestionResponse.self, from: data).data
            guard result.instrumentId == instrument.id else { throw URLError(.badServerResponse) }
            if !Task.isCancelled, auth.userId == owner { reply = result }
        } catch {
            if !Task.isCancelled, auth.userId == owner {
                problem = (error as? SecureBackend.FunctionError)?.message ?? "The assistant couldn’t answer. Try again."
            }
        }
        if !Task.isCancelled, auth.userId == owner { submitted = nil }
    }
}

private struct CompanyQuestionResponse: Decodable {
    let data: CompanyQuestionReply
}

private struct CompanyQuestionReply: Decodable {
    struct Citation: Decodable, Identifiable {
        let id: String
        let title: String
        let url: URL
        let excerpt: String
    }

    let instrumentId: String
    let answer: String
    let citations: [Citation]
    let missing: [String]
}
