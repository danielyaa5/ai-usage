import AppKit
import Foundation

/// The bundled Codex app-server: where it is, the folder it keeps its own sign-in in, and the
/// locked-down settings it runs with.
enum CodexHelper {
    static let name = "codex-app-server"

    static var executable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: name)
    }

    /// The model list from the same Codex release, so Codex never downloads one.
    static var modelCatalog: URL? {
        Bundle.main.url(forResource: "codex-models", withExtension: "json")
    }

    /// CODEX_HOME: a folder in the app's container, never ~/.codex.
    static var home: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AIUsageStoreTest", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// The stdio transport is the default; `--strict-config` makes a setting Codex doesn't know an
    /// error instead of something it quietly ignores.
    static let arguments = ["--strict-config"]

    /// Signing in talks to auth.openai.com and reading limits to chatgpt.com. Anything else is extra.
    static let expectedHosts: Set<String> = ["auth.openai.com", "chatgpt.com"]

    /// Stages in which Codex has no reason to use the network: before the app says hello, the
    /// seconds after it when no one is signed in, and while idle.
    static let quietStages: Set<String> = ["startup", "initialize", "idle"]

    /// The seconds after hello when a sign-in is stored. Codex then checks the account's workspace
    /// (chatgpt.com/backend-api/wham/accounts/check), so chatgpt.com is expected and nothing else.
    static let signedInHelloStage = "initialize, signed in"

    /// config.toml for codex-cli 0.166.0: the ChatGPT sign-in is kept in CODEX_HOME/auth.json (not the
    /// keychain), and plugins, update checks, analytics, feedback, telemetry, history, bundled skills
    /// and the model download are off. (Remote control is off through the environment; its
    /// [features] key does nothing in this release.)
    static func configText(modelCatalog: URL?) -> String {
        var lines = [
            "# Written by AI Usage Store Test, which runs Codex only to sign in and read usage limits.",
            "cli_auth_credentials_store = \"file\"",
            "forced_login_method = \"chatgpt\"",
            "check_for_update_on_startup = false",
        ]
        if let modelCatalog {
            lines.append("model_catalog_json = \(tomlString(modelCatalog.path))")
        }
        lines += [
            "",
            "[analytics]",
            "enabled = false",
            "",
            "[feedback]",
            "enabled = false",
            "",
            "[history]",
            "persistence = \"none\"",
            "",
            "[otel]",
            "exporter = \"none\"",
            "trace_exporter = \"none\"",
            "metrics_exporter = \"none\"",
            "log_user_prompt = false",
            "",
            "[skills.bundled]",
            "enabled = false",
            "",
            "[features]",
            "plugins = false",
            "remote_plugin = false",
            "plugin_discovery_prefetch = false",
            "apps = false",
            "system_proxy_fallback = false",
            "respect_system_proxy = false",
            "shell_snapshot = false",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Makes CODEX_HOME (owner only) and writes config.toml into it.
    static func prepareHome() throws -> URL {
        let home = Self.home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try configText(modelCatalog: modelCatalog)
            .write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return home
    }

    /// Codex gets a small environment of its own: the container's home, its CODEX_HOME, and, when
    /// `proxyPort` is set, every proxy variable pointing at the app's logging proxy.
    static func environment(home: URL, proxyPort: UInt16?) -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            // Connections and responses (reqwest), warnings from everything else. No request headers.
            "RUST_LOG": "warn,reqwest=debug",
            "NO_COLOR": "1",
            // Codex's own switch for remote control (an internal variable its daemon sets).
            "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED": "1",
        ]
        if let proxyPort {
            let proxy = "http://127.0.0.1:\(proxyPort)"
            for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"] {
                environment[key] = proxy
            }
            environment["NO_PROXY"] = "127.0.0.1,localhost,::1"
            environment["no_proxy"] = "127.0.0.1,localhost,::1"
        }
        return environment
    }

    private static let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    static func stripANSI(_ text: String) -> String {
        guard let ansi else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return ansi.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// The names and sizes of what Codex keeps in CODEX_HOME (never the contents).
    static func homeListing() -> String {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: home.path) else { return "unreadable" }
        return names.sorted().map { name in
            let path = home.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue { return name + "/" }
            let size = (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            return "\(name) (\(size) bytes)"
        }.joined(separator: ", ")
    }

    static var hasSignIn: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
    }

    /// What /etc/codex holds (names only). Codex reads managed settings there at startup, and stops if
    /// it can't read a file that exists.
    static var systemSettings: String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: "/etc/codex") else { return "none" }
        guard let names = try? manager.contentsOfDirectory(atPath: "/etc/codex") else { return "exists, can't list it" }
        return names.isEmpty ? "empty" : names.sorted().joined(separator: ", ")
    }

    /// Deletes the test's own sign-in file without reading it, when Codex couldn't sign out.
    static func removeSignIn() -> Bool {
        let file = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }
}

