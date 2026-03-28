//
//  DebugView.swift
//  Stock Tracker
//

import SwiftUI

struct DebugView: View {
    @EnvironmentObject var marketData: MarketData
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var apiLog: [APILogEntry] = []
    @State private var isRefreshing = false
    @State private var showClearConfirm = false

    // API status
    @State private var statusResults: [APICheckResult] = []
    @State private var isCheckingAPIs = false

    // FMP test
    @State private var fmpTestSymbol = "AAPL"
    @State private var isFMPTesting = false

    // ASX test
    @State private var asxTestSymbol = "BHP"
    @State private var isASXTesting = false

    // Fiscal.ai test
    @State private var fiscalTestSymbol = "AAPL"
    @State private var isFiscalTesting = false

    // OpenAI test
    @State private var isOpenAITesting = false

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                List {
                    // MARK: - API Connection Status
                    Section {
                        if isCheckingAPIs && statusResults.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Checking APIs…")
                                    .foregroundColor(.gray)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 4)
                        } else {
                            ForEach(statusResults) { result in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(result.statusColor)
                                        .frame(width: 10, height: 10)
                                    Text(result.name)
                                        .foregroundColor(theme.primaryText)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(result.detail)
                                            .font(.caption)
                                            .foregroundColor(result.statusColor)
                                        Text(String(format: "%.0f ms", result.latency * 1000))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            Button {
                                Task { await checkAllAPIs() }
                            } label: {
                                HStack {
                                    if isCheckingAPIs {
                                        ProgressView().tint(theme.progressTint)
                                    } else {
                                        Image(systemName: "wifi")
                                    }
                                    Text(statusResults.isEmpty ? "Check All APIs" : "Re-check All APIs")
                                }
                            }
                            .disabled(isCheckingAPIs)
                        }
                    } header: {
                        Text("API Connection Status")
                    } footer: {
                        if let last = statusResults.first?.checkedAt {
                            Text("Last checked: \(last, style: .relative) ago")
                                .font(.caption2)
                        }
                    }

                    // MARK: - Data Summary
                    Section("Local Data") {
                        row("Stocks", "\(marketData.stocks.count)")
                        row("Crypto", "\(marketData.crypto.count)")
                        row("Portfolio Holdings", "\(marketData.portfolio.count)")
                        row("Watchlist Items", "\(marketData.watchlist.count)")
                        row("News Articles", "\(marketData.newsArticles.count)")
                        row("Portfolio Value", String(format: "$%.2f", marketData.totalPortfolioValue))
                    }

