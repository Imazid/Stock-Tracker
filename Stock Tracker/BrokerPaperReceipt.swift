import Auth
import SwiftUI
import Supabase

struct BrokerPaperReceipt: View {
    let api: BrokerPaperAPI
    let id: String
    let account: String?
    let gate: BrokerPaperGate

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @State private var intent: BrokerPaperIntent?
    @State private var busy = false
    @State private var problem: String?
    @State private var requiresMFA = false
    @State private var verificationCode = ""
    @State private var keys: [BrokerPaperAPI.Action: String] = [:]
    @State private var confirmCancel = false
    @State private var executions: [BrokerExecutionPage.Execution] = []
    @State private var nextExecutionPage: BrokerExecutionPage.Cursor?
    @State private var executionsLoading = false
    @State private var executionsError = false

    init(api: BrokerPaperAPI, id: String, initial: BrokerPaperIntent?, account: String?, gate: BrokerPaperGate) {
        self.api = api
        self.id = id
        self.account = account
        self.gate = gate
        _intent = State(initialValue: initial)
    }

    var body: some View {
        BrokerPaperScroll {
            if let intent {
                TradingSection(title: "Alpaca paper order") {
                    TradingRow(label: "Order", value: intent.title, emphasised: true)
                    TradingRow(label: "Status", value: intent.statusLabel)
                        .accessibilityIdentifier("brokerPaper.orderStatus")
                    TradingRow(label: "Account", value: account ?? "Alpaca Paper")
                    TradingRow(label: "Order type", value: BrokerPaperTicket.orderType(intent.type))
                    TradingRow(label: "Time in force", value: BrokerPaperTicket.duration(intent.timeInForce))
                    if let quantity = intent.quantity { TradingRow(label: "Quantity", value: quantity) }
                    if let amount = intent.notional { TradingRow(label: "Amount", value: "\(amount) \(intent.estimate.currency)") }
                    if let limit = intent.limitPrice { TradingRow(label: "Limit price", value: "\(limit) \(intent.estimate.currency)") }
                    if let stop = intent.stopPrice { TradingRow(label: "Stop price", value: "\(stop) \(intent.estimate.currency)") }
                    TradingRow(label: "Estimated value", value: money(intent.estimate.notional, intent.estimate.currency))
                    TradingRow(label: "Estimated fees", value: money(intent.estimate.fee, intent.estimate.feeCurrency ?? intent.estimate.currency))
                        .accessibilityIdentifier("brokerPaper.fees")
                    if intent.side == "sell", intent.estimate.fee != nil {
                        Text("Fee estimates exclude regulatory pass-through fees on sells.")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                if let broker = intent.brokerOrder {
                    brokerReceipt(broker, intent: intent)
                    if hasExecuted(broker) { executionHistory(currency: intent.estimate.currency) }
                }
                if let problem { BrokerPaperMessage(text: problem, symbol: "exclamationmark.circle") }
                if let risk = intent.risk { riskReport(risk) }
                if requiresMFA { verification }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    actions(for: intent, now: context.date)
                }
                orderHistory(intent)
            } else if let problem {
                BrokerPaperMessage(text: problem, symbol: "exclamationmark.circle")
                Button("Retry") { Task { await refresh() } }
                    .buttonStyle(SecondaryPillButtonStyle())
            } else {
                ProgressView("Loading paper order")
            }
        }
        .navigationTitle(intent?.title ?? "Paper order")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
            await api.watchOrderUpdates {
                await refresh(automatically: true)
                if let broker = intent?.brokerOrder, hasExecuted(broker) { await loadExecutions() }
            }
        }
        .refreshable {
            await refresh()
            if let broker = intent?.brokerOrder, hasExecuted(broker) { await loadExecutions() }
        }
        .task(id: intent?.brokerOrder?.filledQuantity) {
            if let broker = intent?.brokerOrder, hasExecuted(broker) { await loadExecutions() }
        }
        .confirmationDialog("Request cancellation at Alpaca?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Request cancellation", role: .destructive) { Task { await act(.cancel) } }
        } message: {
            Text("Any fills that have already occurred stay in the paper account.")
        }
    }

    @ViewBuilder
    private func actions(for intent: BrokerPaperIntent, now: Date) -> some View {
        let draftExpired = now >= intent.expiresAt
        let approvalExpired = intent.approval.map { now >= $0.expiresAt && $0.consumedAt == nil } ?? false
        if intent.canReject || intent.canReconcile {
            TradingSection(title: "Order actions") {
                if !gate.enabled && intent.canReject {
                    Text(gate.reason).font(.subheadline).foregroundStyle(theme.secondaryText)
                } else if (draftExpired && intent.status != "approved") || approvalExpired {
                    Text("This review has expired. Return to the asset to prepare a new order.")
                        .font(.subheadline).foregroundStyle(theme.secondaryText)
                } else if intent.status == "draft" || intent.status == "risk_checked" {
                    actionButton("Run risk checks", .riskCheck)
                } else if intent.status == "awaiting_approval", intent.risk?.result == "pass" {
                    actionButton("Approve paper order", .approve)
                    Text("Approval authorises these exact order details. Submit it separately after approval.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                } else if intent.status == "approved", let approval = intent.approval, approval.consumedAt == nil {
                    actionButton("Submit to Alpaca Paper", .submit)
                    TradingRow(label: "Approval expires", value: approval.expiresAt.formatted(date: .omitted, time: .standard))
                }
                if intent.status == "reconciliation_required" {
                    Text("Alpaca has yet to confirm the outcome. Check with the broker before placing another order.")
                        .font(.subheadline).foregroundStyle(theme.secondaryText)
                }
                if intent.canReconcile {
                    Button("Check status with Alpaca") { Task { await act(.reconcile) } }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .accessibilityIdentifier("brokerPaper.reconcile")
                }
                if intent.canCancel {
                    Button("Request cancellation", role: .destructive) { confirmCancel = true }
                        .accessibilityIdentifier("brokerPaper.cancel")
                }
                if intent.canReject {
                    Button("Reject draft", role: .destructive) { Task { await act(.reject) } }
                        .accessibilityIdentifier("brokerPaper.reject")
                }
                if busy { ProgressView() }
            }
            .disabled(busy || requiresMFA)
        }
    }

    private func actionButton(_ title: String, _ action: BrokerPaperAPI.Action) -> some View {
        Button(title) { Task { await act(action) } }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityIdentifier("brokerPaper.\(action.rawValue)")
    }

    private func brokerReceipt(_ broker: BrokerPaperIntent.BrokerOrder, intent: BrokerPaperIntent) -> some View {
        TradingSection(title: "Confirmed by Alpaca") {
            TradingRow(label: "Broker status", value: BrokerPaperIntent.statusLabel(broker.status), emphasised: true)
                .accessibilityIdentifier("brokerPaper.brokerStatus")
            TradingRow(label: "Filled quantity", value: broker.filledQuantity)
            if let average = broker.averageFillPrice {
                TradingRow(label: "Average fill price", value: "\(average) \(intent.estimate.currency)")
            }
            if let submitted = broker.submittedAt {
                TradingRow(label: "Broker received", value: submitted.formatted(date: .abbreviated, time: .standard))
            }
            if let updated = broker.updatedAt {
                TradingRow(label: "Broker updated", value: updated.formatted(date: .abbreviated, time: .standard))
            }
            Text(broker.providerOrderID)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .accessibilityLabel("Alpaca order ID \(broker.providerOrderID)")
                .accessibilityIdentifier("brokerPaper.brokerID")
        }
    }

    private func hasExecuted(_ broker: BrokerPaperIntent.BrokerOrder) -> Bool {
        broker.filledQuantity.utf8.contains { (49...57).contains($0) }
    }

    private func executionHistory(currency: String) -> some View {
        TradingSection(title: "Broker executions") {
            if executions.isEmpty && !executionsError {
                Text(executionsLoading ? "Loading broker executions…" :
                    "Individual executions will appear after the broker fill history syncs.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            ForEach(executions) { fill in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(fill.quantity) units at \(fill.price) \(currency)")
                        .font(.subheadline.weight(.semibold))
                    if let at = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(fill.executedAt) {
                        Text(at.formatted(date: .abbreviated, time: .standard))
                    }
                    if let fee = fill.fee {
                        Text("Fee \(fee)\(fill.feeCurrency.map { " " + $0 } ?? "")")
                    } else {
                        Text("Fee unavailable")
                    }
                    Text(fill.providerFillID)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityLabel("Broker execution ID \(fill.providerFillID)")
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("brokerPaper.execution.\(fill.id)")
            }
            if executionsError {
                Text("Couldn’t load broker executions.").font(.caption)
                Button("Retry executions") { Task { await loadExecutions() } }
            }
            if let nextExecutionPage {
                Button("Load older executions") { Task { await loadExecutions(before: nextExecutionPage) } }
                    .disabled(executionsLoading)
            }
        }
    }

    private func loadExecutions(before: BrokerExecutionPage.Cursor? = nil) async {
        guard !executionsLoading else { return }
        executionsLoading = true
        defer { executionsLoading = false }
        do {
            let page = try await api.executions(for: id, before: before)
            try Task.checkCancellation()
            if before == nil, !executions.isEmpty {
                // Keep older pages visible when delayed executions are imported.
                let previous = Set(executions.map(\.id))
                if page.executions.contains(where: { previous.contains($0.id) }) {
                    executions += page.executions.filter { !previous.contains($0.id) }
                    executions.sort { ($0.executedAt, $0.id) > ($1.executedAt, $1.id) }
                } else {
                    executions = page.executions
                    nextExecutionPage = page.next
                }
            } else {
                let existing = Set(executions.map(\.id))
                executions.append(contentsOf: page.executions.filter { !existing.contains($0.id) })
                nextExecutionPage = page.next
            }
            executionsError = false
        } catch is CancellationError {
        } catch {
            executionsError = true
        }
    }

    private func riskReport(_ risk: BrokerPaperIntent.Risk) -> some View {
        TradingSection(title: "Risk checks", trailing: risk.result == "pass" ? "Passed" : "Failed") {
            if risk.price.source != "none" {
                TradingRow(label: "Price used", value: "\(risk.price.value) \(risk.price.currency)")
                Text("\(risk.price.source) · \(risk.price.status.replacingOccurrences(of: "_", with: " ")) · \(risk.price.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                Text("No eligible price was available.").font(.subheadline)
            }
            TradingRow(label: "Policy version", value: String(risk.policyVersion))
            TradingRow(label: "Evaluated", value: risk.evaluatedAt.formatted(date: .abbreviated, time: .standard))
            let notable = risk.checks.filter { $0.status == "failed" || $0.status == "warning" }
            ForEach(Array(notable.enumerated()), id: \.offset) { _, check in riskCheck(check) }
            DisclosureGroup("All risk checks") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(Array(risk.checks.enumerated()), id: \.offset) { _, check in riskCheck(check) }
                }
                .padding(.top, DS.Space.s)
            }
        }
        .accessibilityIdentifier("brokerPaper.risk")
    }

    private func riskCheck(_ check: BrokerPaperIntent.Risk.Check) -> some View {
        Label {
            Text("\(checkLabel(check.status)) · \(check.detail)")
        } icon: {
            Image(systemName: checkIcon(check.status))
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func orderHistory(_ intent: BrokerPaperIntent) -> some View {
        TradingSection(title: "Order history") {
            ForEach(Array(intent.transitions.enumerated()), id: \.offset) { _, transition in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    TradingRow(label: LocalizedStringKey(BrokerPaperIntent.statusLabel(transition.to)),
                               value: transition.at.formatted(date: .abbreviated, time: .standard))
                    if let note = transition.note {
                        Text(note).font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            Text("Reference \(intent.clientOrderID)")
                .font(.caption.monospaced()).foregroundStyle(theme.secondaryText).textSelection(.enabled)
        }
    }

    private var verification: some View {
        TradingSection(title: "Verify with your authenticator") {
            SecureField("Six-digit code", text: $verificationCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            Button("Verify") { Task { await verify() } }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(busy || verificationCode.utf8.count != 6 || !verificationCode.utf8.allSatisfy { (48...57).contains($0) })
            Button("Back to order") { requiresMFA = false; verificationCode = "" }
                .disabled(busy)
        }
    }

    private func money(_ amount: String?, _ currency: String) -> String {
        amount.map { "\($0) \(currency)" } ?? "Unavailable"
    }

    private func checkLabel(_ status: String) -> String {
        status == "notApplicable" ? "Not applicable" : status.capitalized
    }

    private func checkIcon(_ status: String) -> String {
        switch status {
        case "passed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        case "warning": return "exclamationmark.triangle"
        default: return "minus.circle"
        }
    }

    private func refresh(automatically: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            intent = try await api.order(id)
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            if !automatically || intent == nil { problem = error.localizedDescription }
        }
    }

    private func act(_ action: BrokerPaperAPI.Action) async {
        guard !busy, let intent else { return }
        busy = true
        defer { busy = false }
        problem = nil
        let key = keys[action] ?? UUID().uuidString
        keys[action] = key
        do {
            self.intent = try await api.act(action, on: intent, key: key)
            keys[action] = nil
        } catch is CancellationError {
            return
        } catch {
            guard SupabaseManager.auth.currentUser?.id == api.userID else { return }
            problem = error.localizedDescription
            if let refusal = error as? SecureBackend.FunctionError, refusal.code != "internal", refusal.status != 0 {
                keys[action] = nil
                requiresMFA = refusal.code == "step_up_required"
            }
            if let latest = try? await api.order(id) { self.intent = latest }
        }
    }

    private func verify() async {
        guard !busy, SupabaseManager.auth.currentUser?.id == api.userID else { return }
        busy = true
        defer { busy = false; verificationCode = "" }
        do {
            let factors = try await SupabaseManager.auth.mfa.listFactors()
            guard SupabaseManager.auth.currentUser?.id == api.userID else { return }
            guard let factor = factors.totp.first(where: { $0.status == .verified }) else {
                problem = "Set up an authenticator in Account settings, then return to this order."
                requiresMFA = false
                return
            }
            try await SupabaseManager.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factor.id, code: verificationCode)
            )
            guard SupabaseManager.auth.currentUser?.id == api.userID else { return }
            requiresMFA = false
            problem = nil
        } catch {
            problem = "Verification failed. Check the code and try again."
        }
    }
}
