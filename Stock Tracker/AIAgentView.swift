//
//  AIAgentView.swift
//  Stock Tracker
//

import SwiftUI
import AVFoundation
import Speech
import Combine

// MARK: - Supporting Structs and Classes

struct EnhancedChatBubble: View {
    let message: ChatMessage

    @Environment(\.colorScheme) var colorScheme
    @State private var showTime = false

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(alignment: .bottom) {
            if !message.isUser {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundColor(.purple)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(16)
                    .background(
                        message.isUser ?
                            LinearGradient(colors: [.blue, .blue.opacity(0.8)], startPoint: .top, endPoint: .bottom) :
                            LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                    )
                    .foregroundColor(message.isUser ? .white : theme.primaryText)
                    .cornerRadius(20, corners: message.isUser ? [.topLeft, .bottomLeft, .bottomRight] : [.topRight, .bottomLeft, .bottomRight])
                    .onTapGesture { showTime.toggle() }

                if showTime {
                    Text(Date().formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .frame(maxWidth: 300, alignment: message.isUser ? .trailing : .leading)

            if message.isUser {
                Spacer(minLength: 0)
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.isUser ? "You said: \(message.text)" : "AI said: \(message.text)")
    }
}

struct TypingIndicator: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var dots = ""

    var body: some View {
        let _ = Theme(colorScheme: colorScheme)
        HStack {
            Text("AI is typing\(dots)")
                .font(.caption)
                .foregroundColor(.gray)
                .onAppear {
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                        dots = dots.count < 3 ? dots + "." : ""
                    }
                }
            
            Spacer()
        }
    }
}

//struct RoundedCorner: Shape {
//    var radius: CGFloat = .infinity
//    var corners: UIRectCorner = .allCorners
//    
//    func path(in rect: CGRect) -> Path {
//        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
//        return Path(path.cgPath)
//    }
//}
//
//extension View {
//    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
//        clipShape(RoundedCorner(radius: radius, corners: corners))
//    }
//}

class SpeechRecognizer: NSObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }
    
    func startRecording(completion: @escaping (String) -> Void) {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                completion(result.bestTranscription.formattedString)
            }
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
    }
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }
}