                    // MARK: - Subscription Tier Override
                    Section {
                        HStack {
                            Image(systemName: subscriptionManager.currentTier.icon)
                                .foregroundColor(subscriptionManager.currentTier.color)
                                .frame(width: 20)
                            Text("Current Tier")
                                .foregroundColor(theme.primaryText)
                            Spacer()
                            Text(subscriptionManager.currentTier.displayName)
                                .font(.caption.bold())
                                .foregroundColor(subscriptionManager.currentTier.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(subscriptionManager.currentTier.color.opacity(0.15))
                                .cornerRadius(8)
                        }

                        Picker("Tier", selection: $subscriptionManager.currentTier) {
                            ForEach(SubscriptionTier.allCases, id: \.self) { tier in
                                Label(tier.displayName, systemImage: tier.icon)
                                    .tag(tier)
                            }
                        }
                        .pickerStyle(.segmented)

                        if subscriptionManager.currentTier != .free {
                            Text("⚠️ Debug override active — ads hidden, all features unlocked.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } header: {
                        Text("Subscription Tier (Debug)")
                    } footer: {
                        Text("Overrides the real StoreKit tier in-session only. Resets on relaunch.")
                            .font(.caption2)
                    }

                    // MARK: - Storage Info
                    Section("Storage") {
                        let keys = ["saved_watchlist", "saved_portfolio", "saved_custom_assets", "saved_price_alerts", "saved_portfolio_history"]
                        let totalBytes = keys.compactMap { UserDefaults.standard.data(forKey: $0)?.count }.reduce(0, +)
                        row("UserDefaults Size", ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                        row("Saved Portfolio", DataPersistenceManager.shared.loadPortfolio().isEmpty ? "No" : "Yes")
                        row("Saved Watchlist", DataPersistenceManager.shared.loadWatchlist().isEmpty ? "No" : "Yes")
                    }

                    // MARK: - API Keys Diagnostic
                    Section {
                        keyRow("Alpaca API Key",     SecretsConfig.alpacaAPIKey)
                        keyRow("Alpaca Secret Key",  SecretsConfig.alpacaSecretKey)
                        keyRow("Alpha Vantage Key",  SecretsConfig.alphaVantageKey)
                        keyRow("Finnhub Key",        SecretsConfig.finnhubAPIKey, optional: true)
                        keyRow("OpenAI Key",         SecretsConfig.openAIAPIKey)
                        keyRow("SnapTrade Client ID",SecretsConfig.snapTradeClientId)
                        keyRow("SnapTrade Consumer", SecretsConfig.snapTradeConsumerKey)
                        keyRow("CoinGecko Key",      SecretsConfig.coinGeckoAPIKey, optional: true)
                        keyRow("FMP Key",            SecretsConfig.fmpAPIKey,       optional: true)
                        keyRow("Fiscal.ai Key",      SecretsConfig.fiscalAIAPIKey,  optional: true)
                    } header: {
                        Text("API Keys Loaded")
                    } footer: {
                        Text("Shows first 6 chars — verifies keys are loading from Secrets.plist / Keychain.")
                            .font(.caption2)
                    }

                    // MARK: - Actions
                    Section("Actions") {
                        Button {
                            isRefreshing = true
                            Task {
                                await marketData.refreshFromAPI()
                                log("Refreshed all APIs (stocks, crypto, news)")
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Force Refresh All APIs")
                                if isRefreshing {
                                    Spacer()
                                    ProgressView().tint(theme.progressTint)
                                }
                            }
                        }

                        Button {
                            marketData.saveToDisk()
                            log("Saved all data to disk")
                        } label: {
                            HStack {
                                Image(systemName: "externaldrive.fill")
                                Text("Force Save to Disk")
                            }
                        }

                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Clear All Local Data")
                            }
                        }

                        Button(role: .destructive) {
                            UserDefaults.standard.hasCompletedOnboarding = false
                            UserDefaults.standard.removeObject(forKey: "onboarding_stocks")
                            log("Onboarding reset — relaunch app to see it again")
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                Text("Reset Onboarding")
                            }
                        }
                    }

                    // MARK: - API Tests
                    Section("API Tests") {
                        Button {
                            Task { await testStockAPI() }
                        } label: {
                            HStack {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                Text("Test Stock Quote (AAPL)")
                            }
                        }

                        Button {
                            Task { await testCryptoAPI() }
                        } label: {
                            HStack {
                                Image(systemName: "bitcoinsign.circle")
                                Text("Test Crypto Price (bitcoin)")
                            }
                        }

                        Button {
                            Task { await testNewsAPI() }
                        } label: {
                            HStack {
                                Image(systemName: "newspaper")
                                Text("Test News API")
                            }
                        }

                        Button {
                            Task { await testHistoricalBars() }
                        } label: {
                            HStack {
                                Image(systemName: "chart.bar")
                                Text("Test Historical Bars (AAPL 1D)")
                            }
                        }
                    }

                    // MARK: - ASX (Alpha Vantage) Test
                    Section {
                        HStack {
                            Image(systemName: "globe.asia.australia")
                                .foregroundColor(.orange)
                                .frame(width: 20)
                            TextField("ASX Symbol (e.g. BHP)", text: $asxTestSymbol)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        }

                        Button {
                            Task { await testASXQuote() }
                        } label: {
                            HStack {
                                if isASXTesting {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                }
                                Text(isASXTesting ? "Fetching…" : "Test ASX Quote")
                            }
                        }
                        .disabled(isASXTesting || asxTestSymbol.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button {
                            Task { await testASXCandles() }
                        } label: {
                            HStack {
                                if isASXTesting {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "chart.bar.fill")
                                }
                                Text(isASXTesting ? "Fetching…" : "Test ASX History 1M")
                            }
                        }
                        .disabled(isASXTesting || asxTestSymbol.trimmingCharacters(in: .whitespaces).isEmpty)

                        if SecretsConfig.alphaVantageKey.isEmpty {
                            Label("Alpha Vantage key not set — add AlphaVantageKey to Secrets.plist", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } header: {
                        Text("ASX Stocks (Alpha Vantage)")
                    } footer: {
                        Text("Tests Alpha Vantage GLOBAL_QUOTE + TIME_SERIES_DAILY for ASX. Symbol sent as \(asxTestSymbol.uppercased()).AX")
                            .font(.caption2)
                    }

                    // MARK: - FMP Test
                    Section {
                        HStack {
                            Image(systemName: "building.2")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            TextField("Symbol (e.g. AAPL)", text: $fmpTestSymbol)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        }

                        Button {
                            Task { await testFMPAPI() }
                        } label: {
                            HStack {
                                if isFMPTesting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.down.doc.fill")
                                }
                                Text(isFMPTesting ? "Fetching…" : "Fetch FMP Profile + Quote")
                            }
                        }
                        .disabled(isFMPTesting || fmpTestSymbol.trimmingCharacters(in: .whitespaces).isEmpty)

                        if SecretsConfig.fmpAPIKey.isEmpty {
                            Label("FMP key not set — add FMPAPIKey to Secrets.plist", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } header: {
                        Text("FMP Company Data Test")
                    } footer: {
                        Text("Tests FMPService directly. Results appear in the Activity Log below.")
                            .font(.caption2)
                    }

                    // MARK: - Fiscal.ai Test
                    Section {
                        HStack {
                            Image(systemName: "chart.pie")
                                .foregroundColor(.purple)
                                .frame(width: 20)
                            TextField("Symbol (e.g. AAPL)", text: $fiscalTestSymbol)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        }

                        Button {
                            Task { await testFiscalAI() }
                        } label: {
                            HStack {
                                if isFiscalTesting {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "sparkle.magnifyingglass")
                                }
                                Text(isFiscalTesting ? "Fetching…" : "Fetch Fundamentals")
                            }
                        }
                        .disabled(isFiscalTesting || fiscalTestSymbol.trimmingCharacters(in: .whitespaces).isEmpty)

                        if SecretsConfig.fiscalAIAPIKey.isEmpty {
                            Label("Fiscal.ai key not set — add FiscalAIAPIKey to Secrets.plist", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } header: {
                        Text("Fiscal.ai Fundamentals Test")
                    } footer: {
                        Text("Tests Fiscal.ai company profile + ratios. Free tier: 250 calls/day.")
                            .font(.caption2)
                    }

                    // MARK: - OpenAI Test
                    Section {
                        Button {
                            Task { await testOpenAI() }
                        } label: {
                            HStack {
                                if isOpenAITesting {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "brain")
                                }
                                Text(isOpenAITesting ? "Testing…" : "Test AI Chat (ping)")
                            }
                        }
                        .disabled(isOpenAITesting)

                        if SecretsConfig.openAIAPIKey.isEmpty {
                            Label("OpenAI key not set — add OpenAIAPIKey to Secrets.plist", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } header: {
                        Text("OpenAI / ChatGPT Test")
                    } footer: {
                        Text("Sends a minimal prompt to verify the API key works and returns a response.")
                            .font(.caption2)
                    }

                    // MARK: - Asset Details
                    Section("Stock Prices") {
                        ForEach(marketData.stocks) { asset in
                            row(asset.symbol, String(format: "$%.2f (%.2f%%)", asset.price, asset.changePercent))
                        }
                    }

                    Section("Crypto Prices") {
                        ForEach(marketData.crypto) { asset in
                            row(asset.symbol, String(format: "$%.2f (%.2f%%)", asset.price, asset.changePercent))
                        }
                    }

                    // MARK: - Log
                    Section("Activity Log") {
                        if apiLog.isEmpty {
                            Text("No activity yet. Run a test above.")
                                .foregroundColor(.gray)
                                .font(.caption)
                        } else {
                            ForEach(apiLog) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.message)
                                        .font(.caption)
                                        .foregroundColor(entry.isError ? .red : .green)
                                    Text(entry.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Debug Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear all local data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Everything", role: .destructive) {
                    clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will reset portfolio, watchlist, and all saved data to defaults. This cannot be undone.")
            }
            .task {
                await checkAllAPIs()
            }
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        let theme = Theme(colorScheme: colorScheme)
        return HStack {
            Text(label)
                .foregroundColor(theme.primaryText)
            Spacer()
            Text(value)
                .foregroundColor(.gray)
                .font(.caption)
        }
    }

    private func keyRow(_ label: String, _ value: String, optional: Bool = false) -> some View {
        let theme = Theme(colorScheme: colorScheme)
        let display: String
        let color: Color
        if value.isEmpty {
            display = optional ? "Not set (optional)" : "MISSING"
            color = optional ? .gray : .red
        } else {
            display = String(value.prefix(6)) + "••••••"
            color = .green
        }
        return HStack {
            Text(label)
                .foregroundColor(theme.primaryText)
            Spacer()
            Text(display)
                .font(.caption.monospaced())
                .foregroundColor(color)
        }
    }

    private func log(_ message: String, isError: Bool = false) {
        apiLog.insert(APILogEntry(message: message, isError: isError), at: 0)
    }

    // MARK: - API Status Checks

    private func checkAllAPIs() async {
        isCheckingAPIs = true
        defer { isCheckingAPIs = false }

        // Run all checks concurrently
        async let alpaca = checkAlpaca()
        async let coinGecko = checkCoinGecko()
        async let news = checkNewsAPI()
        async let alphaVantage = checkAlphaVantage()
        async let openAI = checkOpenAI()
        async let snapTrade = checkSnapTrade()
        async let fmp = checkFMP()
        async let finnhubASX = checkFinnhubASX()
        async let fiscalAI = checkFiscalAI()

        let results = await [alpaca, coinGecko, news, alphaVantage, openAI, snapTrade, fmp, finnhubASX, fiscalAI]
        statusResults = results
    }

    private func checkFMP() async -> APICheckResult {
        let start = Date()
        guard !SecretsConfig.fmpAPIKey.isEmpty else {
            return APICheckResult(name: "FMP (Company Data)", status: .badKey,
                                  detail: "Key not configured", latency: 0)
        }
        let ratios = await FMPService.shared.fetchRatios(symbol: "AAPL")
        let latency = Date().timeIntervalSince(start)
        if let r = ratios {
            let pe = r.priceEarningsRatio.map { String(format: "P/E %.1f", $0) } ?? "connected"
            return APICheckResult(name: "FMP (Company Data)", status: .ok,
                                  detail: "AAPL \(pe)", latency: latency)
        } else {
            return APICheckResult(name: "FMP (Company Data)", status: .error,
                                  detail: "No data — key invalid or quota exceeded", latency: latency)
        }
    }

    private func checkAlpaca() async -> APICheckResult {
        let start = Date()
        do {
            let asset = try await APIService.shared.fetchStockQuote(symbol: "AAPL")
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Alpaca (Stocks)", status: .ok,
                                  detail: "AAPL $\(String(format: "%.2f", asset.price))", latency: latency)
        } catch let err as APIError {
            let latency = Date().timeIntervalSince(start)
            if case .serverError(let code) = err {
                switch code {
                case 401, 403: return APICheckResult(name: "Alpaca (Stocks)", status: .badKey,
                                                     detail: "HTTP \(code) – check API key", latency: latency)
                case 422:      return APICheckResult(name: "Alpaca (Stocks)", status: .error,
                                                     detail: "HTTP 422 – free plan may not support this feed", latency: latency)
                case 429:      return APICheckResult(name: "Alpaca (Stocks)", status: .limited,
                                                     detail: "HTTP 429 – rate limited", latency: latency)
                default:       return APICheckResult(name: "Alpaca (Stocks)", status: .error,
                                                     detail: "HTTP \(code)", latency: latency)
                }
            }
            return APICheckResult(name: "Alpaca (Stocks)", status: .error,
                                  detail: err.localizedDescription, latency: latency)
        } catch {
            return APICheckResult(name: "Alpaca (Stocks)", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    private func checkCoinGecko() async -> APICheckResult {
        let start = Date()
        do {
            let asset = try await APIService.shared.fetchCryptoPrice(id: "bitcoin")
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "CoinGecko (Crypto)", status: .ok,
                                  detail: "BTC $\(String(format: "%.0f", asset.price))", latency: latency)
        } catch {
            return APICheckResult(name: "CoinGecko (Crypto)", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    private func checkNewsAPI() async -> APICheckResult {
        let start = Date()
        do {
            let articles = try await APIService.shared.fetchNews()
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Finnhub News", status: .ok,
                                  detail: "\(articles.count) articles", latency: latency)
        } catch let err as APIError {
            let latency = Date().timeIntervalSince(start)
            if case .serverError(let code) = err {
                switch code {
                case 401: return APICheckResult(name: "Finnhub News", status: .badKey,
                                                detail: "401 – invalid API key", latency: latency)
                case 429: return APICheckResult(name: "Finnhub News", status: .limited,
                                                detail: "429 – rate limited (60/min on free tier)", latency: latency)
                default:  return APICheckResult(name: "Finnhub News", status: .error,
                                                detail: "HTTP \(code)", latency: latency)
                }
            }
            return APICheckResult(name: "Finnhub News", status: .error,
                                  detail: err.localizedDescription, latency: latency)
        } catch {
            return APICheckResult(name: "Finnhub News", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    private func checkAlphaVantage() async -> APICheckResult {
        let start = Date()
        do {
            let results = try await APIService.shared.fetchSymbolSearch(query: "AAPL", kind: .stock)
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Alpha Vantage (Search)", status: .ok,
                                  detail: "\(results.count) results", latency: latency)
        } catch {
            return APICheckResult(name: "Alpha Vantage (Search)", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    private func checkOpenAI() async -> APICheckResult {
        // Lightweight reachability check — sends a minimal 1-token request to avoid cost
        let start = Date()
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(SecretsConfig.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(start)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200: return APICheckResult(name: "OpenAI (AI Chat)", status: .ok,
                                                detail: "Connected", latency: latency)
                case 401: return APICheckResult(name: "OpenAI (AI Chat)", status: .badKey,
                                                detail: "Invalid API key (401)", latency: latency)
                case 429: return APICheckResult(name: "OpenAI (AI Chat)", status: .limited,
                                                detail: "Rate limited (429)", latency: latency)
                default:  return APICheckResult(name: "OpenAI (AI Chat)", status: .error,
                                                detail: "HTTP \(http.statusCode)", latency: latency)
                }
            }
            return APICheckResult(name: "OpenAI (AI Chat)", status: .error, detail: "No response", latency: latency)
        } catch {
            return APICheckResult(name: "OpenAI (AI Chat)", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    private func checkSnapTrade() async -> APICheckResult {
        let start = Date()
        let clientId = SecretsConfig.snapTradeClientId
        let consumerKey = SecretsConfig.snapTradeConsumerKey

        guard !clientId.isEmpty, !consumerKey.isEmpty else {
            return APICheckResult(name: "SnapTrade (Brokerage)", status: .badKey,
                                  detail: "Keys not configured", latency: 0)
        }

        do {
            let client = SnapTradeClient(clientID: clientId, consumerKey: consumerKey)
            let request = try client.createRequest(path: "/snapTrade/listBrokerages",
                                                   queryParams: ["clientId": clientId])
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(start)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:      return APICheckResult(name: "SnapTrade (Brokerage)", status: .ok,
                                                     detail: "Connected", latency: latency)
                case 401, 403: return APICheckResult(name: "SnapTrade (Brokerage)", status: .badKey,
                                                     detail: "HTTP \(http.statusCode) – invalid credentials", latency: latency)
                case 429:      return APICheckResult(name: "SnapTrade (Brokerage)", status: .limited,
                                                     detail: "Rate limited (429)", latency: latency)
                default:       return APICheckResult(name: "SnapTrade (Brokerage)", status: .error,
                                                     detail: "HTTP \(http.statusCode)", latency: latency)
                }
            }
            return APICheckResult(name: "SnapTrade (Brokerage)", status: .error, detail: "No response", latency: latency)
        } catch {
            return APICheckResult(name: "SnapTrade (Brokerage)", status: .error,
                                  detail: error.localizedDescription, latency: Date().timeIntervalSince(start))
        }
    }

    // MARK: - Legacy Test Buttons

    private func testStockAPI() async {
        do {
            let asset = try await APIService.shared.fetchStockQuote(symbol: "AAPL")
            log("AAPL: $\(String(format: "%.2f", asset.price))")
        } catch {
            log("Stock API error: \(error.localizedDescription)", isError: true)
        }
    }

    private func testCryptoAPI() async {
        do {
            let asset = try await APIService.shared.fetchCryptoPrice(id: "bitcoin")
            log("BTC: $\(String(format: "%.2f", asset.price))")
        } catch {
            log("Crypto API error: \(error.localizedDescription)", isError: true)
        }
    }

    private func testNewsAPI() async {
        do {
            let articles = try await APIService.shared.fetchNews()
            log("News: \(articles.count) articles fetched")
        } catch {
            log("News API error: \(error.localizedDescription)", isError: true)
        }
    }

    private func testHistoricalBars() async {
        do {
            let bars = try await APIService.shared.fetchBars(symbol: "AAPL", timeframe: "Day", multiplier: 1, range: .oneMonth)
            log("AAPL bars: \(bars.count) candles")
        } catch {
            log("Bars API error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - ASX Tests

    private func testASXQuote() async {
        let symbol = asxTestSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return }
        isASXTesting = true
        defer { isASXTesting = false }

        let finnhubSymbol = symbol.hasSuffix(".AX") ? symbol : "\(symbol).AX"
        do {
            let asset = try await APIService.shared.fetchFinnhubQuote(symbol: finnhubSymbol, name: symbol)
            log("ASX \(symbol): $\(String(format: "%.2f", asset.price)) (\(String(format: "%+.2f%%", asset.changePercent))) exchange=\(asset.exchange)")
        } catch {
            log("ASX quote error for \(finnhubSymbol): \(error.localizedDescription)", isError: true)
        }
    }

    private func testASXCandles() async {
        let symbol = asxTestSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return }
        isASXTesting = true
        defer { isASXTesting = false }

        let finnhubSymbol = symbol.hasSuffix(".AX") ? symbol : "\(symbol).AX"
        do {
            let points = try await APIService.shared.fetchFinnhubCandles(symbol: finnhubSymbol, range: .oneMonth)
            if points.isEmpty {
                log("ASX \(symbol): 0 candles returned (no_data or invalid symbol)", isError: true)
            } else {
                let first = points.first!
                let last = points.last!
                log("ASX \(symbol) candles: \(points.count) points, \(String(format: "%.2f", first.price)) → \(String(format: "%.2f", last.price))")
            }
        } catch {
            log("ASX candles error for \(finnhubSymbol): \(error.localizedDescription)", isError: true)
        }
    }

    private func checkFinnhubASX() async -> APICheckResult {
        let start = Date()
        guard !SecretsConfig.alphaVantageKey.isEmpty else {
            return APICheckResult(name: "Alpha Vantage (ASX)", status: .badKey,
                                  detail: "Key not configured", latency: 0)
        }
        do {
            let asset = try await APIService.shared.fetchFinnhubQuote(symbol: "BHP.AX", name: "BHP Group")
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Alpha Vantage (ASX)", status: .ok,
                                  detail: "BHP $\(String(format: "%.2f", asset.price))", latency: latency)
        } catch {
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Alpha Vantage (ASX)", status: .error,
                                  detail: error.localizedDescription, latency: latency)
        }
    }

    private func testFMPAPI() async {
        let symbol = fmpTestSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return }

        isFMPTesting = true
        defer { isFMPTesting = false }

        let key = SecretsConfig.fmpAPIKey
        log("FMP key: \(key.isEmpty ? "EMPTY — add FMPAPIKey to Secrets.plist" : String(key.prefix(6)) + "••••")")

        guard !key.isEmpty else {
            log("FMP: aborting — no key configured", isError: true)
            return
        }

        // Raw fetch all four endpoints so we can see exact field names returned
        await fmpRawFetch(label: "quote",            urlString: "https://financialmodelingprep.com/stable/quote?symbol=\(symbol)&apikey=\(key)")
        await fmpRawFetch(label: "profile",          urlString: "https://financialmodelingprep.com/stable/profile?symbol=\(symbol)&apikey=\(key)")
        await fmpRawFetch(label: "ratios",           urlString: "https://financialmodelingprep.com/stable/ratios?symbol=\(symbol)&limit=1&apikey=\(key)")
        await fmpRawFetch(label: "income-statement", urlString: "https://financialmodelingprep.com/stable/income-statement?symbol=\(symbol)&limit=2&apikey=\(key)")
    }

    private func fmpRawFetch(label: String, urlString: String) async {
        guard let url = URL(string: urlString) else {
            log("FMP \(label): invalid URL", isError: true)
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let preview = String(body.prefix(300))

            if status == 200 {
                // Try to detect FMP error object vs real array
                if body.hasPrefix("[") {
                    log("FMP \(label): HTTP \(status) ✓  body: \(preview)")
                } else {
                    log("FMP \(label): HTTP \(status) but response is not an array — \(preview)", isError: true)
                }
            } else {
                log("FMP \(label): HTTP \(status) — \(preview)", isError: true)
            }
        } catch {
            log("FMP \(label): request failed — \(error.localizedDescription)", isError: true)
        }
    }

    private func fmpFormatBig(_ v: Double) -> String {
        switch v {
        case 1_000_000_000_000...: return String(format: "$%.2fT", v / 1_000_000_000_000)
        case 1_000_000_000...:     return String(format: "$%.2fB", v / 1_000_000_000)
        case 1_000_000...:         return String(format: "$%.2fM", v / 1_000_000)
        default:                   return String(format: "$%.0f", v)
        }
    }

    // MARK: - Fiscal.ai Check & Test

    private func checkFiscalAI() async -> APICheckResult {
        let start = Date()
        guard !SecretsConfig.fiscalAIAPIKey.isEmpty else {
            return APICheckResult(name: "Fiscal.ai (Fundamentals)", status: .badKey,
                                  detail: "Key not configured", latency: 0)
        }
        do {
            let data = try await APIService.shared.fetchFiscalFundamentals(symbol: "MSFT", exchange: "NASDAQ")
            let latency = Date().timeIntervalSince(start)
            if let pe = data.peRatio, pe > 0 {
                return APICheckResult(name: "Fiscal.ai (Fundamentals)", status: .ok,
                                      detail: "MSFT P/E \(String(format: "%.1f", pe))", latency: latency)
            } else if let mc = data.marketCap, mc > 0 {
                return APICheckResult(name: "Fiscal.ai (Fundamentals)", status: .ok,
                                      detail: "MSFT connected", latency: latency)
            } else {
                return APICheckResult(name: "Fiscal.ai (Fundamentals)", status: .error,
                                      detail: "No data returned", latency: latency)
            }
        } catch {
            let latency = Date().timeIntervalSince(start)
            return APICheckResult(name: "Fiscal.ai (Fundamentals)", status: .error,
                                  detail: error.localizedDescription, latency: latency)
        }
    }

    private func testFiscalAI() async {
        let symbol = fiscalTestSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return }
        isFiscalTesting = true
        defer { isFiscalTesting = false }

        let key = SecretsConfig.fiscalAIAPIKey
        log("Fiscal.ai key: \(key.isEmpty ? "EMPTY — add FiscalAIAPIKey to Secrets.plist" : String(key.prefix(8)) + "••••")")

        guard !key.isEmpty else {
            log("Fiscal.ai: aborting — no key configured", isError: true)
            return
        }

        do {
            let data = try await APIService.shared.fetchFiscalFundamentals(symbol: symbol)
            var details: [String] = []
            if let mc = data.marketCap, mc > 0 { details.append("MCap: \(fmpFormatBig(mc))") }
            if let pe = data.peRatio, pe > 0 { details.append("P/E: \(String(format: "%.1f", pe))") }
            if let eps = data.eps, eps != 0 { details.append("EPS: \(String(format: "%.2f", eps))") }
            if let beta = data.beta, beta > 0 { details.append("Beta: \(String(format: "%.2f", beta))") }
            if let div = data.dividend, div > 0 { details.append("DivYield: \(String(format: "%.2f%%", div))") }
            if let h = data.week52High, h > 0 { details.append("52WH: \(String(format: "%.2f", h))") }
            if let l = data.week52Low, l > 0 { details.append("52WL: \(String(format: "%.2f", l))") }
            if let rev = data.revenue, rev > 0 { details.append("Rev: \(fmpFormatBig(rev))") }
            if let margin = data.profitMargin { details.append("Margin: \(String(format: "%.1f%%", margin * 100))") }
            if let roe = data.roe { details.append("ROE: \(String(format: "%.1f%%", roe * 100))") }
            if let sector = data.sector, !sector.isEmpty { details.append("Sector: \(sector)") }

            if details.isEmpty {
                log("Fiscal.ai \(symbol): Connected but no data returned — symbol may not be in free tier coverage", isError: true)
            } else {
                log("Fiscal.ai \(symbol): \(details.joined(separator: " | "))")
            }
        } catch {
            log("Fiscal.ai \(symbol): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - OpenAI Test

    private func testOpenAI() async {
        isOpenAITesting = true
        defer { isOpenAITesting = false }

        let key = SecretsConfig.openAIAPIKey
        log("OpenAI key: \(key.isEmpty ? "EMPTY — add OpenAIAPIKey to Secrets.plist" : String(key.prefix(8)) + "••••")")

        guard !key.isEmpty else {
            log("OpenAI: aborting — no key configured", isError: true)
            return
        }

        let aiService = AIAgentService()
        let testMsg = ChatMessage(text: "Reply with exactly: OK", isUser: true)

        do {
            let response = try await aiService.sendMessage(messages: [testMsg])
            log("OpenAI: Response received — \"\(String(response.prefix(100)))\"")
        } catch {
            log("OpenAI: \(error.localizedDescription)", isError: true)
        }
    }

    private func clearAllData() {
        DataPersistenceManager.shared.clearAllData()
        marketData.stocks = []
        marketData.crypto = []
        marketData.portfolio = []
        marketData.watchlist = []
        marketData.newsArticles = []
        log("Cleared all local data")
    }
}

// MARK: - Models

struct APICheckResult: Identifiable {
    enum Status { case ok, badKey, limited, error }

    let id = UUID()
    let name: String
    let status: Status
    let detail: String
    let latency: TimeInterval
    let checkedAt = Date()

    var statusColor: Color {
        switch status {
        case .ok:      return .green
        case .limited: return .orange
        case .badKey:  return .yellow
        case .error:   return .red
        }
    }
}

struct APILogEntry: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
    let timestamp = Date()
}
