//
//  AIAgentService.swift
//  Stock Tracker
//

import Foundation

class AIAgentService: ObservableObject {
    private let apiKey = "YOUR_XAI_API_KEY_HERE"  // Store securely (Keychain or env)
    private let baseURL = "https://api.x.ai/v1/chat/completions"
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    func sendMessage(messages: [ChatMessage]) async throws -> String {
        isLoading = true
        errorMessage = nil
        
        let requestBody = GrokRequest(
            model: "grok-4",  // or "grok-3" for free tier
            messages: messages.map { GrokMessage(role: $0.isUser ? "user" : "assistant", content: $0.text) },
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
        
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }
        
        let decoded = try JSONDecoder().decode(GrokResponse.self, from: data)
        isLoading = false
        
        return decoded.choices.first?.message.content ?? "No response"
    }
}

// MARK: - Request/Response Models
struct GrokRequest: Codable {
    let model: String
    let messages: [GrokMessage]
    let temperature: Double
    let max_tokens: Int
}

struct GrokMessage: Codable {
    let role: String
    let content: String
}

struct GrokResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}