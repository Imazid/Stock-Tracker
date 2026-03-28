//
//  SearchSheet.swift
//  Stock Tracker
//

import SwiftUI
import Combine
import Speech
import AVFoundation

// MARK: - Speech Recognizer

@MainActor
final class SearchVoiceRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var permissionDenied = false

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: .current)

    func toggle(onResult: @escaping (String) -> Void) {
        isRecording ? stopRecording() : requestAndStart(onResult: onResult)
    }

    private func requestAndStart(onResult: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized:
                    self.startRecording(onResult: onResult)
                default:
                    self.permissionDenied = true
                }
            }
        }
    }

    private func startRecording(onResult: @escaping (String) -> Void) {
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in onResult(result.bestTranscription.formattedString) }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in self.stopRecording() }
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Search Sheet

struct SearchSheet: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    let kind: AssetKind
    var isEmbedded: Bool = false

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showWatchlistPaywall = false
    @FocusState private var isSearchFocused: Bool
    @StateObject private var speech = SearchVoiceRecognizer()

    private var filteredResults: [Asset] {
        marketData.searchResults.filter { $0.kind == kind }
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar(theme: theme)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    ScrollView {
                        if isSearching {
                            searchingState
                        } else if searchText.isEmpty {
                            initialState(theme: theme)
                        } else if filteredResults.isEmpty {
                            noResultsState(theme: theme)
                        } else {
                            resultsView(theme: theme)
                        }
                    }
                }
            }
            .navigationTitle(kind == .stock ? "Search Stocks" : "Search Crypto")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                guard !newValue.isEmpty else {
                    marketData.searchResults = []
                    isSearching = false
                    return
                }
                isSearching = true
                marketData.searchAssets(query: newValue, kind: kind)
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    isSearching = false
                }
            }
            .onDisappear {
                if speech.isRecording { speech.stopRecording() }
            }
            .sheet(isPresented: $showWatchlistPaywall) {
                PaywallView(requiredTier: .pro, featureName: "Unlimited Watchlist")
                    .environmentObject(subscriptionManager)
            }
            .alert("Microphone Access Needed", isPresented: $speech.permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enable Microphone and Speech Recognition in Settings to use voice search.")
            }
        }
    }

    // MARK: - Search Bar

    private func searchBar(theme: Theme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isSearchFocused ? .blue : .secondary)

            TextField(kind == .stock ? "Search stocks..." : "Search crypto...", text: $searchText)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .font(.body)
                .onSubmit {
                    if !searchText.isEmpty {
                        marketData.searchAssets(query: searchText, kind: kind)
                    }
                }

            if !searchText.isEmpty || speech.isRecording {
                Button {
                    searchText = ""
                    if speech.isRecording { speech.stopRecording() }
                    marketData.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .transition(.scale.combined(with: .opacity))
            }

            if searchText.isEmpty {
                Button {
                    speech.toggle { transcript in
                        searchText = transcript
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(speech.isRecording ? .red : .blue)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSearchFocused ? Color.blue.opacity(0.4) : theme.glassBorder, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
        .onAppear {
            if !isEmbedded { isSearchFocused = true }
        }
    }

    // MARK: - Initial State

    private func initialState(theme: Theme) -> some View {
        VStack(spacing: 32) {
            // Hero
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.15), Color.blue.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)

                    Image(systemName: kind == .stock ? "chart.line.uptrend.xyaxis" : "bitcoinsign.circle")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 6) {
                    Text("Find your next investment")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Search by ticker symbol or company name")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 32)

            // Trending section
            VStack(alignment: .leading, spacing: 14) {
                Label("Trending", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.secondaryText)

                FlowLayout(spacing: 8) {
                    ForEach(popularSymbols, id: \.self) { symbol in
                        Button {
                            searchText = symbol
                        } label: {
                            Text(symbol)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(theme.primaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(theme.glassBackground)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.glassBorder, lineWidth: 0.5)
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            // ASX section
            if kind == .stock {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Label("ASX Popular", systemImage: "globe.asia.australia")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(theme.secondaryText)
                    }

                    FlowLayout(spacing: 8) {
                        ForEach(popularASXSymbols, id: \.self) { symbol in
                            Button {
                                searchText = symbol
                            } label: {
                                HStack(spacing: 5) {
                                    Text(symbol.replacingOccurrences(of: ".AX", with: ""))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(theme.primaryText)

                                    Text("ASX")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(
                                            LinearGradient(
                                                colors: [.orange, .orange.opacity(0.8)],
                                                startPoint: .leading, endPoint: .trailing
                                            )
                                        )
                                        .cornerRadius(4)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(theme.glassBackground)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.glassBorder, lineWidth: 0.5)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            // Voice hint
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                Text("Tap the mic to search by voice")
                    .font(.caption)
            }
            .foregroundColor(theme.secondaryText.opacity(0.6))
            .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Searching State

    private var searchingState: some View {
        VStack(spacing: 0) {
            StaggeredSkeletonList(count: 5) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        SkeletonCircle(size: 44)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 60, height: 14)
                            SkeletonBlock(width: 150, height: 11)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            SkeletonBlock(width: 70, height: 14)
                            SkeletonBlock(width: 50, height: 11)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    Divider().padding(.leading, 78)
                }
            }
        }
    }

    // MARK: - No Results

    private func noResultsState(theme: Theme) -> some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(theme.glassBackground)
                        .frame(width: 72, height: 72)

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 8) {
                    Text("No results for \"\(searchText)\"")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Try a different ticker or company name")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer()
        }
        .padding(.top, 60)
    }

    // MARK: - Results

    private func resultsView(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(filteredResults.count) \(filteredResults.count == 1 ? "result" : "results")")
                .font(.caption.weight(.medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            LazyVStack(spacing: 0) {
                ForEach(filteredResults) { asset in
                    let alreadyAdded = marketData.watchlist.contains { $0.symbol == asset.symbol }

                    SearchResultCard(asset: asset)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .onTapGesture {
                            if alreadyAdded || subscriptionManager.canAddToWatchlist(currentCount: marketData.watchlist.count) {
                                marketData.addToWatchlist(asset)
                                if !isEmbedded { dismiss() }
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                showWatchlistPaywall = true
                            }
                        }
                }
            }
        }
    }

    // MARK: - Popular Symbols

    private var popularSymbols: [String] {
        switch kind {
        case .stock:
            return ["AAPL", "TSLA", "NVDA", "MSFT", "GOOGL", "AMZN", "META"]
        case .crypto:
            return ["BTC", "ETH", "SOL", "ADA", "DOGE"]
        }
    }

    private var popularASXSymbols: [String] {
        ["BHP.AX", "CBA.AX", "CSL.AX", "NAB.AX", "WBC.AX", "ANZ.AX", "FMG.AX"]
    }
}

// MARK: - Search Result Card

private struct SearchResultCard: View {
    let asset: Asset
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var isInWatchlist: Bool {
        marketData.watchlist.contains { $0.symbol == asset.symbol }
    }

    private var iconGradient: [Color] {
        if asset.exchange == "ASX" {
            return [.orange, .orange.opacity(0.7)]
        }
        if asset.kind == .crypto {
            return [.purple, .purple.opacity(0.7)]
        }
        return [.blue, .blue.opacity(0.7)]
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 14) {
            // Symbol icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: iconGradient,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Text(String(asset.symbol.prefix(2)))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            // Name + exchange
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if asset.exchange == "ASX" {
                        Text("ASX")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .orange.opacity(0.8)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .cornerRadius(4)
                    } else if !asset.exchange.isEmpty {
                        Text(asset.exchange)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                    }
                }

                Text(asset.name)
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Price + change
            if asset.price > 0 {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    HStack(spacing: 3) {
                        Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f", asset.changePercent))%")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor).opacity(0.1)
                    )
                    .cornerRadius(4)
                }
            }

            // Add / checkmark
            Image(systemName: isInWatchlist ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 24))
                .foregroundStyle(
                    isInWatchlist
                        ? AnyShapeStyle(LinearGradient(colors: [appTheme.positiveColor, appTheme.positiveColor.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isInWatchlist)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isInWatchlist ? appTheme.positiveColor.opacity(0.3) : theme.glassBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Flow Layout (wrapping horizontal layout for chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

#Preview {
    SearchSheet(kind: .stock)
        .environmentObject(MarketData())
        .environmentObject(SubscriptionManager.shared)
}
