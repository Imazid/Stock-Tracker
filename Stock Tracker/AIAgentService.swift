//
//  AIAgentService.swift
//  Stock Tracker
//
//  SECURITY: Rate-limited, input-sanitized, no sensitive data logging.
//

import Foundation
import Combine

class AIAgentService: ObservableObject {
    #if DEBUG
    // Direct provider keys exist only in Debug builds (local development without a server).
    private var openAIKey: String { SecretsConfig.openAIAPIKey }
    private var geminiKey: String { SecretsConfig.geminiAPIKey }
    #endif

    private let openAIBaseURL = "https://api.openai.com/v1/chat/completions"

    /// Gemini model. `gemini-2.0-flash` was retired (HTTP 404 "no longer available", verified
    /// 2026-10-16), which made every Gemini call fail and silently fall through to OpenAI.
    /// The `-latest` alias tracks Google's current Flash release so a future retirement
    /// doesn't break the app again; pin a versioned id here if you need stable output.
    private static let geminiModel = "gemini-flash-latest"
    private let secureSession = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 60)

    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Disabled after receiving `insufficient_quota` — no point retrying a dead key
    private var openAIDisabled = false

    /// Sends a conversation. Release builds always go through the `ai-proxy` Edge Function,
    /// which holds the provider keys and enforces limits; Debug builds call Gemini/OpenAI
    /// directly only while no Supabase project is configured.
    /// `purpose` picks the server's output budget: "chat", "insight" or "copilot".
    func sendMessage(messages: [ChatMessage], purpose: String = "chat") async throws -> String {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if SecureBackend.shouldUseServer {
            return try await sendViaServer(messages: messages, purpose: purpose)
        }

        #if DEBUG
        return try await sendDirect(messages: messages)
        #else
        throw URLError(.userAuthenticationRequired)
        #endif
    }

    // MARK: - Server (ai-proxy)

    private func sendViaServer(messages: [ChatMessage], purpose: String) async throws -> String {
        struct Reply: Decodable { let text: String }
        let payload: [[String: String]] = messages.map { msg in
            let role = msg.role ?? (msg.isUser ? "user" : "assistant")
            return ["role": role, "content": msg.isUser ? InputSanitizer.sanitizeForAPI(msg.text) : msg.text]
        }
        do {
            let data = try await SecureBackend.invoke("ai-proxy", body: ["purpose": purpose, "messages": payload])
            return try JSONDecoder().decode(Reply.self, from: data).text
        } catch let error as SecureBackend.FunctionError {
            switch error.code {
            case "AI_DAILY_QUOTA_EXCEEDED":
                errorMessage = "You've reached today's AI limit. It resets at midnight UTC."
            case "AI_UPSTREAM":
                errorMessage = "AI providers are busy. Please wait a minute and try again."
            default:
                errorMessage = error.message
            }
            SecureLogger.error("ai-proxy \(error.status) \(error.code)")
            throw error
        }
    }

    // MARK: - Direct (Debug builds without a server)

    #if DEBUG
    private func sendDirect(messages: [ChatMessage]) async throws -> String {
        // Try Gemini first — 15 RPM free tier is more generous than OpenAI
        if !geminiKey.isEmpty {
            do {
                return try await sendViaGemini(messages: messages)
            } catch {
                SecureLogger.error("Gemini failed, attempting OpenAI fallback")
            }
        }

        // Fallback to OpenAI (skipped if quota is exhausted)
        if !openAIKey.isEmpty && !openAIDisabled {
            do {
                return try await sendViaOpenAI(messages: messages)
            } catch {
                // Check if the response was an insufficient_quota error
                SecureLogger.error("OpenAI fallback also failed")
                // Record a 60s cooldown on Gemini so the next insight waits
                let limiter = APIRateLimiter.shared
                await limiter.recordRetryAfter(for: "gemini", delay: 60)
                errorMessage = "AI providers are rate-limited. Please wait a minute and try again."
                throw error
            }
        }

        errorMessage = "No AI provider configured. Configure the Supabase project (ai-proxy), or add a key to Secrets.plist for a Debug build."
        throw URLError(.userAuthenticationRequired)
    }

    // MARK: - OpenAI

    private func sendViaOpenAI(messages: [ChatMessage]) async throws -> String {
        let openAIMessages = messages.map { msg in
            let role = msg.role ?? (msg.isUser ? "user" : "assistant")
            return OpenAIMessage(
                role: role,
                content: msg.isUser ? InputSanitizer.sanitizeForAPI(msg.text) : msg.text
            )
        }

        let requestBody = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: openAIMessages,
            temperature: 0.7,
            max_tokens: 1024
        )

        guard let url = URL(string: openAIBaseURL) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await secureSession.rateLimitedData(
            for: request, endpoint: "openAI", config: .openAI
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            SecureLogger.error("OpenAI HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            if body.contains("insufficient_quota") {
                openAIDisabled = true
                SecureLogger.warning("OpenAI quota exhausted — disabling for this session")
            }
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            return "No response from AI."
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Gemini

    private func sendViaGemini(messages: [ChatMessage]) async throws -> String {
        let geminiURL = "https://generativelanguage.googleapis.com/v1beta/models/\(Self.geminiModel):generateContent"
        guard let url = URL(string: geminiURL) else { throw URLError(.badURL) }

        // Separate system instruction from conversation
        let systemMessages = messages.filter { $0.role == "system" }
        let conversationMessages = messages.filter { $0.role != "system" }

        let contents = conversationMessages.map { msg -> GeminiContent in
            let role = msg.isUser ? "user" : "model"
            let text = msg.isUser ? InputSanitizer.sanitizeForAPI(msg.text) : msg.text
            return GeminiContent(role: role, parts: [GeminiPart(text: text)])
        }

        var requestBody = GeminiRequest(contents: contents)
        if let systemText = systemMessages.first?.text, !systemText.isEmpty {
            requestBody.systemInstruction = GeminiContent(role: "user", parts: [GeminiPart(text: systemText)])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header auth instead of `?key=` keeps the key out of URLs and URL logging.
        request.setValue(geminiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await secureSession.rateLimitedData(
            for: request, endpoint: "gemini", config: .gemini
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            SecureLogger.error("Gemini HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        // Current Gemini models are "thinking" models: a candidate can carry several parts
        // (some with only a thoughtSignature), so join every text part instead of taking the first.
        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            SecureLogger.error("Gemini returned no text (finishReason: \(decoded.candidates?.first?.finishReason ?? "nil"))")
            throw URLError(.cannotParseResponse)
        }
        return text
    }
#endif
}

// MARK: - OpenAI Request/Response Models
struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    let max_tokens: Int
}

struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: OpenAIMessage
    }
}

// MARK: - Gemini Request/Response Models

struct GeminiPart: Codable {
    let text: String
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    var systemInstruction: GeminiContent?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
    }
}

struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]?

    struct GeminiCandidate: Codable {
        let content: GeminiResponseContent?
        let finishReason: String?
    }

    /// Response-side content: parts may omit `text` (e.g. thought-signature-only parts),
    /// and `parts` itself is absent when the output budget is spent on thinking.
    struct GeminiResponseContent: Codable {
        let parts: [GeminiResponsePart]?
    }

    struct GeminiResponsePart: Codable {
        let text: String?
    }
}