struct AIAgentView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @State private var userInput = ""
    @State private var messages: [ChatMessage] = [
        ChatMessage(text: "Hi! I'm your AI investing assistant. Ask me about your portfolio, watchlist, stocks, or market trends.", isUser: false)
    ]
    @State private var isTyping = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showSuggestions = true
    @State private var isRecording = false
    @EnvironmentObject var insightService: AIInsightService

    let speechRecognizer = SpeechRecognizer()

    /// Max queries allowed for the current tier today. nil = unlimited.
    private var dailyLimit: Int? {
        FeatureGate.aiDailyQueryLimit(for: subscriptionManager.currentTier)
    }

    private var todayQueryCount: Int {
        insightService.todayQueryCount
    }

    private var isAtDailyLimit: Bool {
        !insightService.canQuery(tier: subscriptionManager.currentTier)
    }

    var body: some View {
        Group {
            if subscriptionManager.currentTier == .free {
                AIAgentLockedView()
                    .environmentObject(subscriptionManager)
            } else {
                chatView
            }
        }
    }

    private var chatView: some View {
        let theme = Theme(colorScheme: colorScheme)
        return ZStack {
            LinearGradient(gradient: Gradient(colors: [theme.background, .purple.opacity(0.1), theme.background]), startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Daily usage banner for Pro tier
                if let limit = dailyLimit, limit > 0 {
                    queryCountBanner(used: todayQueryCount, limit: limit, theme: theme)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(messages) { message in
                                EnhancedChatBubble(message: message)
                                    .id(message.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            if isTyping {
                                TypingIndicator()
                                    .padding(.leading)
                            }
                        }
                        .padding()
                        .onAppear { scrollProxy = proxy }
                        .onChange(of: messages.count) { _ in
                            withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                        }
                    }
                }

                if showSuggestions && messages.count == 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(suggestedPrompts, id: \.self) { prompt in
                                Button(prompt) {
                                    userInput = prompt
                                    sendMessage()
                                    showSuggestions = false
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(theme.primaryText)
                                .cornerRadius(20)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 40)
                }

                // Limit reached notice
                if isAtDailyLimit {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Daily limit reached. Upgrade to Black for unlimited access.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                }

                HStack(spacing: 12) {
                    TextField("Ask me anything...", text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(theme.separator)
                        .cornerRadius(20)
                        .lineLimit(1...5)
                        .disabled(isAtDailyLimit)

                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.title2)
                            .foregroundColor(isRecording ? .red : .gray)
                    }
                    .disabled(isAtDailyLimit)
                    .accessibilityLabel(isRecording ? "Stop recording" : "Start voice input")
                    .accessibilityHint(isRecording ? "Tap to stop recording and send" : "Tap to start speaking your question")

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.title2)
                            .foregroundColor(userInput.isEmpty || isAtDailyLimit ? .gray : .blue)
                    }
                    .disabled(userInput.isEmpty || isAtDailyLimit)
                    .accessibilityLabel("Send message")
                    .accessibilityHint(userInput.isEmpty ? "Type a message first" : "Sends your message to the AI assistant")
                }
                .padding()
                .background(theme.background.opacity(0.9))
            }
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    messages = [messages.first!]
                    showSuggestions = true
                }
                .foregroundColor(theme.primaryText)
            }
        }
        .onAppear {
            speechRecognizer.requestAuthorization()
        }
    }

    @ViewBuilder
    private func queryCountBanner(used: Int, limit: Int, theme: Theme) -> some View {
        let remaining = max(0, limit - used)
        let fraction = Double(used) / Double(limit)
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundColor(.purple)
            Text("\(remaining) queries remaining today")
                .font(.caption.weight(.medium))
                .foregroundColor(remaining == 0 ? .orange : theme.primaryText)
            Spacer()
            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.purple.opacity(0.12)).frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: [.purple, remaining == 0 ? .orange : .blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * fraction), height: 4)
                }
            }
            .frame(width: 60, height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }

    private let suggestedPrompts = [
        "Summarize my portfolio",
        "Analyze my watchlist",
        "What's the market outlook?",
        "Recommend diversification"
    ]
    
    private func sendMessage() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAtDailyLimit else { return }

        insightService.incrementQueryCount()
        messages.append(ChatMessage(text: trimmed, isUser: true))
        userInput = ""
        isTyping = true

        Task {
            do {
                let systemPrompt = buildSystemPrompt()
                let systemMessage = ChatMessage(text: systemPrompt, isUser: false)

                let fullMessages = [systemMessage] + messages

                let response = try await aiService.sendMessage(messages: fullMessages)
                messages.append(ChatMessage(text: response, isUser: false))
            } catch {
                messages.append(ChatMessage(text: "Error: \(error.localizedDescription)", isUser: false))
            }
            isTyping = false
        }
    }
    
    private func buildSystemPrompt() -> String {
        // SECURITY: Only send anonymized/aggregated data to external AI service.
        // Do NOT send exact share counts, cost basis, or exact portfolio values.
        let watchlistSymbols = marketData.watchlist.map { $0.symbol }.joined(separator: ", ")

        // Send only symbols and approximate allocation percentages (no exact values)
        let totalValue = marketData.totalPortfolioValue
        let portfolioSummary: String
        if totalValue > 0 {
            portfolioSummary = marketData.portfolio.map { holding in
                let pct = (holding.currentValue / totalValue) * 100
                return "\(holding.asset.symbol) (~\(Int(pct))%)"
            }.joined(separator: ", ")
        } else {
            portfolioSummary = "Empty"
        }

        return """
        You are a helpful AI investing assistant. The user tracks the following:
        - Watchlist symbols: \(watchlistSymbols.isEmpty ? "None" : watchlistSymbols)
        - Portfolio allocation: \(portfolioSummary)
        Do not give financial advice; provide general analysis only. Be concise and helpful.
        """
    }
    
    private let aiService = AIAgentService()
    
    private func toggleRecording() {
        if isRecording {
            speechRecognizer.stopRecording()
            isRecording = false
        } else {
            speechRecognizer.startRecording { transcript in
                userInput = transcript
                sendMessage()
            }
            isRecording = true
        }
    }
}

#Preview {
    AIAgentView()
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}
