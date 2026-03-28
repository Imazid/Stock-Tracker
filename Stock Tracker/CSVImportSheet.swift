//
//  CSVImportSheet.swift
//  Stock Tracker
//
//  CSV import for bulk-adding portfolio holdings.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - CSV Import Sheet

struct CSVImportSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var showFilePicker = false
    @State private var parsedRows: [CSVRow] = []
    @State private var parseError: String?
    @State private var importComplete = false
    @State private var selectedRows: Set<UUID> = []

    struct CSVRow: Identifiable {
        let id = UUID()
        let symbol: String
        let name: String
        let shares: Double
        let avgCost: Double
        let isCrypto: Bool
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        headerSection(theme: theme)

                        if parsedRows.isEmpty && !importComplete {
                            formatGuide(theme: theme)
                            selectFileButton
                        } else if importComplete {
                            successView(theme: theme)
                        } else {
                            previewSection(theme: theme)
                            importButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    // MARK: - Header

    private func headerSection(theme: Theme) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.42, green: 0.35, blue: 0.65), Color(red: 0.32, green: 0.25, blue: 0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 48, height: 48)
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("CSV Import")
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Text(parsedRows.isEmpty ? "Import holdings from a spreadsheet" : "\(parsedRows.count) holdings found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(red: 0.42, green: 0.35, blue: 0.65).opacity(0.08))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0.42, green: 0.35, blue: 0.65).opacity(0.15), lineWidth: 1))
    }

    // MARK: - Format Guide

    private func formatGuide(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Expected CSV Format", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your CSV should have these columns:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    formatRow("Symbol", example: "AAPL", required: true)
                    formatRow("Name", example: "Apple Inc.", required: false)
                    formatRow("Shares", example: "10", required: true)
                    formatRow("Average Cost", example: "150.00", required: false)
                    formatRow("Type", example: "stock or crypto", required: false)
                }

                Divider().opacity(0.4)

                Text("Example:")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Text("symbol,name,shares,avg_cost,type\nAAPL,Apple Inc.,10,150.00,stock\nBTC,Bitcoin,0.5,42000.00,crypto")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.glassBackground)
                    .cornerRadius(8)
            }
            .padding(16)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 0.5))

            if let error = parseError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .cornerRadius(10)
            }
        }
    }

    private func formatRow(_ name: String, example: String, required: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .frame(width: 90, alignment: .leading)
            Text(example)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if required {
                Text("Required")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .cornerRadius(4)
            } else {
                Text("Optional")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - Select File Button

    private var selectFileButton: some View {
        Button {
            showFilePicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.title3)
                Text("Select CSV File").font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.42, green: 0.35, blue: 0.65), Color(red: 0.32, green: 0.25, blue: 0.55)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .cornerRadius(16)
            .shadow(color: Color(red: 0.42, green: 0.35, blue: 0.65).opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 12, y: 6)
        }
    }

    // MARK: - Preview Section

    private func previewSection(theme: Theme) -> some View {
        VStack(spacing: 14) {
            HStack {
                Label("Preview", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    if selectedRows.count == parsedRows.count {
                        selectedRows.removeAll()
                    } else {
                        selectedRows = Set(parsedRows.map(\.id))
                    }
                } label: {
                    Text(selectedRows.count == parsedRows.count ? "Deselect All" : "Select All")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.blue)
                }
            }

            VStack(spacing: 8) {
                ForEach(parsedRows) { row in
                    csvRowView(row, theme: theme)
                }
            }

            if let error = parseError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            Button {
                parsedRows = []
                selectedRows = []
                parseError = nil
                showFilePicker = true
            } label: {
                Text("Choose Different File")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func csvRowView(_ row: CSVRow, theme: Theme) -> some View {
        let isSelected = selectedRows.contains(row.id)
        return Button {
            if isSelected {
                selectedRows.remove(row.id)
            } else {
                selectedRows.insert(row.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))

                ZStack {
                    Circle()
                        .fill(row.isCrypto
                            ? LinearGradient(colors: [.orange, .orange.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.blue, .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 36, height: 36)
                    Text(String(row.symbol.prefix(2)))
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if row.isCrypto {
                            Text("Crypto")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange)
                                .cornerRadius(3)
                        }
                    }
                    if !row.name.isEmpty && row.name != row.symbol {
                        Text(row.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.4g", row.shares))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    if row.avgCost > 0 {
                        Text(String(format: "$%.2f", row.avgCost))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.06) : theme.glassBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : theme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import Button

    private var importButton: some View {
        let count = selectedRows.count
        return Button {
            guard count > 0 else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            importSelected()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.fill").font(.title3)
                Text("Import \(count) Holding\(count == 1 ? "" : "s")").font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                count > 0
                    ? LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.25)], startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .shadow(color: count > 0 ? Color.blue.opacity(colorScheme == .dark ? 0.35 : 0.10) : .clear, radius: 12, y: 6)
        }
        .disabled(count == 0)
        .animation(.easeInOut(duration: 0.2), value: count)
    }

    // MARK: - Success View

    private func successView(theme: Theme) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(appTheme.positiveColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(appTheme.positiveColor)
            }

            VStack(spacing: 6) {
                Text("Import Complete")
                    .font(.title2.bold())
                Text("Holdings have been added to your portfolio")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(appTheme.positiveColor)
                    .cornerRadius(14)
            }
        }
        .padding(.top, 40)
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
            } ?? 0
            let cost = clampValue(rawCost, max: Self.maxCostValue)

            let typeStr = sanitise(
                typeIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "",
                maxLength: 20
            ).lowercased()
            let isCrypto = typeStr.contains("crypto") || typeStr.contains("coin")

            if shares <= 0 { warnings += 1 }

            rows.append(CSVRow(symbol: symbol, name: name, shares: shares, avgCost: cost, isCrypto: isCrypto))
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
        let toImport = parsedRows.filter { selectedRows.contains($0.id) }

        for row in toImport {
            let asset = Asset(
                symbol: row.symbol,
                name: row.name.isEmpty ? row.symbol : row.name,
                price: row.avgCost,
                change: 0,
                changePercent: 0,
                volume: 0,
                kind: row.isCrypto ? .crypto : .stock,
                exchange: row.isCrypto ? "Crypto" : "CSV Import"
            )
            marketData.addToPortfolio(asset: asset, shares: row.shares, avgCost: row.avgCost)
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            importComplete = true
        }
    }
}
