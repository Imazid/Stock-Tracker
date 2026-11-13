//
//  CSVImportSheet.swift
//  Stock Tracker
//
//  Bulk-add holdings from a spreadsheet (Black). Costs are read in each
//  holding's own trading currency (A$ for ASX tickers ending ".AX", US$
//  otherwise) and saved through MarketData.addHolding, which stores USD and
//  prices every new holding straight away.
//

import SwiftUI
import UniformTypeIdentifiers

struct CSVImportSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.theme) private var theme

    @State private var showFilePicker = false
    @State private var parsedRows: [CSVRow] = []
    @State private var parseError: String?
    @State private var importComplete = false
    @State private var selectedRows: Set<UUID> = []
    @State private var resultText = ""

    struct CSVRow: Identifiable {
        let id = UUID()
        let symbol: String
        let name: String
        let shares: Double
        let avgCost: Double
        let costKnown: Bool
        let isCrypto: Bool

        var isASX: Bool { !isCrypto && symbol.hasSuffix(".AX") }
        var displaySymbol: String { isASX ? String(symbol.dropLast(3)) : symbol }
        var currencySymbol: String { isASX ? "A$" : "US$" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if importComplete {
                        successView
                    } else if parsedRows.isEmpty {
                        formatGuide
                        if let parseError { errorLabel(parseError) }
                        Button("Choose a CSV file") { showFilePicker = true }
                            .buttonStyle(PrimaryPillButtonStyle())
                            .accessibilityIdentifier("csv.choose")
                    } else {
                        previewSection
                    }
                }
                .padding(DS.Space.gutter)
            }
            .dsScreenBackground()
            .safeAreaInset(edge: .bottom) {
                if !parsedRows.isEmpty && !importComplete {
                    Button("Import \(selectedRows.count) holding\(selectedRows.count == 1 ? "" : "s")", action: importSelected)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(selectedRows.isEmpty)
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.vertical, DS.Space.s)
                        .background(theme.background.opacity(0.96).ignoresSafeArea(edges: .bottom))
                        .accessibilityIdentifier("csv.import")
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importComplete ? "Done" : "Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText, .plainText],
                          allowsMultipleSelection: false) { handleFileImport($0) }
        }
    }

    // MARK: - Format guide

    private var formatGuide: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Add many holdings at once from a spreadsheet exported from your broker or a tracker.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            VStack(spacing: 0) {
                LedgerLine(label: "symbol", value: "Required — AAPL, BHP.AX, BTC")
                LedgerLine(label: "shares", value: "Required — quantity held")
                LedgerLine(label: "avg_cost", value: "Optional — per unit, in its own currency")
                LedgerLine(label: "name", value: "Optional")
                LedgerLine(label: "type", value: "Optional — stock or crypto")
            }
            .dsCard()
            Text("Example")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            Text("symbol,name,shares,avg_cost,type\nAAPL,Apple Inc.,10,150.00,stock\nBHP.AX,BHP Group,50,42.10,stock\nBTC,Bitcoin,0.5,42000,crypto")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.subtleFill))
                .textSelection(.enabled)
        }
    }

    private func errorLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.footnote.weight(.medium))
            .foregroundStyle(theme.negativeColor)
            .accessibilityIdentifier("csv.error")
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("\(parsedRows.count) rows found")
                    .font(.headline)
                Spacer()
                Button(selectedRows.count == parsedRows.count ? "Select none" : "Select all") {
                    selectedRows = selectedRows.count == parsedRows.count ? [] : Set(parsedRows.map(\.id))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DS.accent)
                .frame(minHeight: 44)
            }
            if let parseError { errorLabel(parseError) }
            VStack(spacing: 0) {
                ForEach(parsedRows) { row in
                    rowView(row)
                    if row.id != parsedRows.last?.id { Divider().overlay(theme.cardBorder.opacity(0.4)) }
                }
            }
            .dsCard(padding: DS.Space.m)
            Button("Choose a different file") {
                parsedRows = []; selectedRows = []; parseError = nil; showFilePicker = true
            }
            .buttonStyle(QuietTextButtonStyle())
        }
    }

    private func rowView(_ row: CSVRow) -> some View {
        let isOn = selectedRows.contains(row.id)
        return Button {
            if isOn { selectedRows.remove(row.id) } else { selectedRows.insert(row.id) }
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? DS.accent : theme.secondaryText.opacity(0.5))
                TickerLogo(symbol: row.displaySymbol, kind: row.isCrypto ? .crypto : .stock,
                           exchange: row.isASX ? "ASX" : "", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.displaySymbol).font(.subheadline.weight(.semibold))
                        MarketBadge(text: row.isCrypto ? "Crypto" : (row.isASX ? "ASX" : "US"))
                    }
                    if !row.name.isEmpty && row.name != row.symbol {
                        Text(row.name).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatQuantity(row.shares)).font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(row.avgCost > 0 ? "\(row.currencySymbol)\(row.avgCost.formatted(.number.precision(.fractionLength(2...6))))" : "No cost")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.vertical, DS.Space.s)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Done

    private var successView: some View {
        EmptyStateCard(systemImage: "checkmark", title: "Import finished", message: LocalizedStringKey(resultText),
                       primaryTitle: "Done", primaryAction: { dismiss() })
            .accessibilityIdentifier("csv.done")
    }

    // MARK: - File Handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        parseError = nil
        parsedRows = []

        switch result {
        case .failure(let error):
            parseError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                parseError = "Could not access the selected file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                parseCSV(content)
            } catch {
                parseError = "Could not read file: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sanitisation

    private static let maxFileSize = 1_000_000  // 1 MB
    private static let maxRows = 500
    private static let maxSymbolLength = 20
    private static let maxNameLength = 100
    private static let maxSharesValue: Double = 1_000_000_000
    private static let maxCostValue: Double = 10_000_000

    /// Strips control characters, null bytes, and trims whitespace.
    private func sanitise(_ raw: String, maxLength: Int) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\0", with: "")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == " " }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count > maxLength {
            return String(stripped.prefix(maxLength))
        }
        return stripped
    }

    /// Only allows alphanumeric, dot, hyphen, space for symbols.
    private func sanitiseSymbol(_ raw: String) -> String {
        let cleaned = sanitise(raw, maxLength: Self.maxSymbolLength).uppercased()
        return cleaned.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    /// Clamps a numeric value to a safe range.
    private func clampValue(_ value: Double, max ceiling: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), ceiling)
    }

    private func parseCSV(_ content: String) {
        guard content.utf8.count <= Self.maxFileSize else {
            parseError = "File too large (max 1 MB)"
            return
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count > 1 else {
            parseError = "CSV file appears empty or has no data rows"
            return
        }

        // Parse header to find column indices
        let header = lines[0].lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let symbolIdx = header.firstIndex(where: { $0.contains("symbol") || $0.contains("ticker") }) ?? 0
        let nameIdx = header.firstIndex(where: { $0.contains("name") || $0.contains("company") })
        let sharesIdx = header.firstIndex(where: { $0.contains("share") || $0.contains("quantity") || $0.contains("qty") || $0.contains("units") })
        let costIdx = header.firstIndex(where: { $0.contains("cost") || $0.contains("price") || $0.contains("avg") })
        let typeIdx = header.firstIndex(where: { $0.contains("type") || $0.contains("kind") || $0.contains("class") })

        var rows: [CSVRow] = []
        var warnings = 0
        let rowLimit = min(lines.count, Self.maxRows + 1)  // +1 for header

        for i in 1..<rowLimit {
            let cols = parseCSVLine(lines[i])
            guard cols.count > symbolIdx else { continue }

            let symbol = sanitiseSymbol(cols[symbolIdx])
            guard !symbol.isEmpty else { continue }

            let name = sanitise(
                nameIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? symbol,
                maxLength: Self.maxNameLength
            )

            let rawShares = sharesIdx.flatMap { $0 < cols.count ?
                Double(sanitise(cols[$0], maxLength: 20).replacingOccurrences(of: ",", with: "")) : nil
            } ?? 0
            let shares = clampValue(rawShares, max: Self.maxSharesValue)

            let rawCost = costIdx.flatMap { $0 < cols.count ?
                Double(sanitise(cols[$0], maxLength: 20).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) : nil
            }
            let cost = clampValue(rawCost ?? 0, max: Self.maxCostValue)

            let typeStr = sanitise(
                typeIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "",
                maxLength: 20
            ).lowercased()
            let isCrypto = typeStr.contains("crypto") || typeStr.contains("coin")

            if shares <= 0 { warnings += 1 }

            rows.append(CSVRow(symbol: symbol, name: name, shares: shares, avgCost: cost,
                               costKnown: rawCost == cost, isCrypto: isCrypto))
        }

        if rows.isEmpty {
            parseError = "No valid rows found. Check that the CSV has a header row with 'symbol' column."
            return
        }

        var warningMessages: [String] = []
        if warnings > 0 {
            warningMessages.append("\(warnings) row(s) had missing or zero shares")
        }
        if lines.count - 1 > Self.maxRows {
            warningMessages.append("Only first \(Self.maxRows) rows imported")
        }
        if !warningMessages.isEmpty {
            parseError = warningMessages.joined(separator: ". ")
        }

        parsedRows = rows
        selectedRows = Set(rows.filter { $0.shares > 0 }.map(\.id))
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - Import

    private func importSelected() {
        var added = 0, limited = 0
        var failed: [String] = []
        for row in parsedRows where selectedRows.contains(row.id) {
            let currency = row.isASX ? "AUD" : "USD"
            let usdCost = row.avgCost * (FXRates.shared.toUSDFactor(from: currency) ?? 1)
            let asset = Asset(symbol: row.displaySymbol,
                              name: row.name.isEmpty ? row.displaySymbol : row.name,
                              price: usdCost, change: 0, changePercent: 0, volume: 0,
                              kind: row.isCrypto ? .crypto : .stock,
                              exchange: row.isCrypto ? "Crypto" : (row.isASX ? "ASX" : "US"))
            switch marketData.addHolding(asset: asset, shares: row.shares, costPerUnit: row.avgCost, costCurrency: currency,
                                         source: .csvPosition, sourceCostKnown: row.costKnown) {
            case .ok: added += 1
            case .limitReached: limited += 1
            case .invalid: failed.append(row.displaySymbol)
            }
        }
        var text = "\(added) holding\(added == 1 ? "" : "s") added to your portfolio."
        if limited > 0 { text += " \(limited) skipped — your plan's holding limit was reached." }
        if !failed.isEmpty { text += " Couldn't add \(failed.joined(separator: ", ")) (missing quantity)." }
        resultText = text
        Haptics.success()
        dsAnimate { importComplete = true }
    }
}
