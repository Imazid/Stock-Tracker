import SwiftUI

struct AngelListView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var link = AngelListLink()
    @State private var connected = false
    @State private var busy = false
    @State private var tools: [AngelListLink.Tool] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Connect through AngelList to read the fund records your account can access. Access is stored in this device’s Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
                if auth.userId == nil {
                    Text("Sign in to Stock Tracker first.")
                } else if connected {
                    Button("Refresh available records") { refresh() }.disabled(busy)
                    Button("Disconnect AngelList", role: .destructive) { disconnect() }.disabled(busy)
                } else {
                    Button("Connect AngelList") { connect() }.disabled(busy)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            if connected {
                Section("Authorized fund records") {
                    if tools.isEmpty && !busy { Text("AngelList has no compatible records available for this connection.") }
                    ForEach(tools) { tool in
                        if let owner = auth.userId {
                            NavigationLink(tool.title) { AngelListRecordView(link: link, tool: tool, owner: owner) }
                        }
                    }
                }
            }
        }
        .navigationTitle("AngelList Link")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) {
            tools = []
            connected = auth.userId.map(link.isConnected) ?? false
            if connected { refresh() }
        }
    }

    private func connect() {
        perform { owner in
            try await link.connect(owner) { auth.userId == owner }
            guard auth.userId == owner else { return }
            connected = true
            tools = try await link.tools(owner)
        }
    }

    private func refresh() {
        perform { owner in
            let available = try await link.tools(owner)
            guard auth.userId == owner else { return }
            tools = available
        }
    }

    private func disconnect() {
        perform { owner in
            try await link.disconnect(owner)
            guard auth.userId == owner else { return }
            connected = false
            tools = []
        }
    }

    private func perform(_ operation: @escaping (UUID) async throws -> Void) {
        guard let owner = auth.userId, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await operation(owner) }
            catch { if auth.userId == owner { self.error = error.localizedDescription } }
        }
    }
}

private struct AngelListRecordView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    let link: AngelListLink
    let tool: AngelListLink.Tool
    let owner: UUID
    @State private var fields: [String: String] = [:]
    @State private var result: String?
    @State private var fetchedAt: Date?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            if !tool.description.isEmpty {
                Text(tool.description).font(.footnote).foregroundStyle(.secondary)
            }
            if !tool.fields.isEmpty {
                Section("Record filters") {
                    ForEach(tool.fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(field.title + (field.required ? " (required)" : ""),
                                      text: Binding(get: { fields[field.id, default: ""] }, set: { fields[field.id] = $0 }))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            if let detail = field.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                Button("Read records", action: load).disabled(busy || auth.userId != owner)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            if let result, let fetchedAt, auth.userId == owner {
                Section("AngelList records") {
                    Text("Retrieved \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(result).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() {
        busy = true
        result = nil
        error = nil
        Task {
            defer { busy = false }
            do {
                let text = try await link.call(tool, arguments: fields, owner: owner)
                guard auth.userId == owner else { return }
                result = text
                fetchedAt = .now
            } catch {
                if auth.userId == owner { self.error = error.localizedDescription }
            }
        }
    }
}
