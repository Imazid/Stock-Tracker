import SwiftUI
import TradingCore

struct StrategyRuleEditor: View {
    let title: LocalizedStringKey
    let timeframe: Timeframe
    let onSave: (Condition?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rule: Condition?
    @FocusState private var editingNumber: Bool

    init(title: LocalizedStringKey, rule: Condition?, timeframe: Timeframe, onSave: @escaping (Condition?) -> Void) {
        self.title = title
        self.timeframe = timeframe
        self.onSave = onSave
        _rule = State(initialValue: rule)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let rule = Binding($rule) {
                    RuleFields(rule: rule, timeframe: timeframe, depth: 0, editingNumber: $editingNumber)
                    Section {
                        Button("Remove condition", role: .destructive) { self.rule = nil }
                    }
                } else {
                    Section {
                        Button("Add comparison", systemImage: "plus") { rule = RuleFields.defaultRule }
                        Button("Add rule group", systemImage: "square.stack") { rule = .all([RuleFields.defaultRule]) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        editingNumber = false
                        onSave(rule)
                        dismiss()
                    }
                    .accessibilityIdentifier("strategy.rule.apply")
                }
            }
        }
    }
}

private struct RuleFields: View {
    @Binding var rule: Condition
    let timeframe: Timeframe
    let depth: Int
    let editingNumber: FocusState<Bool>.Binding

    static let defaultRule = Condition.above(.close, .sma(50))

    private var children: Binding<[Condition]> {
        Binding(get: { rule.conditions ?? [] }, set: { rule.conditions = $0 })
    }

    var body: some View {
        Section("Condition") {
            Text(rule.isGroup && children.wrappedValue.isEmpty ? "Add a comparison to this group." : rule.label(timeframe))
                .accessibilityIdentifier("strategy.rule.preview")
        }

        if rule.isGroup {
            Section {
                Picker("Match", selection: $rule.op) {
                    Text("All rules").tag(ConditionOp.all)
                    Text("Any rule").tag(ConditionOp.any)
                }
                ForEach(children.indices, id: \.self) { index in
                    NavigationLink {
                        Form {
                            RuleFields(rule: children[index], timeframe: timeframe, depth: depth + 1, editingNumber: editingNumber)
                        }
                        .navigationTitle("Rule \(index + 1)")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        let child = children.wrappedValue[index]
                        Text(child.isGroup && (child.conditions ?? []).isEmpty ? "Empty group" : child.label(timeframe))
                    }
                }
                .onDelete { children.wrappedValue.remove(atOffsets: $0) }
                if children.wrappedValue.count < 8, depth < 4 {
                    Button("Add comparison", systemImage: "plus") { children.wrappedValue.append(Self.defaultRule) }
                    if depth < 3 {
                        Button("Add nested group", systemImage: "square.stack") {
                            children.wrappedValue.append(.all([Self.defaultRule]))
                        }
                    }
                }
            } header: {
                Text("Rules in this group")
            } footer: {
                Text("Swipe a rule left to remove it.")
            }
        } else {
            OperandFields(title: "First value", id: "left", value: operand(\.left, default: .close), editingNumber: editingNumber)
            Section {
                Picker("Comparison", selection: $rule.op) {
                    Text("Is above").tag(ConditionOp.above)
                    Text("Is below").tag(ConditionOp.below)
                    Text("Crosses above").tag(ConditionOp.crossesAbove)
                    Text("Crosses below").tag(ConditionOp.crossesBelow)
                }
                .accessibilityIdentifier("strategy.rule.comparison")
                if depth < 4 {
                    Button("Add a second comparison", systemImage: "square.stack") {
                        rule = .all([rule, Self.defaultRule])
                    }
                }
            }
            OperandFields(title: "Second value", id: "right", value: operand(\.right, default: .sma(50)), editingNumber: editingNumber)
        }
    }

    private func operand(_ path: WritableKeyPath<Condition, Operand?>, default defaultValue: Operand) -> Binding<Operand> {
        Binding(get: { rule[keyPath: path] ?? defaultValue }, set: { rule[keyPath: path] = $0 })
    }
}