/// A string several queues read and one writes: the stage the Codex test is in, read by the proxy as
/// connections arrive.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String) {
        self.text = text
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
        set {
            lock.lock()
            text = newValue
            lock.unlock()
        }
    }
}

/// A notification from Codex, cut down on Codex's queue to the parts the test keeps.
struct CodexEvent: Sendable {
    var method: String
    var success: Bool?
    var text: String?

    init(method: String, params: [String: Any]) {
        self.method = method
        switch method {
        case "account/login/completed":
            success = params["success"] as? Bool
            text = (params["error"] as? String).map { String(Redact.scrub($0).prefix(300)) }
        case "configWarning":
            let parts = [params["summary"] as? String, params["details"] as? String].compactMap { $0 }
            text = String(Redact.scrub(parts.joined(separator: ": ")).prefix(400))
        case "account/updated":
            text = "auth \(params["authMode"] as? String ?? "none"), plan \(params["planType"] as? String ?? "none")"
        default:
            break
        }
    }
}

/// What one start of the bundled Codex saw.
@MainActor
final class CodexRun {
    let label: String
    var loginResult: (success: Bool, error: String?)?
    var windowEnded: String?
    var windowEndedAt: Date?
    var usedBrowser = false
    var configWarnings: [String] = []
    var serverRequests: [String] = []
    var notifications: [String] = []
    var stderrLines = 0
    var droppedLines = 0
    var panics: [String] = []
    var exit: String?
    var stopping = false
    /// You clicked Stop while the test waited for the sign-in.
    var cancelled = false

    init(label: String) {
        self.label = label
    }
}

/// The limit windows in an `account/rateLimits/read` reply. The account id in it is not kept.
struct CodexLimitReading {
    var windows: [String] = []
    var facts: [String: String] = [:]

    init(_ result: [String: Any]) {
        var snapshots: [(String, [String: Any])] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in byID {
                if let snapshot = value as? [String: Any] { snapshots.append((key, snapshot)) }
            }
        }
        if snapshots.isEmpty, let single = result["rateLimits"] as? [String: Any] {
            snapshots.append((single["limitId"] as? String ?? "rateLimits", single))
        }
        for (name, snapshot) in snapshots.sorted(by: { $0.0 < $1.0 }) {
            for slot in ["primary", "secondary"] {
                guard let window = snapshot[slot] as? [String: Any],
                      let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                var text = String(format: "%.0f%% used", used)
                if let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue {
                    text += ", \(Self.windowName(minutes)) window"
                }
                if let resets = (window["resetsAt"] as? NSNumber)?.doubleValue {
                    text += ", resets \(Date(timeIntervalSince1970: resets).formatted(date: .abbreviated, time: .shortened))"
                }
                facts["\(name).\(slot)"] = text
                windows.append("\(name) \(slot)")
            }
            if let plan = snapshot["planType"] as? String { facts["\(name).plan"] = plan }
            if let reached = snapshot["rateLimitReachedType"] as? String { facts["\(name).reached"] = reached }
        }
        if let allowed = result["ordinaryUsageAllowed"] as? Bool { facts["ordinaryUsageAllowed"] = allowed ? "yes" : "no" }
        let accountID = result["accountId"]
        facts["accountId"] = (accountID == nil || accountID is NSNull) ? "not sent" : "sent (not kept)"
        facts["keys"] = result.keys.sorted().joined(separator: ", ")
    }

    var summary: String {
        windows.isEmpty ? "The reply had no limit windows." :
            "Read \(windows.count) window\(windows.count == 1 ? "" : "s"): \(windows.joined(separator: ", "))."
    }

    static func windowName(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5-hour"
        case 1440: return "daily"
        case 10080: return "weekly"
        default: return "\(minutes)-minute"
        }
    }
}

