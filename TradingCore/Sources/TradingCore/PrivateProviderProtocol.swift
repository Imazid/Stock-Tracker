import Foundation

public enum PrivateProviderProtocol {
    public static func authorizationCode(in url: URL, redirect: URL, state: String) -> String? {
        guard let response = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              response.scheme == target.scheme, response.host == target.host, response.path == target.path,
              response.user == nil, response.password == nil, response.port == nil, response.fragment == nil else { return nil }
        let parameters = response.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = parameters.filter { $0.name == name }
            return matches.count == 1 ? matches.first?.value : nil
        }
        guard value("state") == state, !parameters.contains(where: { $0.name == "error" }),
              let code = value("code"), !code.isEmpty, code.utf8.count <= 2_048 else { return nil }
        return code
    }

    /// Streamable HTTP can return an ordinary JSON body or an SSE message.
    public static func rpcResult(in data: Data, id: Int, contentType: String?) throws -> [String: Any] {
        let bodies: [Data]
        if contentType?.lowercased().hasPrefix("text/event-stream") == true {
            guard let text = String(data: data, encoding: .utf8) else { throw Failure.response }
            bodies = text.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n").compactMap { block in
                    let event = block.split(separator: "\n").compactMap { line -> String? in
                        guard line.hasPrefix("data:") else { return nil }
                        let value = line.dropFirst(5)
                        return String(value.first == " " ? value.dropFirst() : value)
                    }.joined(separator: "\n")
                    return event.isEmpty ? nil : Data(event.utf8)
                }
        } else {
            bodies = [data]
        }
        for body in bodies {
            guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  envelope["jsonrpc"] as? String == "2.0", envelope["id"] as? Int == id else { continue }
            if envelope["error"] != nil { throw Failure.provider }
            if let result = envelope["result"] as? [String: Any] { return result }
        }
        throw Failure.response
    }

    public enum Failure: Error { case response, provider }
}
