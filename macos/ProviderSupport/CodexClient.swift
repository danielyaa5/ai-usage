import Darwin
import Foundation

/// Runs the bundled `codex app-server` and talks to it the way the dashboard's
/// ai_usage/codex_limits.py does: JSON-RPC over stdin and stdout, one JSON object per line.
/// Requests from the server (approvals and the like) are declined; notifications are passed on.
final class CodexClient: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case notRunning
        case timedOut(String)
        case exited(Int32, String)
        case rpc(String, Int, String)
        case badReply(String)

        var description: String {
            switch self {
            case .notRunning: return "Codex isn't running"
            case .timedOut(let method): return "\(method): no answer in time"
            case .exited(let status, let how): return "Codex exited (\(how) \(status))"
            case .rpc(let method, let code, let message): return "\(method): error \(code): \(message)"
            case .badReply(let text): return "unexpected reply: \(text)"
            }
        }
    }

    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "AIUsage.codex")
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var methods: [Int: String] = [:]
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var exitDescription: String?

    /// Notifications (method, params), on a background queue.
    var onNotification: (@Sendable (String, [String: Any]) -> Void)?
    /// Each line Codex writes to stderr, on a background queue.
    var onStderr: (@Sendable (String) -> Void)?
    /// A request from the server, which the client declines.
    var onServerRequest: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (String) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        // At the end of a stream the handler is called with no data, again and again unless removed.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.consumeOutput(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.consumeErrors(data) }
        }
        process.terminationHandler = { [weak self] process in
            let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
            let text = "\(how) \(process.terminationStatus)"
            self?.queue.async {
                guard let self else { return }
                self.exitDescription = text
                let waiting = self.pending
                self.pending = [:]
                self.methods = [:]
                for (_, finish) in waiting {
                    finish(.failure(Failure.exited(process.terminationStatus, how)))
                }
                self.onExit?(text)
            }
        }
        try process.run()
    }

    /// Sends a request and waits for its result object.
    func request(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            queue.async {
                guard self.process.isRunning, self.exitDescription == nil else {
                    continuation.resume(throwing: Failure.notRunning)
                    return
                }
                let id = self.nextID
                self.nextID += 1
                self.pending[id] = { result in continuation.resume(with: result) }
                self.methods[id] = method
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                if let problem = self.write(message) {
                    self.methods.removeValue(forKey: id)
                    self.pending.removeValue(forKey: id)?(.failure(Failure.badReply(problem)))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.methods.removeValue(forKey: id)
                    self.pending.removeValue(forKey: id)?(.failure(Failure.timedOut(method)))
                }
            }
        }
    }

    func notify(_ method: String, params: [String: Any]? = nil) {
        queue.async {
            var message: [String: Any] = ["method": method]
            if let params { message["params"] = params }
            _ = self.write(message)
        }
    }

    /// How Codex ended when the app stopped it.
    struct Stopped: Sendable, CustomStringConvertible {
        /// "when its input closed", "after SIGTERM", "after SIGKILL" or "not at all".
        var when: String
        /// "status 0", "signal 9" and so on; nil while it still runs.
        var exit: String?
        var seconds: Double

        /// Codex left by itself, with status 0, once its input closed: what a shipped app relies on.
        var clean: Bool { when == "when its input closed" && exit == "status 0" }

        var description: String {
            let time = String(format: "%.1f s", seconds)
            guard let exit else { return "still running \(time) after it was told to stop" }
            return "exited (\(exit)) \(when), after \(time)"
        }
    }

    private static func uncancelledSleep(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(milliseconds)
            ) {
                continuation.resume()
            }
        }
    }

    private var isProcessAlive: Bool {
        let currentPID = process.processIdentifier
        guard currentPID > 0, process.isRunning else { return false }
        return Darwin.kill(currentPID, 0) == 0 || errno == EPERM
    }

    /// Closes stdin (app-server exits at the end of its input), then asks it to stop, then makes it.
    func stop() async -> Stopped {
        let began = Date()
        var when = "when its input closed"
        try? input.fileHandleForWriting.close()
        for _ in 0..<30 where isProcessAlive {
            await Self.uncancelledSleep(milliseconds: 100)
        }
        if isProcessAlive {
            when = "after SIGTERM"
            process.terminate()
            for _ in 0..<20 where isProcessAlive {
                await Self.uncancelledSleep(milliseconds: 100)
            }
        }
        if isProcessAlive {
            when = "after SIGKILL"
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            for _ in 0..<10 where isProcessAlive {
                await Self.uncancelledSleep(milliseconds: 100)
            }
        }
        let seconds = Date().timeIntervalSince(began)
        // Let the last lines Codex wrote arrive before the readers go.
        await Self.uncancelledSleep(milliseconds: 300)
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        guard !process.isRunning else { return Stopped(when: "not at all", exit: nil, seconds: seconds) }
        let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
        return Stopped(when: when, exit: "\(how) \(process.terminationStatus)", seconds: seconds)
    }

    // MARK: - On the queue

    private func write(_ message: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return "couldn't encode" }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            return nil
        } catch {
            return "couldn't write to Codex: \(error.localizedDescription)"
        }
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        outBuffer.append(data)
        while let newline = outBuffer.firstIndex(of: 0x0A) {
            let line = outBuffer[outBuffer.startIndex..<newline]
            outBuffer.removeSubrange(outBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func consumeErrors(_ data: Data) {
        guard !data.isEmpty else { return }
        errBuffer.append(data)
        while let newline = errBuffer.firstIndex(of: 0x0A) {
            let line = errBuffer[errBuffer.startIndex..<newline]
            errBuffer.removeSubrange(errBuffer.startIndex...newline)
            if let text = String(data: Data(line), encoding: .utf8), !text.isEmpty {
                onStderr?(text)
            }
        }
        if errBuffer.count > 64 * 1024 {  // a very long line: pass it on in pieces
            onStderr?(String(decoding: errBuffer, as: UTF8.self))
            errBuffer.removeAll()
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            onStderr?("(stdout, not JSON) " + String(decoding: line.prefix(300), as: UTF8.self))
            return
        }
        let method = object["method"] as? String
        if let method, let rawID = object["id"] {
            // The server asks the client something (an approval, say); this test never agrees.
            onServerRequest?(method)
            _ = write(["id": rawID, "error": ["code": -32601, "message": "Not supported by AI Usage"]])
            return
        }
        if let method {
            onNotification?(method, object["params"] as? [String: Any] ?? [:])
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue, let finish = pending.removeValue(forKey: id) else { return }
        let requestMethod = methods.removeValue(forKey: id) ?? "request \(id)"
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            let message = error["message"] as? String ?? "unknown error"
            finish(.failure(Failure.rpc(requestMethod, code, message)))
        } else if let result = object["result"] as? [String: Any] {
            finish(.success(result))
        } else if object["result"] is NSNull || object["result"] == nil {
            finish(.success([:]))
        } else {
            finish(.success(["value": object["result"] as Any]))
        }
    }
}