// MARK: - Test 1: ChatGPT limits through the bundled Codex

extension TestModel {
    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The first run: start Codex behind the logging proxy, sign in with ChatGPT, read the limits,
    /// watch for a minute, stop, then read the limits once more without the proxy.
    func runCodexTest() async {
        guard !codexRunning else { return }
        codexRunning = true
        defer {
            codexRunning = false
            idleSecondsLeft = nil
            browserFallbackURL = nil
        }
        let firstContact = contacts.count
        codexRuns = []
        codexStage.value = "startup"
        codexStatus = "Starting Codex…"
        guard let proxyPort = await startProxy() else {
            codexStatus = "The logging proxy didn't start, so the test stopped."
            return
        }
        defer {
            proxy?.stop()
            proxy = nil
        }
        guard let started = await startCodex(label: "first run", proxyPort: proxyPort,
                                             checkID: "codex.launch", title: "Codex starts in the sandbox") else {
            codexStatus = "Codex didn't start. The results above say why."
            return
        }
        let (client, run) = started
        var signedIn = false
        var limitsRead = false
        do {
            codexStage.value = "account"
            let before = try await client.request("account/read", params: [:])
            if Self.account(before) != nil {
                // An earlier run's sign-in: sign out so this run tests signing in.
                codexStage.value = "logout"
                _ = try await client.request("account/logout", timeout: 30)
                results.event("Signed out of an earlier test sign-in, so the sign-in runs again.")
            }
            signedIn = await signIn(client, run)
            if signedIn {
                codexStage.value = "account"
                let after = try await client.request("account/read", params: [:])
                let account = Self.account(after)
                let plan = account?["planType"] as? String
                results.set("codex.account", test: 1, "Signed in with ChatGPT",
                            account?["type"] as? String == "chatgpt" ? .passed : .failed,
                            account == nil ? "Codex says no one is signed in." : "Codex reports a ChatGPT account (\(plan ?? "no plan given")).",
                            facts: ["type": account?["type"] as? String ?? "none", "plan": plan ?? "none"])
                limitsRead = await readLimits(client, checkID: "codex.limits", title: "ChatGPT limits read")
            }
        } catch {
            results.set("codex.account", test: 1, "Signed in with ChatGPT", .failed, Redact.scrub("\(error)"))
        }
        if limitsRead {
            await idle(seconds: 60)
        }
        await stopCodex(client, run, checkID: "codex.stop", title: "Codex stops cleanly")
        judgeContacts(contactsSince(firstContact), hostsID: "codex.hosts", extrasID: "codex.no-extras", limitsRead: limitsRead)
        if signedIn {
            codexStatus = "Reading the limits again without the logging proxy…"
            await directRun()
        }
        judgeLogs()
        codexStatus = limitsRead ? "Done. Codex signed in and read your limits; the results are below." :
            "Done, but the limits weren't read. The results below say why."
    }

