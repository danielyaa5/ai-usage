import Foundation

/// Reads `/api/widget` from an AI Usage dashboard.
public enum UsageClient {
    public static let defaultServer = URL(string: "http://localhost:8796/")!

    /// Accepts "my-mac.local:8796", "http://my-mac.local:8796" or a path such as
    /// "http://my-server.local:8088/ai-usage/", and returns it with a scheme and a trailing slash.
    public static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.query = nil
        parts.fragment = nil
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        return parts.url
    }

    public static func endpoint(server: URL, range: String) -> URL {
        var parts = URLComponents(url: server.appendingPathComponent("api/widget"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "range", value: range)]
        return parts.url!
    }

    public static func fetch(server: URL, range: String = "7d", timeout: TimeInterval = 15) async throws -> UsageSummary {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint(server: server, range: range))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.unreachable(server: server, reason: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw UsageError.http(status: status, message: message)
        }
        do {
            return try UsageSummary.decoder.decode(UsageSummary.self, from: data)
        } catch {
            throw UsageError.unexpected(error.localizedDescription)
        }
    }
}

public enum UsageError: LocalizedError, Equatable {
    case unreachable(server: URL, reason: String)
    case http(status: Int, message: String?)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(server, reason):
            return "Can't reach AI Usage at \(server.host ?? server.absoluteString)\(server.port.map { ":\($0)" } ?? ""): \(reason)"
        case .http(404, _):
            return "That server has no /api/widget. Update AI Usage on it (git pull), then restart it."
        case let .http(status, message):
            return "AI Usage answered \(status)" + (message.map { ": \($0)" } ?? "")
        case let .unexpected(reason):
            return "AI Usage sent something unexpected: \(reason)"
        }
    }
}
