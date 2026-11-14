import Auth
import Supabase
import SwiftUI

struct AccountPracticeLimitsView: View {
    let owner: UUID
    var onSaved: () async -> Void = {}

    @Environment(\.theme) private var theme
    @State private var limits: Limits?
    @State private var exposure = ""
    @State private var dailyBuys = ""
    @State private var code = ""
    @State private var stepUp = false
    @State private var error: String?
    @State private var saved = false
    @State private var busy = false
    @FocusState private var editing: String?

    private struct Limits: Decodable {
        let maxSymbolExposurePct: Double
        let maxTotalDailyNotional: Double
    }
    private struct Reply: Decodable {
        struct Body: Decodable { let limits: Limits }
        let data: Body
    }

    var body: some View {
        TradingSection(title: "Account practice limits") {
            Text("Limits apply when agents buy. The daily limit counts filled buys and sells across practice portfolios in the same currency. Manual buys show a concentration warning.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            if limits != nil {
                limitField("Maximum exposure to one asset (%)", value: $exposure, id: "practiceLimits.exposure")
                limitField("Daily agent buy limit per currency", value: $dailyBuys, id: "practiceLimits.dailyBuys")
                if stepUp {
                    Text("Verify with your authenticator")
                        .font(.subheadline.weight(.semibold))
                    SecureField("Six-digit code", text: $code)
                        .focused($editing, equals: "code")
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("practiceLimits.code")
                    Button("Back to limits") { stepUp = false; code = ""; error = nil }
                }
                Button(busy ? "Saving…" : stepUp ? "Verify and save limits" : "Save limits") {
                    editing = nil
                    Task { await save() }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(busy || (stepUp && !validCode) || !hasEdits)
                .accessibilityIdentifier("practiceLimits.save")
            } else if error == nil {
                ProgressView("Loading account limits")
            } else {
                Button("Retry") { Task { await load() } }.disabled(busy)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(theme.negativeColor) }
            if saved && !hasEdits {
                Text("Account practice limits saved.")
                    .font(.footnote)
                    .accessibilityIdentifier("practiceLimits.saved")
            }
        }
        .task { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = nil }
                    .accessibilityIdentifier("practiceLimits.keyboardDone")
            }
        }
    }

    private func limitField(_ title: String, value: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(title, text: value)
                .focused($editing, equals: id)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
                .disabled(busy)
        }
    }

    private var validCode: Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private var enteredExposure: Double? { numericValue(exposure) }
    private var enteredDailyBuys: Double? { numericValue(dailyBuys) }

    private var hasEdits: Bool {
        guard let limits else { return false }
        return enteredExposure != limits.maxSymbolExposurePct || enteredDailyBuys != limits.maxTotalDailyNotional
    }

    private func numericValue(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
    }

    private func editableNumber(_ value: Double) -> String {
        let text = String(value)
        let withoutTrailingZero = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        return withoutTrailingZero.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }

    private func call(_ body: [String: Any]) async throws -> Limits {
        let data = try await SecureBackend.invoke("trading-api", body: body, expectedUserID: owner)
        try Task.checkCancellation()
        guard SupabaseManager.auth.currentUser?.id == owner else { throw CancellationError() }
        return try JSONDecoder().decode(Reply.self, from: data).data.limits
    }

    private func show(_ selection: Limits) {
        limits = selection
        exposure = editableNumber(selection.maxSymbolExposurePct)
        dailyBuys = editableNumber(selection.maxTotalDailyNotional)
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { show(try await call(["action": "accountLimits"])) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard !busy, hasEdits, let limits else { return }
        saved = false
        guard let exposureValue = enteredExposure, exposureValue > 0, exposureValue <= 100 else {
            error = "Single-asset exposure must be greater than 0% and at most 100%."
            return
        }
        guard let dailyBuysValue = enteredDailyBuys, dailyBuysValue.isFinite, dailyBuysValue > 0 else {
            error = "The daily agent buy limit must be greater than zero."
            return
        }
        var requested: [String: Double] = [:]
        if limits.maxSymbolExposurePct != exposureValue { requested["maxSymbolExposurePct"] = exposureValue }
        if limits.maxTotalDailyNotional != dailyBuysValue { requested["maxTotalDailyNotional"] = dailyBuysValue }
        busy = true
        error = nil
        defer { busy = false; code = "" }
        do {
            if stepUp {
                guard validCode, SupabaseManager.auth.currentUser?.id == owner else { return }
                let factors = try await SupabaseManager.auth.mfa.listFactors()
                guard SupabaseManager.auth.currentUser?.id == owner else { throw CancellationError() }
                guard let factor = factors.totp.first(where: { $0.status == .verified }) else {
                    error = "Set up an authenticator in Account settings, then return to these limits."
                    return
                }
                try await SupabaseManager.auth.mfa.challengeAndVerify(
                    params: MFAChallengeAndVerifyParams(factorId: factor.id, code: code))
            }
            let updated = try await call(["action": "updateAccountLimits", "limits": requested])
            show(updated)
            await onSaved()
            saved = true
            stepUp = false
        } catch is CancellationError {
        } catch {
            if let refusal = error as? SecureBackend.FunctionError, refusal.code == "step_up_required" { stepUp = true }
            self.error = error.localizedDescription
        }
    }
}

struct AccountPracticeLimitsScreen: View {
    let owner: UUID
    @EnvironmentObject private var trading: TradingStore

    var body: some View {
        ScrollView {
            AccountPracticeLimitsView(owner: owner, onSaved: {
                if SupabaseManager.auth.currentUser?.id == owner { await trading.syncFromAccount() }
            })
            .id(owner)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .dsScreenBackground()
        .navigationTitle("Practice limits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
