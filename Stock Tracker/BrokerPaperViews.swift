import SwiftUI
import TradingCore

struct BrokerPaperEntry: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    let asset: BrokerPaperAsset?
    @State private var presented = false

    var body: some View {
        if auth.authState == .signedIn, let owner = auth.userId {
            Button {
                presented = true
            } label: {
                Label(asset == nil ? "Alpaca paper orders" : "Trade with Alpaca Paper", systemImage: "building.columns")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(DS.accent)
            .accessibilityIdentifier(asset == nil ? "brokerPaper.activity" : "brokerPaper.trade")
            .sheet(isPresented: $presented) {
                BrokerPaperWorkspace(api: BrokerPaperAPI(userID: owner), asset: asset)
            }
            .onChange(of: auth.userId) { presented = false }
            .id(owner)
        }
    }
}

private struct BrokerPaperWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let api: BrokerPaperAPI
    let asset: BrokerPaperAsset?

    @State private var gate: BrokerPaperGate?
    @State private var connections: [BrokerPaperConnection] = []
    @State private var orders: [BrokerPaperIntent] = []
    @State private var selection: Destination?
    @State private var loading = true
    @State private var problem: String?

    private enum Destination: Hashable {
        case connect, ticket, order(String)
    }

    private var tradable: [BrokerPaperConnection] {
        guard let asset else { return [] }
        return connections.filter { $0.capability(for: asset) != nil }
    }

    var body: some View {
        NavigationStack {
            BrokerPaperScroll {
                Text("Orders use the simulated balance in your Alpaca paper account.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                if let gate, !gate.enabled {
                    BrokerPaperMessage(text: "Alpaca paper execution is disabled on this deployment.", symbol: "lock", identifier: "brokerPaper.gate")
                }
                if let problem {
                    BrokerPaperMessage(text: problem, symbol: "exclamationmark.circle")
                    Button("Retry") { Task { await reload() } }
                        .buttonStyle(SecondaryPillButtonStyle())
                } else if loading {
                    ProgressView("Loading Alpaca paper accounts")
                } else if let asset, gate?.enabled == true {
                    if tradable.isEmpty {
                        BrokerPaperMessage(text: "Connect an Alpaca paper account with trading permission to prepare an order.",
                                           symbol: "info.circle")
                    } else {
                        Button("Prepare an order for \(asset.instrument.symbol)") { selection = .ticket }
                            .buttonStyle(PrimaryPillButtonStyle())
                            .accessibilityIdentifier("brokerPaper.prepare")
                    }
                }
                accounts
                if asset == nil, !loading { history }
            }
            .navigationTitle("Alpaca Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationDestination(item: $selection) { destination in
                switch destination {
                case .connect:
                    BrokerPaperConnectView(api: api) { connection in
                        connections.insert(connection, at: 0)
                        selection = nil
                    }
                case .ticket:
                    if let asset {
                        BrokerPaperTicket(api: api, asset: asset, accounts: tradable, gate: gate ?? .unavailable)
                    }
                case .order(let id):
                    BrokerPaperReceipt(api: api, id: id, initial: orders.first { $0.id == id },
                                       account: accountName(for: id), gate: gate ?? .unavailable)
                }
            }
            .task(id: selection) {
                if selection == nil { await reload() }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active, asset == nil else { return }
                await api.watchOrderUpdates {
                    if selection == nil, !loading, let latest = try? await api.orders(), selection == nil {
                        orders = latest
                    }
                }
            }
            .refreshable { await reload() }
        }
    }

    private var accounts: some View {
        TradingSection(title: "Paper accounts") {
            if connections.isEmpty {
                if !loading { Text("No Alpaca paper accounts connected.").font(.subheadline) }
            } else {
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(connection.label).font(.subheadline.weight(.semibold))
                        Text(connection.status == "needs_attention" ? "Reconnect required"
                             : connection.permissions.contains("trade") ? "Trading permission" : "Read only")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        if connection.sync.state == "failed", let error = connection.sync.lastError {
                            Text(error).font(.caption).foregroundStyle(theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            Button("Connect Alpaca Paper") { selection = .connect }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityIdentifier("brokerPaper.connect")
                .disabled(loading || gate == nil)
        }
    }

    private var history: some View {
        TradingSection(title: "Paper order history") {
            if orders.isEmpty {
                Text("Orders you prepare for Alpaca appear here.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(orders) { order in
                Button {
                    selection = .order(order.id)
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(order.title).font(.subheadline.weight(.semibold))
                        Text("\(order.statusLabel) · \(TradingFormat.time(order.createdAt))")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("brokerPaper.history.\(order.id)")
            }
        }
    }

    private func accountName(for id: String) -> String? {
        guard let order = orders.first(where: { $0.id == id }) else { return nil }
        return connections.first { $0.id == order.connectionID }?.label
    }

    private func reload() async {
        defer { if !Task.isCancelled { loading = false } }
        do {
            async let availableGate = api.gate()
            async let availableConnections = api.connections()
            let (nextGate, nextConnections) = try await (availableGate, availableConnections)
            gate = nextGate
            connections = nextConnections
            if asset == nil { orders = try await api.orders() }
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct BrokerPaperConnectView: View {
    let api: BrokerPaperAPI
    let connected: (BrokerPaperConnection) -> Void

    @State private var label = ""
    @State private var keyID = ""
    @State private var secretKey = ""
    @State private var allowOrders = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        BrokerPaperScroll {
            TradingSection(title: "Paper API credentials") {
                Text("Use the API credentials from your Alpaca paper account.")
                    .font(.subheadline)
                TextField("Account name (optional)", text: $label)
                    .textContentType(.none)
                SecureField("Paper API key ID", text: $keyID)
                    .textContentType(.none)
                    .accessibilityIdentifier("brokerPaper.keyID")
                SecureField("Paper API secret key", text: $secretKey)
                    .textContentType(.none)
                    .accessibilityIdentifier("brokerPaper.secretKey")
                Toggle("Allow paper orders", isOn: $allowOrders)
                    .accessibilityIdentifier("brokerPaper.tradePermission")
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .disabled(busy)
            if let problem { BrokerPaperMessage(text: problem, symbol: "exclamationmark.circle") }
            Button(busy ? "Connecting…" : "Connect paper account") { Task { await connect() } }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(busy || keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("brokerPaper.saveConnection")
        }
        .navigationTitle("Connect Alpaca Paper")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        problem = nil
        do {
            let account = try await api.connect(label: label, keyID: keyID, secretKey: secretKey, allowOrders: allowOrders)
            keyID = ""
            secretKey = ""
            connected(account)
        } catch is CancellationError {
            return
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct BrokerPaperScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l, content: content)
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.l)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .dsScreenBackground()
    }
}

struct BrokerPaperMessage: View {
    let text: String
    let symbol: String
    var identifier = "brokerPaper.message"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(padding: DS.Space.m)
            .accessibilityIdentifier(identifier)
    }
}
