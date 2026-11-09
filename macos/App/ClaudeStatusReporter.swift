import Foundation
import AIUsageKit
import Darwin

/// Claude Code invokes the installed app in this mode before SwiftUI starts. It never opens a window.
enum ClaudeStatusReporter {
    static func run(passThrough: Bool) {
        // A custom status line may print a label without reading stdin. Its closed pipe
        // must not terminate the reporter before it has delivered the quota reading.
        var forwardInput = passThrough
        if forwardInput { signal(SIGPIPE, SIG_IGN) }
        let defaults = UserDefaults.standard
        let port = defaults.integer(forKey: "statusPort")
        let token = defaults.string(forKey: "statusToken")
        var canReport = defaults.bool(forKey: "claudeStatusLine") && (1...65535).contains(port) && token != nil
        var input = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 32_768), !chunk.isEmpty {
            if forwardInput {
                do { try FileHandle.standardOutput.write(contentsOf: chunk) }
                catch { forwardInput = false }
            }
            if canReport {
                if chunk.count <= 1_048_576 - input.count { input.append(chunk) }
                else { canReport = false; input.removeAll() }
            }
        }
        guard canReport, let token, let payload = ClaudeStatusReading.payload(from: input) else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/claude-status")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-AI-Usage-Token")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                            "ExceptionsList": ["127.0.0.1"], "ExcludeSimpleHostnames": 1,
                                            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let session = URLSession(configuration: config, delegate: LocalRequest(), delegateQueue: nil)
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 0.75)
        session.invalidateAndCancel()
    }

    private final class LocalRequest: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
