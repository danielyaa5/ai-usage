import Foundation
import Network

/// The result of one plain-HTTP read, in the words the test reports.
struct URLCheckOutcome: Codable, Equatable {
    var name: String
    var url: String
    var ok: Bool
    var status: Int?
    var bytes: Int?
    var errorDomain: String?
    var errorCode: Int?
    /// macOS refused because the app may not use the local network (Local Network privacy).
    var localNetworkDenied: Bool
    /// App Transport Security refused the plain-HTTP load (NSURLErrorAppTransportSecurityRequiresSecureConnection).
    var blockedByATS: Bool
    /// The network path macOS attached to the error, when it did (it names "Local network prohibited").
    var path: String?
    var summary: String
    var milliseconds: Int
    var at: Date
}

enum URLCheck {
    /// Reads `url` once with a fresh ephemeral session (no cache, no cookies, no waiting for
    /// connectivity) and describes what happened.
    static func run(name: String, url: URL, timeout: TimeInterval = 8) async -> URLCheckOutcome {
        let started = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var outcome = URLCheckOutcome(name: name, url: url.absoluteString, ok: false, status: nil, bytes: nil,
                                      errorDomain: nil, errorCode: nil, localNetworkDenied: false,
                                      blockedByATS: false, path: nil, summary: "", milliseconds: 0, at: started)
        do {
            var request = URLRequest(url: url)
            request.setValue("AIUsageStoreTest", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            outcome.status = status
            outcome.bytes = data.count
            outcome.ok = status.map { (200..<300).contains($0) } ?? false
            outcome.summary = "HTTP \(status.map(String.init) ?? "?"), \(data.count) bytes"
        } catch {
            describe(error, into: &outcome)
        }
        outcome.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return outcome
    }

    static func describe(_ error: Error, into outcome: inout URLCheckOutcome) {
        let ns = error as NSError
        outcome.errorDomain = ns.domain
        outcome.errorCode = ns.code
        let path = ns.userInfo["_NSURLErrorNWPathKey"].map { String(describing: $0) }
        outcome.path = path.map { String($0.prefix(300)) }
        let text = ([path ?? "", ns.localizedDescription, String(describing: ns.userInfo[NSUnderlyingErrorKey] ?? "")])
            .joined(separator: " ").lowercased()
        outcome.localNetworkDenied = text.contains("local network prohibited") || text.contains("localnetworkdenied")
        outcome.blockedByATS = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection
        if outcome.blockedByATS {
            outcome.summary = "Blocked by App Transport Security (\(ns.code))"
        } else if outcome.localNetworkDenied {
            outcome.summary = "Local network access denied (\(ns.code), \"Local network prohibited\")"
        } else if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
            outcome.summary = "Timed out (\(ns.code))"
        } else if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost {
            outcome.summary = "Nothing answered at that address (\(ns.code))"
        } else {
            outcome.summary = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }
    }


}