    /// Later runs (after a relaunch, and after the update to build 2): the sign-in should still be
    /// there and the limits readable. After the update the test signs out, so no token is left behind.
    func codexAfterRestart(signOutAfter: Bool) async {
        let firstContact = contacts.count
        codexStage.value = "startup"
        let proxyPort = await startProxy()
        defer {
            proxy?.stop()
            proxy = nil
        }
        guard let started = await startCodex(label: phaseName, proxyPort: proxyPort, checkID: id("codex.launch"),
                                             title: "Codex starts after the \(phaseName)") else {
            if signOutAfter { removeSignInFile(reason: "Codex didn't start") }
            return
        }
        let (client, run) = started
        var limitsRead = false
        var signedOut = false
        do {
            codexStage.value = "account"
            let reply = try await client.request("account/read", params: [:])
            let account = Self.account(reply)
            results.set(id("codex.account"), test: 1, "Still signed in after the \(phaseName)",
                        account?["type"] as? String == "chatgpt" ? .passed : .failed,
                        account == nil ? "Codex says no one is signed in." : "The ChatGPT sign-in survived the \(phaseName).",
                        facts: ["plan": account?["planType"] as? String ?? "none", "authFile": CodexHelper.hasSignIn ? "present" : "missing"])
            if account != nil {
                limitsRead = await readLimits(client, checkID: id("codex.limits"), title: "ChatGPT limits read after the \(phaseName)")
            }
        } catch {
            results.set(id("codex.account"), test: 1, "Still signed in after the \(phaseName)", .failed, Redact.scrub("\(error)"))
        }
        if signOutAfter {
            codexStage.value = "logout"
            do {
                _ = try await client.request("account/logout", timeout: 30)
                let check = try await client.request("account/read", params: [:])
                signedOut = Self.account(check) == nil
                results.set(id("codex.logout"), test: 1, "Signed out at the end of the test", signedOut ? .passed : .failed,
                            signedOut ? "Codex signed out; no token is left in the test app." : "Codex still reports an account after signing out.",
                            facts: ["authFile": CodexHelper.hasSignIn ? "still there" : "gone"])
            } catch {
                results.set(id("codex.logout"), test: 1, "Signed out at the end of the test", .failed,
                            "Codex couldn't sign out: \(Redact.scrub("\(error)"))")
            }
        }
        await stopCodex(client, run, checkID: id("codex.stop"), title: "Codex stops cleanly after the \(phaseName)")
        judgeContacts(contactsSince(firstContact), hostsID: id("codex.hosts"), extrasID: id("codex.no-extras"),
                      limitsRead: limitsRead)
        judgeLogs()
        if signOutAfter && !signedOut { removeSignInFile(reason: "Codex couldn't sign out") }
    }

