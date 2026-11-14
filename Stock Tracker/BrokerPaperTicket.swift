import SwiftUI
import TradingCore

struct BrokerPaperTicket: View {
    let api: BrokerPaperAPI
    let asset: BrokerPaperAsset
    let accounts: [BrokerPaperConnection]
    let gate: BrokerPaperGate

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @FocusState private var focusedField: String?
    @State private var accountID = ""
    @State private var side: OrderSide = .buy
    @State private var type = "market"
    @State private var timeInForce = ""
    @State private var byAmount = false
    @State private var size = ""
    @State private var limit = ""
    @State private var stop = ""
    @State private var draftKey: String?
    @State private var intent: BrokerPaperIntent?
    @State private var problem: String?
    @State private var busy = false
    @State private var showReceipt = false

    private var account: BrokerPaperConnection? { accounts.first { $0.id == accountID } }
    private var capability: BrokerPaperConnection.OrderCapability? { account?.capability(for: asset) }
    private var orderTypes: [String] { capability?.orderTypes ?? [] }
    private var durations: [String] { capability?.timeInForce[type] ?? [] }
    private var needsLimit: Bool { type == "limit" || type == "stop_limit" }
    private var needsStop: Bool { type == "stop" || type == "stop_limit" }
    private var supportsAmount: Bool {
        capability?.notional == true && type == "market" && (asset.assetClass == "crypto" || timeInForce == "day")
    }
    private var cashAmount: Bool { supportsAmount && byAmount }

    var body: some View {
        BrokerPaperScroll {
            TradingSection(title: "Order details") {
                InstrumentLabel(instrument: asset.instrument, subtitle: "Alpaca paper order")
                Picker("Paper account", selection: $accountID) {
                    ForEach(accounts) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("brokerPaper.account")
                Picker("Side", selection: $side) {
                    Text("Buy").tag(OrderSide.buy)
                    Text("Sell").tag(OrderSide.sell)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("brokerPaper.side")
                Picker("Order type", selection: $type) {
                    ForEach(orderTypes, id: \.self) { Text(Self.orderType($0)).tag($0) }
                }
                .accessibilityIdentifier("brokerPaper.type")
                Picker("Time in force", selection: $timeInForce) {
                    ForEach(durations, id: \.self) { Text(Self.duration($0)).tag($0) }
                }
                .accessibilityIdentifier("brokerPaper.timeInForce")
                if supportsAmount {
                    Picker("Size in", selection: Binding(get: { byAmount }, set: { byAmount = $0; size = "" })) {
                        Text("Units").tag(false)
                        Text("USD").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                decimalField(cashAmount ? "Amount (USD)" : "Quantity", text: $size, identifier: "brokerPaper.size")
                if needsLimit { decimalField("Limit price (USD)", text: $limit, identifier: "brokerPaper.limit") }
                if needsStop { decimalField("Stop price (USD)", text: $stop, identifier: "brokerPaper.stop") }
                if let issue = sizeIssue {
                    Text(issue).font(.footnote).foregroundStyle(theme.negativeColor)
                }
            }
            .disabled(draftKey != nil || intent != nil)
            if let problem { BrokerPaperMessage(text: problem, symbol: "exclamationmark.circle") }
            Button {
                focusedField = nil
                if intent != nil { showReceipt = true } else { Task { await prepare() } }
            } label: {
                Text(busy ? "Preparing…" : intent != nil ? "Review order" : draftKey != nil ? "Retry order preparation" : "Prepare for review")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(busy || input == nil)
            .accessibilityIdentifier("brokerPaper.draft")
        }
        .navigationTitle("Prepare paper order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("brokerPaper.keyboardDone")
            }
        }
        .onAppear {
            if accountID.isEmpty, let first = accounts.first { accountID = first.id }
            selectSupportedOptions()
        }
        .onChange(of: accountID) { selectSupportedOptions() }
        .onChange(of: type) { selectSupportedOptions() }
        .onChange(of: supportsAmount) {
            if !supportsAmount && byAmount {
                byAmount = false
                size = ""
            }
        }
        .navigationDestination(isPresented: $showReceipt) {
            if let intent {
                BrokerPaperReceipt(api: api, id: intent.id, initial: intent, account: account?.label, gate: gate)
            }
        }
    }

    private func decimalField(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label).font(.subheadline)
            TextField(label, text: text, prompt: Text("0"))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: identifier)
                .accessibilityIdentifier(identifier)
        }
    }

    private var sizeIssue: String? {
        guard !cashAmount, let quantity = positiveDecimal(size), quantity.split(separator: ".").dropFirst().contains(where: { $0.contains { $0 != "0" } })
        else { return nil }
        if capability?.fractional == false { return "Use a whole quantity for this account." }
        if asset.assetClass == "us_equity", timeInForce != "day" { return "Fractional stock quantities require a day order." }
        return nil
    }

    private var input: [String: Any]? {
        guard let account, orderTypes.contains(type), durations.contains(timeInForce),
              let amount = positiveDecimal(size), sizeIssue == nil, !byAmount || supportsAmount else { return nil }
        var fields: [String: Any] = [
            "connectionID": account.id, "symbol": asset.symbol, "assetClass": asset.assetClass,
            "side": side.rawValue, "type": type, "timeInForce": timeInForce, "origin": ["kind": "manual"],
            cashAmount ? "notional" : "quantity": amount,
        ]
        if needsLimit {
            guard let value = positiveDecimal(limit) else { return nil }
            fields["limitPrice"] = value
        }
        if needsStop {
            guard let value = positiveDecimal(stop) else { return nil }
            fields["stopPrice"] = value
        }
        return fields
    }

    private func positiveDecimal(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = trimmed.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ part in part.utf8.allSatisfy { (48...57).contains($0) } }),
              decimal.utf8.contains(where: { (49...57).contains($0) }) else { return nil }
        let whole = parts[0].drop(while: { $0 == "0" })
        guard whole.count <= 20 else { return nil }
        let prefix = whole.isEmpty ? "0" : String(whole)
        if parts.count == 1 || parts[1].isEmpty { return prefix }
        guard parts[1].count <= 18 else { return nil }
        return "\(prefix).\(parts[1])"
    }

    private func selectSupportedOptions() {
        if !orderTypes.contains(type) { type = orderTypes.first ?? "" }
        if !durations.contains(timeInForce) { timeInForce = durations.first ?? "" }
    }

    private func prepare() async {
        guard !busy, let input else { return }
        let key = draftKey ?? UUID().uuidString
        draftKey = key
        busy = true
        defer { busy = false }
        problem = nil
        do {
            intent = try await api.draft(input, key: key)
            showReceipt = true
        } catch is CancellationError {
            return
        } catch let error as SecureBackend.FunctionError where (400..<500).contains(error.status) || error.code == "feature_disabled" {
            draftKey = nil
            problem = error.localizedDescription
        } catch {
            problem = "The server didn't confirm order preparation. Retry to recover the same draft."
        }
    }

    static func orderType(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func duration(_ value: String) -> String {
        switch value {
        case "day": return "Day"
        case "gtc": return "Good till cancelled"
        case "ioc": return "Immediate or cancel"
        case "fok": return "Fill or kill"
        default: return value.uppercased()
        }
    }
}
