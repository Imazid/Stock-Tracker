//
//  AIAgentView.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 21/12/2025.
//


//
//  AIAgentView.swift
//  Stock Tracker
//

import SwiftUI

struct AIAgentView: View {
    @State private var userInput = ""
    @State private var messages: [ChatMessage] = [
        ChatMessage(text: "Hi! I'm your AI investing assistant. Ask me about stocks, portfolio strategy, market news, or anything finance-related.", isUser: false)
    ]
    @State private var isTyping = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages List
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                    }
                    
                    if isTyping {
                        TypingIndicator()
                    }
                }
                .padding()
            }
            
            // Input Bar
            HStack(spacing: 12) {
                TextField("Ask me anything...", text: $userInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(20)
                    .lineLimit(1...5)
                
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                        .foregroundColor(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .blue)
                }
                .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color.black)
        }
        .background(Color.black)
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private let aiService = AIAgentService()

    private func sendMessage() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Add user message
        messages.append(ChatMessage(text: trimmed, isUser: true))
        userInput = ""
        isTyping = true
        
        Task {
            do {
                let response = try await aiService.sendMessage(messages: messages)
                await MainActor.run {
                    isTyping = false
                    messages.append(ChatMessage(text: response, isUser: false))
                }
            } catch {
                await MainActor.run {
                    isTyping = false
                    let errorText = "Sorry, something went wrong: \(error.localizedDescription)"
                    messages.append(ChatMessage(text: errorText, isUser: false))
                }
            }
        }
    }
    
    private func generateAIResponse(to userMessage: String) -> String {
        // Simple placeholder responses — replace with real AI API later
        let lower = userMessage.lowercased()
        
        if lower.contains("aapl") || lower.contains("apple") {
            return "AAPL is currently trading at $273.69, up 0.90% today. It's near its 52-week high with strong institutional support. Analysts rate it as a Buy with an average target of $290."
        } else if lower.contains("portfolio") {
            return "Your portfolio is well-diversified across tech and consumer stocks. Consider adding some defensive assets like utilities or bonds if you're concerned about market volatility."
        } else if lower.contains("buy") || lower.contains("sell") {
            return "I can't give personalized investment advice, but I can help analyze fundamentals, technicals, or news sentiment for any stock you're considering."
        } else {
            return "That's an interesting question! I can help with stock analysis, market trends, portfolio insights, or explaining financial concepts. What would you like to know?"
        }
    }
}

// MARK: - Chat Models
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

// MARK: - Chat Bubble
struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            
            Text(message.text)
                .padding(14)
                .background(message.isUser ? Color.blue : Color.white.opacity(0.15))
                .foregroundColor(message.isUser ? .white : .white)
                .cornerRadius(18)
                .frame(maxWidth: 280, alignment: message.isUser ? .trailing : .leading)
            
            if !message.isUser { Spacer() }
        }
    }
}

// MARK: - Typing Indicator
struct TypingIndicator: View {
    @State private var dots = ""
    
    var body: some View {
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

#Preview {
    NavigationStack {
        AIAgentView()
    }
    .preferredColorScheme(.dark)
}
