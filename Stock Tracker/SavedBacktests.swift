import CryptoKit
import Foundation
import Supabase
import SwiftUI
import TradingCore

struct BacktestDatasetReference: Codable, Sendable {
    let instrumentId: String
    let source: String
    let timeframe: Timeframe
    let window: String
    let bars: Int
    let firstBar: String?
    let lastBar: String?
    let currency: String
    let sha256: String
    let fetchedAt: String
    let volumeIsMarketWide: Bool

    init(series: BarSeries, window: String) throws {
        instrumentId = series.instrument.id
        source = series.provenance.source
        timeframe = series.timeframe
        self.window = window
        bars = series.bars.count
        firstBar = series.bars.first?.time.ISO8601Format(.init(includingFractionalSeconds: true))
        lastBar = series.bars.last?.time.ISO8601Format(.init(includingFractionalSeconds: true))
        currency = series.instrument.currency
        fetchedAt = series.fetchedAt.ISO8601Format(.init(includingFractionalSeconds: true))
        volumeIsMarketWide = series.volumeIsMarketWide
        let values = series.bars.map { [$0.time.timeIntervalSince1970 * 1_000, $0.open, $0.high, $0.low, $0.close, $0.volume] }
        sha256 = SHA256.hash(data: try JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }
}

struct BacktestArchive: Codable, Sendable {
    struct Inputs: Codable, Sendable {
        let spec: StrategySpec
        let config: BacktestConfig
        let window: String
        let benchmark: String?
        let asOf: Date
    }

    struct Failure: Codable, Sendable {
        let instrumentId: String
        let reasons: [String]
    }

    let schemaVersion: Int
    let title: String
    let engine: String
    let ranAt: String
    let inputs: Inputs
    let result: BacktestResult
    let datasets: [BacktestDatasetReference]
    let benchmarkDataset: BacktestDatasetReference?
    let failures: [Failure]
}

struct SavedBacktestRow: Decodable, Identifiable {
    let id: UUID
    let title: String
    let ran_at: String
    let saved_at: String

    var runDate: Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(ran_at)
    }
}

struct BacktestRecords {
    private let table = "backtest_runs"
    let owner: UUID

    private func requireOwner() async throws {
        guard try await SupabaseManager.auth.session.user.id == owner else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func save(id: UUID, archive: BacktestArchive) async throws {
        try await requireOwner()
        struct Record: Encodable { let user_id: UUID; let id: UUID; let report: AnyJSON }
        let encoded = try TradingCodec.encoder().encode(archive)
        let report = try JSONDecoder().decode(AnyJSON.self, from: encoded)
        try await SupabaseManager.client.from(table)
            .upsert(Record(user_id: owner, id: id, report: report), onConflict: "user_id,id", returning: .minimal, ignoreDuplicates: true).execute()
    }

    func page(after: SavedBacktestRow?, limit: Int) async throws -> [SavedBacktestRow] {
        try await requireOwner()
        let query = SupabaseManager.client.from(table).select("id,title,ran_at,saved_at").eq("user_id", value: owner.uuidString)
        if let after { query.or("saved_at.lt.\(after.saved_at),and(saved_at.eq.\(after.saved_at),id.lt.\(after.id.uuidString))") }
        return try await query.order("saved_at", ascending: false).order("id", ascending: false).limit(limit).execute().value
    }

    func report(_ id: UUID) async throws -> BacktestArchive {
        try await requireOwner()
        let response = try await SupabaseManager.client.from(table).select("report").eq("user_id", value: owner.uuidString).eq("id", value: id.uuidString).single().execute()
        struct Record: Decodable { let report: BacktestArchive }
        let archive = try TradingCodec.decoder().decode(Record.self, from: response.data).report
        guard archive.schemaVersion == 1, archive.result.usedRealMarketData else { throw TradingServerError.badReply }
        return archive
    }

    func remove(_ id: UUID) async throws {
        try await requireOwner()
        try await SupabaseManager.client.from(table).delete().eq("user_id", value: owner.uuidString).eq("id", value: id.uuidString).execute()
    }
}

struct SavedBacktestsView: View {
    let owner: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SavedBacktestRow] = []
    @State private var selected: BacktestBox?
    @State private var removing: SavedBacktestRow?
    @State private var hasMore = false
    @State private var loading = false
    @State private var problem: String?
    private let pageSize = 20
    private var records: BacktestRecords { BacktestRecords(owner: owner) }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty && !loading && problem == nil {
                    Text("Save a completed backtest to open it here on any signed-in device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        Task { await reopen(row) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline)
                            if let date = row.runDate { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(loading)
                    .swipeActions { Button("Remove", role: .destructive) { removing = row } }
                    .accessibilityIdentifier("backtest.saved.row")
                }
                if loading { ProgressView("Loading reports…") }
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                    Button("Reload reports") { Task { await load() } }
                } else if hasMore {
                    Button("Load older reports") { Task { await load(after: rows.last) } }.disabled(loading)
                }
            }
            .navigationTitle("Saved backtests")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("backtest.saved.done") } }
            .refreshable { await load() }
            .sheet(item: $selected) { box in NavigationStack { BacktestReportView(box: box) } }
            .confirmationDialog("Remove this saved report?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let row = removing { Button("Remove report", role: .destructive) { Task { await remove(row) } } }
            }
        }
        .task { await load() }
    }

    private func load(after: SavedBacktestRow? = nil) async {
        guard !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let page = try await records.page(after: after, limit: pageSize + 1)
            try Task.checkCancellation()
            rows = (after == nil ? [] : rows) + page.prefix(pageSize)
            hasMore = page.count > pageSize
        } catch is CancellationError {
        } catch { problem = "Saved reports could not be loaded." }
    }

    private func reopen(_ row: SavedBacktestRow) async {
        loading = true
        problem = nil
        defer { loading = false }
        do { selected = BacktestBox(id: row.id, archive: try await records.report(row.id), owner: owner, alreadySaved: true) }
        catch is CancellationError {
        } catch { problem = "This report could not be opened." }
    }

    private func remove(_ row: SavedBacktestRow) async {
        do {
            try await records.remove(row.id)
            rows.removeAll { $0.id == row.id }
        } catch is CancellationError {
        } catch { problem = "The report could not be removed. Try again." }
    }
}
