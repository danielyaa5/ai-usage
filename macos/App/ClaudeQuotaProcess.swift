#if CLAUDE_QUOTA_TEST
import AIUsageKit
import AppKit

/// Test builds alone embed the original provider-signed executable. The app never handles its tokens.
enum ClaudeQuotaProcess {
    enum Failure: Error { case helper, timeout, unreadable, signIn }
    private struct TrackedProcess {
        let process: Process
        let identity: SubprocessReaper.Identity?
    }

    private static let processLock = NSLock()
    private static var activeProcesses = [Int32: TrackedProcess]()

    static func stopAll() {
        let tracked = processLock.withLock { () -> [TrackedProcess] in
            let values = Array(activeProcesses.values)
            activeProcesses.removeAll()
            return values
        }
        for entry in tracked {
            let pid = entry.process.processIdentifier
            if pid > 0, SubprocessReaper.isAlive(pid: pid, identity: entry.identity) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private enum Operation { case read, login, status }
    private struct Result {
        var payload: Data?
        var status: Int32 = -1
    }

    static func read(privateProfile: Bool) async throws -> [LimitWindow] {
        let result = try await run(.read, privateProfile: privateProfile)
        guard let payload = result.payload else { throw Failure.unreadable }
        return try ClaudeQuotaReply.windows(payload, now: Date())
    }

    static func signedIn(privateProfile: Bool) async throws -> Bool {
        try await run(.status, privateProfile: privateProfile).status == 0
    }

    static func login() async throws {
        guard try await run(.login, privateProfile: true).status == 0 else { throw Failure.signIn }
    }

    private static func run(_ operation: Operation, privateProfile: Bool) async throws -> Result {
        let hardLimit: Double = operation == .login ? 305 : 30
        do {
            return try await BoundedTask.withTimeout(
                seconds: hardLimit,
                onTimeout: { Self.stopAll() }
            ) {
                try await Self.execute(operation, privateProfile: privateProfile)
            }
        } catch is BoundedTask.TimeoutError {
            throw Failure.timeout
        }
    }

    private static func execute(_ operation: Operation, privateProfile: Bool) async throws -> Result {
        let process = Process()
        let input = Pipe()
        let output: Pipe? = operation == .read ? Pipe() : nil
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claude")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.helper }
        let temporary = FileManager.default.temporaryDirectory
        process.executableURL = executable
        process.currentDirectoryURL = temporary
        let inherited = ProcessInfo.processInfo.environment
        var env = inherited.filter { ["HOME", "PATH", "LANG", "TMPDIR", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
        env["CLAUDE_CODE_TMPDIR"] = temporary.path
        env["TMPDIR"] = temporary.path
        env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        if privateProfile {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let profile = support.appendingPathComponent("ClaudeQuotaProfile", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            env["CLAUDE_CONFIG_DIR"] = profile.path
        }
        let id = UUID().uuidString
        switch operation {
        case .read:
            process.arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                                 "--verbose", "--no-session-persistence", "--tools", "", "--setting-sources", "",
                                 "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        case .login:
            // Claude passes its localhost callback URL to BROWSER. The URL printed on stdout is
            // a different, manual-code flow and cannot finish the automatic sign-in.
            env["BROWSER"] = "/usr/bin/open"
            process.arguments = ["auth", "login", "--claudeai"]
        case .status:
            process.arguments = ["auth", "status"]
        }
        process.environment = env
        process.standardInput = input
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try Task.checkCancellation()
        try process.run()
        let pid = process.processIdentifier
        let identity = SubprocessReaper.Identity(pid: pid)
        processLock.withLock {
            activeProcesses[pid] = TrackedProcess(process: process, identity: identity)
        }
        defer {
            _ = processLock.withLock { activeProcesses.removeValue(forKey: pid) }
            SubprocessReaper.reapInBackground(
                process: process,
                identity: identity,
                stdin: input,
                stdout: output
            )
        }
        let deadline = ContinuousClock.now.advanced(by: operation == .login ? .seconds(300) : .seconds(25))
        if operation != .read {
            // Claude handles its own browser callback and account state. Only its exit code is needed.
            try? input.fileHandleForWriting.close()
            while SubprocessReaper.isProcessRunning(process, identity: identity) {
                try Task.checkCancellation()
                if ContinuousClock.now >= deadline { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(150))
            }
            for _ in 0..<10 where process.isRunning {
                await SubprocessReaper.uncancelledSleep(milliseconds: 10)
            }
            guard !process.isRunning else { throw Failure.unreadable }
            return Result(status: process.terminationStatus)
        }
        guard let output else { throw Failure.unreadable }
        let request: [String: Any] = ["type": "control_request", "request_id": id,
                                      "request": ["subtype": "get_usage", "skip_behaviors": true]]
        let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: data)
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unreadable }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw Failure.timeout }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                pending.append(contentsOf: buffer.prefix(count))
                guard pending.count <= 1024 * 1024 else { throw Failure.unreadable }
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    if let payload = try response(line, id: id) {
                        return Result(payload: payload, status: 0)
                    }
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.unreadable }
            if !SubprocessReaper.isProcessRunning(process, identity: identity) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<10 where process.isRunning && !SubprocessReaper.isAlive(pid: pid, identity: identity) {
            await SubprocessReaper.uncancelledSleep(milliseconds: 10)
        }
        guard !process.isRunning else { throw Failure.unreadable }
        return Result(status: process.terminationStatus)
    }

    private static func response(_ line: Data, id: String) throws -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["type"] as? String == "control_response",
              let response = message["response"] as? [String: Any], response["request_id"] as? String == id else { return nil }
        guard response["subtype"] as? String == "success", let data = response["response"] as? [String: Any] else {
            throw Failure.unreadable
        }
        return try JSONSerialization.data(withJSONObject: data)
    }

}
#endif
