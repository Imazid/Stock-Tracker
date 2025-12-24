//
//  AIAgentService.swift
//  Stock Tracker
//
//  Updated for OpenAI ChatGPT API (GPT-4o / GPT-4o-mini)
//

import Foundation
import Combine

class AIAgentService: ObservableObject {
    // Get your key from: https://platform.openai.com/api-keys
    private let apiKey = "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"  // ← Replace this!
    
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    /// Sends a conversation to ChatGPT and returns the assistant's reply
    func sendMessage(messages: [ChatMessage]) async throws -> String {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        let openAIMessages = messages.map { msg in
            OpenAIMessage(
                role: msg.isUser ? "user" : "assistant",
                content: msg.text
            )
        }
        
        let requestBody = OpenAIRequest(
            model: "gpt-4o-mini",  // ← Fast & cheap. Use "gpt-4o" for max intelligence
            messages: openAIMessages,
            temperature: 0.7,
            max_tokens: 1024
        )
        
        guard let url = URL(string: baseURL) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Handle HTTP errors
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("OpenAI Error Response: \(errorString)")
            }
            throw URLError(.badServerResponse)
        }
        
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        
        guard let content = decoded.choices.first?.message.content else {
            return "No response from AI."
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OpenAI Request/Response Models
struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    let max_tokens: Int
}

struct OpenAIMessage: Codable {
    let role: String  // "user", "assistant", or "system"
    let content: String
}

struct OpenAIResponse: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let message: OpenAIMessage
    }
}