    func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
        codexRuns.last?.usedBrowser = true
        codexStatus = "Sign in with ChatGPT in your browser, then come back here."
        results.event("Opened the ChatGPT sign-in page in the default browser.")
    }

    /// Gives up waiting for the sign-in.
    func stopSignIn() {
        codexRuns.last?.cancelled = true
        results.event("You stopped the sign-in.")
    }

    // MARK: - Steps

    private func startProxy() async -> UInt16? {
        let stage = codexStage
        do {
            let proxy = try ConnectProxy(stage: { stage.value }) { [weak self] contact in
                Task { @MainActor in self?.recordContact(contact) }
            }
            let port = await proxy.start { [weak self] problem in
                Task { @MainActor in self?.results.event("Logging proxy: \(problem)") }
            }
            guard let port else {
                results.set(id("codex.proxy"), test: 1, "Logging proxy for Codex", .failed, "It didn't start listening on 127.0.0.1.")
                return nil
            }
            self.proxy = proxy
            results.event("Logging proxy for Codex on 127.0.0.1:\(port).")
            return port
        } catch {
            results.set(id("codex.proxy"), test: 1, "Logging proxy for Codex", .failed, "Couldn't create it: \(error)")
            return nil
        }
    }

    /// Starts Codex and says hello. Records `checkID`; returns nil when Codex didn't answer.
    private func startCodex(label: String, proxyPort: UInt16?, checkID: String, title: String) async -> (CodexClient, CodexRun)? {
        guard let executable = CodexHelper.executable else {
            results.set(checkID, test: 1, title, .failed, "\(CodexHelper.name) is missing from the app bundle.")
            return nil
        }
        let home: URL
        do {
            home = try CodexHelper.prepareHome()
        } catch {
            results.set(checkID, test: 1, title, .failed, "Couldn't set up Codex's folder in the container: \(error.localizedDescription)")
            return nil
        }
        let run = CodexRun(label: label)
        codexRuns.append(run)
        codexStage.value = proxyPort == nil ? "direct" : "startup"
        // Codex looks for project settings (.codex/config.toml) from its working folder up to the
        // nearest .git. Starting it in / keeps that walk out of your home folder, where the sandbox
        // would refuse the read and Codex would stop.
        let client = CodexClient(executable: executable, arguments: CodexHelper.arguments,
                                 environment: CodexHelper.environment(home: home, proxyPort: proxyPort),
                                 directory: URL(fileURLWithPath: "/", isDirectory: true))
        client.onStderr = { [weak self] line in
            Task { @MainActor in self?.takeStderr(line, run: run) }
        }
        client.onNotification = { [weak self] method, params in
            let event = CodexEvent(method: method, params: params)
            Task { @MainActor in self?.take(event, run: run) }
        }
        client.onServerRequest = { [weak self] method in
            Task { @MainActor in
                run.serverRequests.append(method)
                self?.results.event("Codex asked the app for \(method); the test declined.")
            }
        }
        client.onExit = { [weak self] text in
            Task { @MainActor in
                run.exit = text
                if !run.stopping { self?.results.event("Codex exited by itself (\(text)).") }
            }
        }
        let launched = Date()
        let signedInAtLaunch = CodexHelper.hasSignIn
        var facts = [
            "helper": CodeSigning.summary(of: executable),
            "proxy": proxyPort == nil ? "none" : "the app's logging proxy",
            "modelCatalog": CodexHelper.modelCatalog == nil ? "missing, so Codex may download one" : "bundled",
            "signInStored": signedInAtLaunch ? "yes" : "no",
            "etcCodex": CodexHelper.systemSettings,
        ]
        do {
            try client.start()
        } catch {
            results.set(checkID, test: 1, title, .failed, "Couldn't start Codex: \(error.localizedDescription)", facts: facts)
            return nil
        }
        codex = client
        results.event("Started Codex (pid \(client.pid)) \(proxyPort == nil ? "without" : "behind") the logging proxy.")
        if proxyPort != nil {
            // Anything Codex does by itself before the app says hello counts as "startup".
            codexStatus = "Watching Codex start…"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            codexStage.value = signedInAtLaunch ? CodexHelper.signedInHelloStage : "initialize"
        }
        do {
            let hello = try await client.request("initialize", params: [
                "clientInfo": ["name": "ai_usage_store_test", "title": "AI Usage Store Test", "version": shortVersion],
                // Codex announces its remote control state (with this Mac's name) unasked; the test has no use for it.
                "capabilities": ["optOutNotificationMethods": ["remoteControl/status/changed"]],
            ], timeout: 30)
            client.notify("initialized")
            let userAgent = Redact.scrub(hello["userAgent"] as? String ?? "?")
            codexVersion = Self.firstVersion(in: userAgent) ?? codexVersion
            let codexHome = hello["codexHome"] as? String ?? ""
            facts["userAgent"] = String(userAgent.prefix(200))
            facts["platform"] = "\(hello["platformFamily"] as? String ?? "?")/\(hello["platformOs"] as? String ?? "?")"
            facts["codexHomeInContainer"] = codexHome.contains("/Library/Containers/") ? "yes" : "no"
            facts["seconds"] = String(format: "%.1f", Date().timeIntervalSince(launched))
            results.set(checkID, test: 1, title, .passed, "Codex \(codexVersion ?? "?") is running in the sandbox and answered.",
                        facts: facts)
            if proxyPort != nil {
                // And what it does in the seconds after hello (plugins, update checks) counts as "initialize".
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return (client, run)
        } catch {
            run.stopping = true
            let stopped = await client.stop()
            codex = nil
            facts["exit"] = run.exit ?? stopped.description
            facts["lastStderr"] = codexLog.suffix(3).joined(separator: " | ")
            if !run.panics.isEmpty { facts["panic"] = run.panics.joined(separator: " | ") }
            results.set(checkID, test: 1, title, .failed, "Codex didn't answer: \(Redact.scrub("\(error)")).", facts: facts)
            return nil
        }
    }

    /// Starts the ChatGPT sign-in and waits up to Codex's own ten minutes for it to finish.
    private func signIn(_ client: CodexClient, _ run: CodexRun) async -> Bool {
        let title = "Sign-in with ChatGPT in a sandboxed browser window"
        // Codex's sign-in waits on 127.0.0.1:1455 and cancels whatever already listens there, which
        // would be another Codex sign-in in progress (`codex login`, the Codex app). Don't.
        let port = await URLCheck.probe(host: "127.0.0.1", port: 1455, timeout: 2)
        if port == "ready" {
            results.set("codex.login", test: 1, title, .skipped,
                        "Another Codex sign-in seems to be open on this Mac (something listens on 127.0.0.1:1455). Finish or close it, then click Sign in again.")
            codexStatus = "Another Codex sign-in is open on this Mac. Finish or close it, then try again."
            return false
        }
        codexStage.value = "login"
        let reply: [String: Any]
        do {
            reply = try await client.request("account/login/start", params: ["type": "chatgpt"], timeout: 30)
        } catch {
            results.set("codex.login", test: 1, title, .failed, "Codex couldn't start the sign-in: \(Redact.scrub("\(error)"))")
            return false
        }
        guard let text = reply["authUrl"] as? String, let authURL = URL(string: text) else {
            results.set("codex.login", test: 1, title, .failed, "Codex's reply had no sign-in address.",
                        facts: ["keys": reply.keys.sorted().joined(separator: ", ")])
            return false
        }
        var facts: [String: String] = ["signInHost": authURL.host ?? "?"]
        let query = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let redirect = query.first(where: { $0.name == "redirect_uri" })?.value {
            facts["redirectURI"] = redirect  // Codex's own login server, http://127.0.0.1:1455/auth/callback
        }
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: authURL) {
            facts["defaultBrowser"] = Bundle(url: browser)?.bundleIdentifier ?? browser.lastPathComponent
        }
        browserFallbackURL = authURL
        signInWaiting = true
        defer { signInWaiting = false }
        let started = Date()
        // The window with the button you clicked; a window that isn't on screen can't host the session.
        let anchor = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        let login = anchor.map { WebLogin(anchor: $0) }
        webLogin = login
        let opened = login?.start(url: authURL) { text in
            run.windowEnded = text
            run.windowEndedAt = Date()
        } ?? false
        facts["window"] = opened ? "opened" : (anchor == nil ? "no app window to attach it to" : "didn't open")
        results.set("codex.login", test: 1, title, .running, opened ? "Waiting for you to sign in." : "The sign-in window didn't open.")
        codexStatus = opened ? "Sign in with ChatGPT in the window that opened. If it asks to use auth.openai.com, click Continue." :
            "The sign-in window didn't open. Use the link below to sign in in your browser."
        // Codex's login server waits ten minutes. The browser link below works all that time, also
        // after the window closes, so the test waits as long, unless you click Stop.
        let deadline = started.addingTimeInterval(600)
        var toldAboutWindow = false
        while run.loginResult == nil, !run.cancelled, Date() < deadline, client.isRunning {
            if run.windowEndedAt != nil, !toldAboutWindow, !run.usedBrowser {
                toldAboutWindow = true
                codexStatus = "The sign-in window closed before the sign-in finished. Use the link below to sign in in your browser, or click Stop."
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        login?.finish()
        webLogin = nil
        browserFallbackURL = nil
        facts["seconds"] = String(format: "%.0f", Date().timeIntervalSince(started))
        if let ended = run.windowEnded { facts["windowEnded"] = ended }
        if run.usedBrowser { facts["usedBrowserLink"] = "yes" }
        if run.loginResult == nil, client.isRunning, CodexHelper.hasSignIn,
           let check = try? await client.request("account/read", params: [:]),
           Self.account(check)?["type"] as? String == "chatgpt" {
            // Signed in, but the notice that says so never came.
            facts["completedNotice"] = "missing; account/read shows the sign-in"
            run.loginResult = (true, nil)
        }
        guard let result = run.loginResult else {
            let why: String
            if !client.isRunning {
                why = "Codex exited during the sign-in (\(run.exit ?? "unknown"))."
            } else if run.cancelled {
                why = "You stopped the sign-in\(run.windowEnded.map { " after \($0)" } ?? "")."
            } else if let ended = run.windowEnded {
                why = "The sign-in didn't finish within ten minutes; \(ended)."
            } else {
                why = "The sign-in didn't finish within ten minutes."
            }
            _ = try? await client.request("account/login/cancel", params: ["loginId": reply["loginId"] as? String ?? ""], timeout: 10)
            results.set("codex.login", test: 1, title, .failed, why, facts: facts)
            return false
        }
        if result.success {
            facts["windowClosedBy"] = run.windowEnded == nil ? "the app, after Codex reported the sign-in" : "the window itself"
            facts["authFile"] = CodexHelper.hasSignIn ? "in Codex's folder in the container" : "not found"
            results.set("codex.login", test: 1, title, .passed, "Signed in; Codex's login server on 127.0.0.1 got the callback inside the sandbox.",
                        facts: facts)
        } else {
            results.set("codex.login", test: 1, title, .failed, "Codex reported the sign-in failed: \(result.error ?? "no reason given").",
                        facts: facts)
        }
        return result.success
    }

    /// Reads the limits and records `checkID`.
    private func readLimits(_ client: CodexClient, checkID: String, title: String) async -> Bool {
        codexStage.value = "limits"
        codexStatus = "Reading your ChatGPT limits…"
        do {
            // The light read a shipped app would poll with: no separate reset-credit lookup.
            let reply = try await client.request("account/rateLimits/read", params: ["excludeResetCreditDetails": true],
                                                 timeout: 30)
            let reading = CodexLimitReading(reply)
            results.set(checkID, test: 1, title, reading.windows.isEmpty ? .failed : .passed, reading.summary, facts: reading.facts)
            return !reading.windows.isEmpty
        } catch {
            results.set(checkID, test: 1, title, .failed, Redact.scrub("\(error)"))
            return false
        }
    }

    /// Leaves Codex running with nothing to do, to see whether it reaches out on its own.
    private func idle(seconds: Int) async {
        codexStage.value = "idle"
        for left in stride(from: seconds, to: 0, by: -1) {
            idleSecondsLeft = left
            codexStatus = "Watching which servers Codex contacts while idle: \(left) s left."
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        idleSecondsLeft = nil
    }

    private func stopCodex(_ client: CodexClient, _ run: CodexRun, checkID: String, title: String) async {
        codexStage.value = "stopping"
        run.stopping = true
        let unexpected = run.exit
        let stopped = await client.stop()
        if codex === client { codex = nil }
        let facts = ["how": stopped.description, "codexHome": CodexHelper.homeListing()]
        if let unexpected {
            results.set(checkID, test: 1, title, .failed, "Codex had already exited by itself (\(unexpected)).", facts: facts)
        } else {
            results.set(checkID, test: 1, title, stopped.clean ? .passed : .failed,
                        stopped.clean ? "Codex left by itself once its input closed (\(stopped.description))." :
                            "Codex didn't leave by itself when its input closed: it \(stopped.description).", facts: facts)
        }
    }

    /// The same Codex and sign-in, with no proxy variables, the way a shipped app would run it.
    private func directRun() async {
        codexStage.value = "direct"
        let title = "Limits read without the logging proxy"
        guard let started = await startCodex(label: "without the proxy", proxyPort: nil, checkID: "codex.direct",
                                             title: title) else { return }
        let (client, run) = started
        _ = await readLimits(client, checkID: "codex.direct", title: title)
        run.stopping = true
        _ = await client.stop()
        if codex === client { codex = nil }
    }

    private func take(_ event: CodexEvent, run: CodexRun) {
        run.notifications.append(event.method)
        switch event.method {
        case "account/login/completed":
            run.loginResult = (event.success ?? false, event.text)
            results.event("Codex: sign-in \(event.success == true ? "finished" : "failed").")
        case "configWarning":
            run.configWarnings.append(event.text ?? "?")
            results.event("Codex warned about its settings: \(event.text ?? "?")")
        case "account/updated":
            results.event("Codex: account updated (\(event.text ?? "")).")
        default:
            break
        }
    }

    private func takeStderr(_ raw: String, run: CodexRun) {
        run.stderrLines += 1
        let line = CodexHelper.stripANSI(raw)
        if line.contains("panicked at") {
            run.panics.append(String(Redact.scrub(line).prefix(300)))
        }
        guard let kept = Redact.line(line, limit: 400) else {
            run.droppedLines += 1
            return
        }
        codexLog.append("[\(run.label)] \(kept)")
        if codexLog.count > 2000 { codexLog.removeFirst(codexLog.count - 2000) }
    }

    private func recordContact(_ contact: ConnectProxy.Contact) {
        // Never trimmed (the test makes a few dozen), so an index into it stays valid.
        guard contacts.count < 5000 else { return }
        contacts.append(ContactRecord(host: contact.host, port: contact.port, method: contact.method, stage: contact.stage,
                                      at: contact.at, result: contact.result, bytesUp: contact.bytesUp,
                                      bytesDown: contact.bytesDown))
        if contact.result != "closed" {
            results.event("Codex → \(contact.host):\(contact.port) while \(contact.stage): \(contact.result)")
        }
    }

    private func contactsSince(_ index: Int) -> [ContactRecord] {
        index < contacts.count ? Array(contacts[index...]) : []
    }

    /// Which servers Codex asked the proxy for, and whether any was more than signing in and reading limits.
    private func judgeContacts(_ list: [ContactRecord], hostsID: String, extrasID: String, limitsRead: Bool) {
        let opened = list.filter { $0.result != "closed" }
        var facts: [String: String] = [:]
        for host in Set(opened.map { "\($0.host):\($0.port)" }).sorted() {
            let mine = list.filter { "\($0.host):\($0.port)" == host }
            let connections = mine.filter { $0.result != "closed" }
            let stages = Set(connections.map(\.stage)).sorted().joined(separator: ", ")
            let up = mine.reduce(0) { $0 + $1.bytesUp }
            let down = mine.reduce(0) { $0 + $1.bytesDown }
            let failures = connections.filter { $0.result != "tunneled" }.map(\.result)
            var text = "\(connections.count) connection\(connections.count == 1 ? "" : "s") while \(stages); \(up / 1024) KB up, \(down / 1024) KB down"
            if !failures.isEmpty { text += "; " + Set(failures).sorted().joined(separator: "; ") }
            facts[host] = text
        }
        let hosts = Set(opened.map(\.host)).sorted()
        results.set(hostsID, test: 1, "Servers Codex contacted", .info,
                    hosts.isEmpty ? "None through the logging proxy." : hosts.joined(separator: ", "), facts: facts)
        if opened.isEmpty {
            results.set(extrasID, test: 1, "No plugin, update or analytics calls", limitsRead ? .failed : .info,
                        limitsRead ? "Codex read the limits without using the logging proxy, so this run can't show what it contacted." :
                            "Codex contacted nothing through the logging proxy.")
            return
        }
        let unexpectedHosts = hosts.filter { !CodexHelper.expectedHosts.contains($0) }
        let quiet = opened.filter { contact in
            CodexHelper.quietStages.contains(contact.stage) ||
                (contact.stage == CodexHelper.signedInHelloStage && contact.host != "chatgpt.com")
        }
        var problems: [String] = []
        if !unexpectedHosts.isEmpty { problems.append("other servers: \(unexpectedHosts.joined(separator: ", "))") }
        if !quiet.isEmpty {
            problems.append("connections while starting or idle: " +
                            Set(quiet.map { "\($0.host) (\($0.stage))" }).sorted().joined(separator: ", "))
        }
        results.set(extrasID, test: 1, "No plugin, update or analytics calls", problems.isEmpty ? .passed : .failed,
                    problems.isEmpty ? "Only \(hosts.joined(separator: " and ")), and only to sign in and read limits." :
                        "Codex also made " + problems.joined(separator: "; ") + ".")
    }

    /// Codex's settings warnings, panics and requests to the app, over this phase's runs.
    private func judgeLogs() {
        let runs = codexRuns
        guard !runs.isEmpty else { return }
        let warnings = runs.flatMap { $0.configWarnings }
        results.set(id("codex.config"), test: 1, "Codex accepted the locked-down settings", warnings.isEmpty ? .passed : .failed,
                    warnings.isEmpty ? "No settings warnings, with --strict-config." : warnings.joined(separator: " | "))
        var facts: [String: String] = [:]
        for run in runs {
            facts["\(run.label): lines"] = "\(run.stderrLines), \(run.droppedLines) left out for mentioning credentials"
            facts["\(run.label): notifications"] = Set(run.notifications).sorted().joined(separator: ", ")
            if !run.serverRequests.isEmpty {
                facts["\(run.label): requests to the app"] = run.serverRequests.joined(separator: ", ")
            }
        }
        let panics = runs.flatMap { $0.panics }
        results.set(id("codex.log"), test: 1, "Codex's own log", panics.isEmpty ? .info : .failed,
                    panics.isEmpty ? "No crashes logged." : "Codex panicked: \(panics.joined(separator: " | "))",
                    facts: facts)
    }

    private func removeSignInFile(reason: String) {
        let removed = CodexHelper.removeSignIn()
        results.set(id("codex.cleanup"), test: 1, "Test sign-in removed", removed ? .passed : .failed,
                    removed ? "\(reason), so the app deleted its own auth.json without reading it." :
                        "\(reason), and the app couldn't delete its auth.json.")
    }

    static func account(_ reply: [String: Any]) -> [String: Any]? {
        reply["account"] as? [String: Any]
    }

    static func firstVersion(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