private struct OperandFields: View {
    let title: LocalizedStringKey
    let id: String
    @Binding var value: Operand
    let editingNumber: FocusState<Bool>.Binding

    var body: some View {
        Section(title) {
            Picker("Indicator", selection: Binding(get: { value.kind }, set: { kind in
                let factor = value.factor
                value = Self.initialValue(for: kind)
                value.factor = factor
            })) {
                ForEach(OperandKind.allCases, id: \.self) { kind in
                    Text(Self.title(for: kind)).tag(kind)
                }
            }
            .accessibilityIdentifier("strategy.rule.\(id).kind")

            switch value.kind {
            case .price:
                Picker("Price", selection: Binding(get: { value.field ?? .close }, set: { value.field = $0 })) {
                    ForEach(PriceField.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            case .volume:
                EmptyView()
            case .constant:
                decimal("Number", field: "number", value: $value.value, keyboard: .numbersAndPunctuation)
            case .macdLine, .macdSignal, .macdHistogram:
                period("Fast period", field: "fast", value: $value.fast)
                period("Slow period", field: "slow", value: $value.slow)
                period("Signal period", field: "signal", value: $value.signal)
            case .bollingerUpper, .bollingerLower:
                period("Period in bars", field: "period", value: $value.period)
                decimal("Standard deviations", field: "deviations", value: $value.deviations)
            case .volumeAverage, .sma, .ema, .rsi, .bollingerMiddle, .atr, .highest, .lowest, .rateOfChange:
                period("Period in bars", field: "period", value: $value.period)
            }
            decimal("Multiplier", field: "factor", value: $value.factor, prompt: "1")
        }
    }

    private func period(_ title: LocalizedStringKey, field: String, value: Binding<Int?>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: value, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused(editingNumber)
                    .accessibilityIdentifier("strategy.rule.\(id).\(field)")
                if value.wrappedValue != nil {
                    Button {
                        editingNumber.wrappedValue = false
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear period")
                    .accessibilityIdentifier("strategy.rule.\(id).\(field).clear")
                }
            }
        }
    }

    private func decimal(_ title: LocalizedStringKey, field: String, value: Binding<Double?>,
                         prompt: String? = nil, keyboard: UIKeyboardType = .decimalPad) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.grouping(.never), prompt: prompt.map { Text($0) })
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .focused(editingNumber)
                .accessibilityIdentifier("strategy.rule.\(id).\(field)")
        }
    }

    private static func title(for kind: OperandKind) -> LocalizedStringKey {
        switch kind {
        case .price: "Price"
        case .volume: "Volume"
        case .volumeAverage: "Average volume"
        case .sma: "Simple moving average"
        case .ema: "Exponential moving average"
        case .rsi: "RSI"
        case .macdLine: "MACD line"
        case .macdSignal: "MACD signal"
        case .macdHistogram: "MACD histogram"
        case .bollingerUpper: "Upper Bollinger band"
        case .bollingerMiddle: "Middle Bollinger band"
        case .bollingerLower: "Lower Bollinger band"
        case .atr: "Average true range"
        case .highest: "Prior high"
        case .lowest: "Prior low"
        case .rateOfChange: "Rate of change (%)"
        case .constant: "Fixed number"
        }
    }

    private static func initialValue(for kind: OperandKind) -> Operand {
        switch kind {
        case .price: .close
        case .volume: .volume
        case .volumeAverage: .volumeAverage(20)
        case .sma: .sma(20)
        case .ema: .ema(20)
        case .rsi: .rsi()
        case .macdLine: .macdLine()
        case .macdSignal: .macdSignal()
        case .macdHistogram: .macdHistogram()
        case .bollingerUpper: .bollingerUpper()
        case .bollingerMiddle: .bollingerMiddle()
        case .bollingerLower: .bollingerLower()
        case .atr: .atr()
        case .highest: .highest(20)
        case .lowest: .lowest(20)
        case .rateOfChange: .rateOfChange(10)
        case .constant: .constant(50)
        }
    }
}
