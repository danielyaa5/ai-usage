import Foundation

/// The start of an HTTP/1.1 request, as read by the test listener and the logging proxy.
struct HTTPRequestHead: Sendable {
    var method: String
    var target: String
    var version: String
    /// Header names in lower case.
    var headers: [String: String]
    /// Bytes from the start of the request up to and including the blank line.
    var length: Int

    enum Parse: Sendable {
        case incomplete
        case invalid(String)
        case complete(HTTPRequestHead)
    }

    static let blankLine = Data("\r\n\r\n".utf8)

    static func parse(_ data: Data, limit: Int = 16 * 1024) -> Parse {
        guard let end = data.range(of: blankLine) else {
            return data.count > limit ? .invalid("request head over \(limit) bytes") : .incomplete
        }
        let head = data[data.startIndex..<end.lowerBound]
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return .invalid("request head is not text")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return .invalid("malformed request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = data.distance(from: data.startIndex, to: end.upperBound)
        return .complete(HTTPRequestHead(method: String(parts[0]), target: String(parts[1]),
                                         version: String(parts[2]), headers: headers, length: length))
    }

    /// The path without its query string.
    var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    var contentLength: Int? {
        guard let value = headers["content-length"] else { return 0 }
        return Int(value)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    static func encoded<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let body = (try? StoreTestShared.encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
