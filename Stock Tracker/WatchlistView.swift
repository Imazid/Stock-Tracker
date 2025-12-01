import SwiftUI
import UIKit

struct WatchlistView: View {
    @EnvironmentObject var marketData: MarketData
    
    @State private var filter: AssetKind = .stock
    @State private var searchText: String = ""
    @State private var showAddSheet = false
    @State private var showBrowseSheet = false
    @State private var selectedAsset: Asset?
    @State private var showAddToPortfolio = false
    @State private var assetToAdd: Asset?
    
    // Filtered watchlist items
    private var filteredAssets: [Asset] {
        var list = marketData.watchlist.filter { $0.kind == filter }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let lower = q.lowercased()
            list = list.filter {
                $0.symbol.lowercased().contains(lower) ||
                $0.name.lowercased().contains(lower)
            }
        }
        return list
    }
    
    var body: some View {
        VStack(spacing: 16) {
            header
            
            if filteredAssets.isEmpty {
                emptyState
            } else {
                // Use List instead of ScrollView for swipe actions
                List {
                    ForEach(filteredAssets) { asset in
                        Button {
                            selectedAsset = asset
                        } label: {
                            WatchlistRow(asset: asset)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                withAnimation {
                                    marketData.removeFromWatchlist(asset)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            
                            Button {
                                share(asset)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                            
                            Button {
                                assetToAdd = asset
                                showAddToPortfolio = true
                            } label: {
                                Label("Portfolio", systemImage: "plus.circle")
                            }
                            .tint(.green)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top)
        .sheet(isPresented: $showAddSheet) {
            WatchlistAddAssetSheet(kind: filter)
                .environmentObject(marketData)
        }
        .sheet(isPresented: $showBrowseSheet) {
            WatchlistBrowseSheet(kind: filter)
                .environmentObject(marketData)
        }
        .sheet(item: $selectedAsset) { asset in
            AssetDetailView(asset: asset)
        }
        .sheet(isPresented: $showAddToPortfolio) {
            if let asset = assetToAdd {
                AddToPortfolioSheet(asset: asset)
                    .environmentObject(marketData)
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Type", selection: $filter) {
                    Text("Stocks").tag(AssetKind.stock)
                    Text("Crypto").tag(AssetKind.crypto)
                }
                .pickerStyle(.segmented)
                
                Spacer()
                
                Button {
                    showBrowseSheet = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.ultraThinMaterial)
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.15),
                                                Color.white.opacity(0.05)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            }
                        )
                }
                .buttonStyle(.plain)
                
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.ultraThinMaterial)
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.15),
                                                Color.white.opacity(0.05)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                            }
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search watchlist…", text: $searchText)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                }
            )
            .padding(.horizontal)
        }
    }
    
    // MARK: - Empty state
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == .stock ? "chart.line.uptrend.xyaxis"
                                               : "bitcoinsign.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.4))
            Text("No items in watchlist")
                .font(.headline)
                .foregroundColor(.white)
            Text("Add \(filter == .stock ? "stocks" : "crypto") to start tracking prices.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            Button {
                showBrowseSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Browse \(filter == .stock ? "Stocks" : "Crypto")")
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white)
                )
                .foregroundColor(.black)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Share helper
    
    private func share(_ asset: Asset) {
        let text =
        """
        \(asset.symbol) — \(asset.name)
        Price: $\(String(format: "%.2f", asset.price))
        Change: \(asset.isPositive ? "+" : "")\(String(format: "%.2f", asset.changePercent))%
        """
        
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(vc, animated: true)
        }
    }
}

// MARK: - Row with improved glass effect

struct WatchlistRow: View {
    let asset: Asset
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("$\(asset.price, specifier: "%.2f")")
                    .font(.headline)
                    .foregroundColor(.white)
                HStack(spacing: 4) {
                    Image(systemName: asset.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text("\(asset.isPositive ? "+" : "")\(asset.changePercent, specifier: "%.2f")%")
                        .font(.caption.bold())
                }
                .foregroundColor(asset.isPositive ? .green : .red)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Add Asset Sheet

struct WatchlistAddAssetSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    
    let kind: AssetKind
    
    @State private var symbol: String = ""
    @State private var name: String = ""
    @State private var priceText: String = ""
    
    private var canSubmit: Bool {
        !symbol.trimmingCharacters(in: .whitespaces).isEmpty &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        Double(priceText) != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                Form {
                    Section("Details") {
                        TextField("Symbol", text: $symbol)
                            .autocapitalization(.allCharacters)
                        TextField("Name", text: $name)
                        TextField("Price", text: $priceText)
                            .keyboardType(.decimalPad)
                    }
                    
                    Section {
                        Button("Add to Watchlist") {
                            addAsset()
                        }
                        .disabled(!canSubmit)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add \(kind == .stock ? "Stock" : "Crypto")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func addAsset() {
        guard let price = Double(priceText) else { return }
        let asset = Asset(
            symbol: symbol.uppercased(),
            name: name,
            price: price,
            change: 0,
            changePercent: 0,
            volume: 0,
            kind: kind
        )
        marketData.addToWatchlist(asset)
        dismiss()
    }
}

// MARK: - Browse Sheet

struct WatchlistBrowseSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    
    let kind: AssetKind
    @State private var query: String = ""
    
    private var allAssets: [Asset] {
        kind == .stock ? marketData.stocks : marketData.crypto
    }
    
    private var results: [Asset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allAssets }
        let lower = q.lowercased()
        return allAssets.filter {
            $0.symbol.lowercased().contains(lower) ||
            $0.name.lowercased().contains(lower)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                List {
                    Section {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("Search…", text: $query)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                    
                    Section("Results") {
                        ForEach(results) { asset in
                            Button {
                                marketData.addToWatchlist(asset)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(asset.symbol)
                                        .font(.headline)
                                    Text(asset.name)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Spacer()
                                    Text("$\(asset.price, specifier: "%.2f")")
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Browse \(kind == .stock ? "Stocks" : "Crypto")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
