import AppKit
import AIUsageKit

@MainActor
final class ChatGPTAccount {
    enum Problem: LocalizedError {
        case unavailable, busy, signIn, closed, expired, unreadable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The ChatGPT helper is missing. Reinstall AI Usage."
            case .busy: return "Finish the other Codex sign-in on this Mac, then try again."
            case .signIn: return "OpenAI could not start sign-in. Try again."
            case .closed: return "Sign-in was canceled."
            case .expired: return "Sign-in timed out. Try again."
            case .unreadable: return "ChatGPT limits are unavailable. Check the connection or sign in again."
            }
        }
    }

    private var loginWindow: WebLogin?
    private var cancelled = false
    private var loginResult: Bool?
    private var loginID: String?
    private weak var loginClient: CodexClient?
    private var browserClosedAt: Date?
    private(set) var signingIn = false

    private func start() async throws -> CodexClient {
        guard let executable = CodexHelper.executable, CodexHelper.modelCatalog != nil else { throw Problem.unavailable }
        let home = try CodexHelper.prepareHome()
        let client = CodexClient(executable: executable, arguments: CodexHelper.arguments,
                    environment: CodexHelper.environment(home: home, proxyPort: nil), directory: home)
        client.onNotification = { [weak self, weak client] method, params in
            if method == "account/login/completed" {
                let success = params["success"] as? Bool ?? false
                let id = params["loginId"] as? String
                Task { @MainActor in
                    guard let self, let client, self.loginClient === client else { return }
                    // Codex permits an omitted loginId. This process handles exactly one login.
                    if id == nil || self.loginID == nil || self.loginID == id { self.loginResult = success }
                }
            }
        }
        try client.start()
        do {
            _ = try await client.request("initialize", params: ["clientInfo": ["name":"ai_usage","version":"1.0"],
                "capabilities":["optOutNotificationMethods":["remoteControl/status/changed"]]])
            client.notify("initialized")
            return client
        } catch {
            _ = await client.stop()
            throw Problem.unreadable
        }
    }

    func connect() async throws {
        guard !signingIn else { throw Problem.busy }
        signingIn = true
        cancelled = false
        loginResult = nil
        browserClosedAt = nil
        defer {
            signingIn = false
            loginClient = nil
            loginID = nil
            loginWindow?.finish()
            loginWindow = nil
        }
        guard await PortProbe.run(host: "127.0.0.1", port: 1455, timeout: 2) != "ready" else { throw Problem.busy }
        let client = try await start()
        loginClient = client
        do {
            if await signedIn(client) { _ = await client.stop(); return }
            let reply = try await client.request("account/login/start", params:["type":"chatgpt"])
            loginID = reply["loginId"] as? String
            guard let text = reply["authUrl"] as? String, let url = URL(string: text),
                  url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                throw Problem.signIn
            }
            let web = WebLogin(anchor: window)
            loginWindow = web
            guard !cancelled, web.start(url: url, onEnd: { [weak self] _ in self?.browserClosedAt = Date() }) else { throw Problem.signIn }
            let deadline = Date().addingTimeInterval(600)
            var nextCheck = Date().addingTimeInterval(3)
            while !cancelled && loginResult == nil && client.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard Date() >= nextCheck else { continue }
                // Some helper versions complete the browser callback without sending a notice.
                if await signedIn(client) { loginResult = true; break }
                if let closed = browserClosedAt, Date().timeIntervalSince(closed) >= 3 { throw Problem.closed }
                nextCheck = Date().addingTimeInterval(3)
            }
            guard !cancelled else { throw Problem.closed }
            guard loginResult == true else { throw loginResult == nil ? Problem.expired : Problem.signIn }
            _ = await client.stop()
        } catch {
            if let loginID { _ = try? await client.request("account/login/cancel", params:["loginId":loginID],timeout:5) }
            _ = await client.stop()
            throw error
        }
    }

    private func signedIn(_ client: CodexClient) async -> Bool {
        let reply = try? await client.request("account/read", params: ["refreshToken": false], timeout: 5)
        let account = reply?["account"] as? [String: Any]
        return account?["type"] as? String == "chatgpt"
    }

    func cancel() { cancelled = true; loginWindow?.finish() }

    func limits() async throws -> [LimitWindow] {
        let client = try await start()
        do {
            let reply = try await client.request("account/rateLimits/read", params: [:])
            let windows = Self.windows(reply, at: Date())
            _ = await client.stop()
            return windows
        } catch {
            _ = await client.stop()
            throw Problem.unreadable
        }
    }

    static func windows(_ reply: [String: Any], at now: Date) -> [LimitWindow] {
        let byID = reply["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        // The primary Codex limit is also returned in the legacy field. Read each bucket once.
        let snapshots = byID.isEmpty ? [("codex", reply["rateLimits"] as? [String: Any] ?? [:])] : byID.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return snapshots.flatMap { name, snapshot in
            ["primary","secondary"].compactMap { slot -> LimitWindow? in
                guard let v = snapshot[slot] as? [String: Any] else { return nil }
                return LocalLimits.window((v["usedPercent"] as? NSNumber)?.doubleValue,
                        minutes: v["windowDurationMins"] as? Int, reset: (v["resetsAt"] as? NSNumber)?.doubleValue,
                        at: now, group: name == "codex" ? nil : name, fallback: slot.capitalized)
            }
        }
    }

    func disconnect() async throws {
        let client = try await start()
        do {
            _ = try await client.request("account/logout", params: [:])
            _ = await client.stop()
        } catch { _ = await client.stop(); throw Problem.unreadable }
    }
}
