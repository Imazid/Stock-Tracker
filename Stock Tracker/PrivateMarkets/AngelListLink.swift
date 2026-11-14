import AuthenticationServices
import CryptoKit
import Foundation
import Security
import TradingCore
import UIKit

@MainActor
final class AngelListLink: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AngelListLink()

    struct Records {
        let text: String
        let statements: [PrivateFundSnapshot.Record]
        let connectionID: String
    }

    struct Tool: Identifiable {
        struct Field: Identifiable {
            let id: String
            let title: String
            let detail: String?
            let type: String
            let required: Bool
        }
        let id: String
        let title: String
        let description: String
        let fields: [Field]
    }

    private struct Registration: Decodable { let client_id: String }
    private struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let token_type: String
        let expires_in: Double?
    }
    private struct Connection: Codable {
        let clientID: String
        let access: String
        let refresh: String?
        let expiresAt: Date
    }
    enum Failure: LocalizedError {
        case presentation, redirect, unavailable, authorization, storage, unsupported, arguments, disconnected
        var errorDescription: String? {
            switch self {
            case .presentation: "The AngelList sign-in window could not open."
            case .redirect: "The AngelList sign-in response could not be verified."
            case .unavailable: "AngelList Link is unavailable. Try again."
            case .authorization: "AngelList access expired or was declined. Reconnect to continue."
            case .storage: "The AngelList connection could not be stored in Keychain."
            case .unsupported: "AngelList returned a response this app cannot read."
            case .arguments: "Check the required fields and the formats supplied by AngelList."
            case .disconnected: "Connect your AngelList account first."
            }
        }
    }

    private static let auth = URL(string: "https://auth.angellist.com")!
    private static let endpoint = URL(string: "https://mcp.angellist.com/mcp")!
    private static let resource = "https://mcp.angellist.com"
    private static let redirect = URL(string: "stocktracker://angellist-oauth")!
    private static let scopes = "firms:read vehicles:read capital_accounts:read capital_calls:read distributions:read valuation_updates:read"
    private static let protocolVersion = "2025-06-18"
    private let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration, delegate: AngelListNoRedirect(), delegateQueue: nil)
    }()
    private var browser: ASWebAuthenticationSession?
    private var refreshing: [UUID: Task<Connection, Error>] = [:]
    private var disconnecting: Set<UUID> = []

    func isConnected(_ owner: UUID) -> Bool { connection(owner) != nil }

    func isCurrentConnection(_ id: String, owner: UUID) -> Bool {
        !disconnecting.contains(owner) && connection(owner)?.clientID == id
    }

    func connect(_ owner: UUID, stillSignedIn: () -> Bool) async throws {
        guard !disconnecting.contains(owner) else { throw Failure.disconnected }
        let (data, _) = try await request(Self.auth.appendingPathComponent("oauth/register"), json: [
            "client_name": "Stock Tracker",
            "redirect_uris": [Self.redirect.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": Self.scopes
        ])
        let registration = try JSONDecoder().decode(Registration.self, from: data)
        let state = try randomValue()
        let verifier = try randomValue()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var url = URLComponents(url: Self.auth.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)
        else { throw Failure.presentation }
        url.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: registration.client_id),
            .init(name: "redirect_uri", value: Self.redirect.absoluteString), .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: Self.resource)
        ]
        guard let authorizationURL = url.url else { throw Failure.presentation }
        let callback = try await authenticate(authorizationURL)
        guard stillSignedIn(), let code = PrivateProviderProtocol.authorizationCode(in: callback, redirect: Self.redirect, state: state)
        else { throw Failure.redirect }
        let credential = try await token(clientID: registration.client_id, fields: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect.absoluteString,
            "code_verifier": verifier
        ])
        guard stillSignedIn(), !disconnecting.contains(owner) else { throw Failure.disconnected }
        try save(credential, owner: owner)
    }

    func disconnect(_ owner: UUID) async throws {
        guard disconnecting.insert(owner).inserted else { throw Failure.disconnected }
        defer { disconnecting.remove(owner) }
        _ = try? await refreshing[owner]?.value
        guard let active = connection(owner) else { return }
        // Revoke the refresh token last. If either request fails, a retry still has the token.
        if active.expiresAt > .now {
            _ = try await request(Self.auth.appendingPathComponent("token/revoke"), form: [
                "client_id": active.clientID, "token": active.access, "token_type_hint": "access_token"
            ])
        }
        if let refresh = active.refresh {
            _ = try await request(Self.auth.appendingPathComponent("token/revoke"), form: [
                "client_id": active.clientID, "token": refresh, "token_type_hint": "refresh_token"
            ])
        }
        guard KeychainManager.shared.delete(key: key(owner)) else { throw Failure.storage }
    }

    func forgetDeletedAccount(_ owner: UUID) -> Bool {
        KeychainManager.shared.delete(key: key(owner))
    }

    func tools(_ owner: UUID) async throws -> [Tool] {
        try await withSession(owner) { headers, _ in
            var result: [Tool] = []
            var cursor: String?
            for page in 0..<5 {
                let listed = try await rpc("tools/list", id: page + 2, parameters: cursor.map { ["cursor": $0] } ?? [:], headers: headers).0
                guard let tools = listed["tools"] as? [[String: Any]] else { throw Failure.unsupported }
                result += tools.compactMap { tool in
                    guard let name = tool["name"] as? String, readTool(name, tool: tool),
                          let schema = tool["inputSchema"] as? [String: Any] else { return nil }
                    let required = Set(schema["required"] as? [String] ?? [])
                    let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
                    guard required.isSubset(of: Set(properties.keys)) else { return nil }
                    let fields = properties.keys.sorted().compactMap { key -> Tool.Field? in
                        guard let property = properties[key] else { return nil }
                        return .init(id: key, title: property["title"] as? String ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                                     detail: property["description"] as? String, type: property["type"] as? String ?? "json",
                                     required: required.contains(key))
                    }
                    return Tool(id: name, title: tool["title"] as? String ?? name.replacingOccurrences(of: "_", with: " ").capitalized,
                                description: tool["description"] as? String ?? "", fields: fields)
                }
                cursor = listed["nextCursor"] as? String
                if cursor == nil { break }
            }
            var used = Set<String>()
            return result.filter { used.insert($0.id).inserted }
        }
    }

    func call(_ tool: Tool, arguments: [String: String], owner: UUID) async throws -> Records {
        var params: [String: Any] = [:]
        for field in tool.fields {
            let raw = arguments[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                guard !field.required else { throw Failure.arguments }
                continue
            }
            guard raw.utf8.count <= 8_000 else { throw Failure.arguments }
            if field.type == "string" {
                params[field.id] = raw
            } else {
                guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) else {
                    throw Failure.arguments
                }
                params[field.id] = value
            }
        }
        return try await withSession(owner) { headers, connectionID in
            let result = try await rpc("tools/call", id: 2, parameters: ["name": tool.id, "arguments": params], headers: headers).0
            guard result["isError"] as? Bool != true else { throw Failure.arguments }
            let contents = (result["content"] as? [[String: Any]] ?? []).compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }
            let structured = result["structuredContent"].flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys])
            }
            let display = structured.flatMap { String(data: $0, encoding: .utf8) } ?? contents.joined(separator: "\n\n")
            guard !display.isEmpty else { throw Failure.unsupported }
            let canImport = tool.id == "get_capital_account" || tool.id == "list_capital_accounts"
            return Records(text: display,
                           statements: canImport ? PrivateFundSnapshot.statementRecords(structured: structured, text: contents) : [],
                           connectionID: connectionID)
        }
    }

    private func readTool(_ name: String, tool: [String: Any]) -> Bool {
        let allowed = ["firm", "vehicle", "fund", "capital_account", "capital_call", "distribution", "valuation_update"]
        let terms = name.lowercased()
        let annotations = tool["annotations"] as? [String: Any]
        guard annotations?["readOnlyHint"] as? Bool != false,
              ["get", "list", "find", "search", "read"].contains(where: { terms.hasPrefix($0 + "_") }),
              allowed.contains(where: { terms.contains($0) }) else { return false }
        return !["document", "download", "partner", "subscription"].contains(where: { terms.contains($0) })
    }

    private func withSession<T>(_ owner: UUID, operation: ([String: String], String) async throws -> T) async throws -> T {
        let active = try await freshConnection(owner)
        guard !disconnecting.contains(owner) else { throw Failure.disconnected }
        var headers = ["Authorization": "Bearer " + active.access, "Accept": "application/json, text/event-stream"]
        let (server, response) = try await rpc("initialize", id: 1, parameters: [
            "protocolVersion": Self.protocolVersion, "capabilities": [:],
            "clientInfo": ["name": "Stock Tracker", "version": "1.0"]
        ], headers: headers)
        guard let version = server["protocolVersion"] as? String,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw Failure.unsupported }
        headers["MCP-Protocol-Version"] = version
        headers["Mcp-Session-Id"] = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        _ = try await request(Self.endpoint, json: ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: headers)
        do {
            let value = try await operation(headers, active.clientID)
            if headers["Mcp-Session-Id"] != nil { _ = try? await request(Self.endpoint, method: "DELETE", headers: headers) }
            return value
        } catch {
            if headers["Mcp-Session-Id"] != nil { _ = try? await request(Self.endpoint, method: "DELETE", headers: headers) }
            throw error
        }
    }

    private func rpc(_ method: String, id: Int, parameters: [String: Any], headers: [String: String]) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(Self.endpoint, json: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": parameters
        ], headers: headers)
        do {
            return (try PrivateProviderProtocol.rpcResult(in: data, id: id,
                                                          contentType: response.value(forHTTPHeaderField: "Content-Type")), response)
        } catch { throw Failure.unsupported }
    }

    private func authenticate(_ url: URL) async throws -> URL {
        guard browser == nil else { throw Failure.presentation }
        defer { browser = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirect.scheme) { response, error in
                if let response { continuation.resume(returning: response) }
                else { continuation.resume(throwing: error ?? Failure.presentation) }
            }
            browser = session
            session.presentationContextProvider = self
            if !session.start() { continuation.resume(throwing: Failure.presentation) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    private func freshConnection(_ owner: UUID) async throws -> Connection {
        guard !disconnecting.contains(owner) else { throw Failure.disconnected }
        guard let existing = connection(owner) else { throw Failure.disconnected }
        if existing.expiresAt.timeIntervalSinceNow > 60 { return existing }
        guard let refresh = existing.refresh else { throw Failure.authorization }
        if let pending = refreshing[owner] { return try await pending.value }
        let pending = Task {
            let renewed = try await token(clientID: existing.clientID,
                                          fields: ["grant_type": "refresh_token", "refresh_token": refresh], oldRefresh: refresh)
            try save(renewed, owner: owner)
            return renewed
        }
        refreshing[owner] = pending
        defer { refreshing[owner] = nil }
        return try await pending.value
    }

    private func token(clientID: String, fields: [String: String], oldRefresh: String? = nil) async throws -> Connection {
        let (data, _) = try await request(Self.auth.appendingPathComponent("token"), form: fields.merging([
            "client_id": clientID, "resource": Self.resource
        ]) { original, _ in original })
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        let expires = tokens.expires_in ?? 300
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty,
              expires.isFinite, expires > 0 else { throw Failure.authorization }
        return Connection(clientID: clientID, access: tokens.access_token, refresh: tokens.refresh_token ?? oldRefresh,
                          expiresAt: Date.now.addingTimeInterval(expires))
    }

    private func request(_ url: URL, method: String = "POST", json: [String: Any]? = nil, form: [String: String]? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            request.httpBody = Data(form.sorted(by: { $0.key < $1.key }).map {
                $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await transport.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        if [400, 401, 403].contains(http.statusCode) { throw Failure.authorization }
        guard (200..<300).contains(http.statusCode) else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw Failure.unavailable }
            data.append(byte)
        }
        return (data, http)
    }

    private func key(_ owner: UUID) -> String { "stocktracker.private.angellist." + owner.uuidString }
    private func connection(_ owner: UUID) -> Connection? {
        guard let data = KeychainManager.shared.retrieveData(key: key(owner)) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }
    private func save(_ connection: Connection, owner: UUID) throws {
        let data = try JSONEncoder().encode(connection)
        guard KeychainManager.shared.saveData(key: key(owner), value: data) else { throw Failure.storage }
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.presentation }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class AngelListNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
