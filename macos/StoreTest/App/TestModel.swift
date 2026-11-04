import Combine
import AppKit
import Foundation
import Security
import WidgetKit

/// A reading the status line snippet sent. Only the window names and numbers are kept.
struct StatusLineReading: Codable {
    struct Window: Codable {
        var usedPercentage: Double?
        var resetsAt: Double?
    }

    var at: Date
    var hasRateLimits: Bool
    var windows: [String: Window]
    /// The top-level keys of what arrived. Anything besides "rate_limits" means the snippet sent more
    /// than it should.
    var topLevelKeys: [String]
    /// The runner's made-up sample (it uses `TestModel.sampleResetsAt`), not Claude Code.
    var selfTest: Bool
    var bytes: Int
}

/// One host the bundled Codex asked the logging proxy to reach.
struct ContactRecord: Codable {
    var host: String
    var port: Int
    var method: String
    var stage: String
    var at: Date
    var result: String
    var bytesUp: Int
    var bytesDown: Int
}

struct AppInfo: Codable {
    var version: String
    var build: String
    var phase: String
    var macOS: String
    var sandboxed: Bool
    var appGroup: Bool
    var listenerPort: Int?
    var helperSigning: String
    var codexVersion: String?
    var startedAt: Date
}

/// Everything the runner script saves for one run of the app.
struct Report: Encodable {
    var app: AppInfo
    var checks: [CheckRecord]
    var events: [String]
    var codexLog: [String]
    var contacts: [ContactRecord]
    var widgetReports: [StoreTestShared.WidgetReport]
    var statusReadings: [StatusLineReading]
    var handoff: Bool
    var done: Bool
}

/// Runs the four checks and keeps their results. The window shows them, and the runner script reads
/// them from the test listener on 127.0.0.1.
@MainActor
final class TestModel: ObservableObject {
    /// The runner's fictional status line sample resets at 2100-01-01, which no real window does.
    static let sampleResetsAt: Double = 4_102_444_800

    let options: LaunchOptions
    let results = Results()

    @Published var listenerPort: UInt16?
    @Published var listenerProblem: String?
    @Published var lanRunning = false
    @Published var codexRunning = false
    @Published var codexStatus = "Not started."
    @Published var browserFallbackURL: URL?
    @Published var signInWaiting = false
    @Published var idleSecondsLeft: Int?
    @Published var handoff = false
    @Published var done = false
    @Published var snippet: String?
    @Published var claudeReadings: [StatusLineReading] = []
    @Published var sampleReadings = 0
    /// Self-test readings that weren't exactly the sample's rate_limits.
    @Published var sampleMismatches = 0
    /// Set by the runner around its self-tests: every reading in that time is the self-test's, so one
    /// the snippet mangled can't pass for Claude Code's.
    private var selfTestRunning = false
    @Published var widgetReports: [StoreTestShared.WidgetReport] = []

    private var server: LoopbackServer?
    var proxy: ConnectProxy?
    var codex: CodexClient?
    var webLogin: WebLogin?
    var contacts: [ContactRecord] = []
    var codexLog: [String] = []
    /// The Codex test's stage, which the proxy stamps on each connection as it arrives.
    let codexStage = LockedText("startup")
    var codexRuns: [CodexRun] = []
    var codexVersion: String?
    private var statusReadings: [StatusLineReading] = []
    private var seenWidgetReports: Set<UUID> = []
    private let startedAt = Date()

    init(options: LaunchOptions) {
        self.options = options
    }

    /// A check's id in this phase: the first run uses the base id, later runs add the phase name.
    func id(_ base: String) -> String {
        options.phase == .first ? base : "\(base).\(options.phase.rawValue)"
    }

    var phaseName: String {
        switch options.phase {
        case .first: return "first run"
        case .relaunch: return "relaunch"
        case .update: return "update"
        }
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: - Start and stop

    func start() {
        signal(SIGPIPE, SIG_IGN)
        recordEnvironment()
        Task {
            await startListener()
            writeSharedConfig()
            switch options.phase {
            case .first:
                await runLoopbackChecks()
                watchWidgetReports()
            case .relaunch, .update:
                await runAutomaticPhase()
            }
        }
    }

    /// Called as the app quits: no Codex process may outlive it.
    func shutdown() {
        if let codex, codex.isRunning {
            codex.process.terminate()
        }
        proxy?.stop()
        server?.stop()
    }

    private func recordEnvironment() {
        let helper = CodexHelper.executable.map(CodeSigning.summary(of:)) ?? "missing from the app bundle"
        var facts = [
            "version": version,
            "phase": options.phase.rawValue,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "sandboxed": StoreTestShared.sandboxed ? "yes" : "no",
            "appGroup": StoreTestShared.appGroup == nil ? "missing" : "present",
            "helper": helper,
            "lanURL": options.lanURL == nil ? "not given" : "given",
        ]
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com/")!) {
            facts["defaultBrowser"] = Bundle(url: browser)?.bundleIdentifier ?? browser.lastPathComponent
        }
        let ready = StoreTestShared.sandboxed && StoreTestShared.appGroup != nil && CodexHelper.executable != nil
        results.set(id("app.environment"), test: 0, "App build and sandbox", ready ? .passed : .failed,
                    "\(version), \(phaseName), sandboxed: \(StoreTestShared.sandboxed ? "yes" : "no")", facts: facts)
    }

    private func startListener() async {
        guard let port = options.port, options.token != nil else {
            let problem = "Open this app with scripts/run.sh, which passes the port and token for the test listener."
            listenerProblem = problem
            results.set(id("app.listener"), test: 0, "Test listener on 127.0.0.1", .failed, problem)
            return
        }
        do {
            let server = try LoopbackServer(port: port) { [weak self] head, body in
                guard let self else { return .text("Gone", status: 503) }
                return await self.handle(head, body)
            }
            self.server = server
            let bound = await server.start { [weak self] problem in
                Task { @MainActor in self?.results.event("Test listener: \(problem)") }
            }
            if let bound {
                listenerPort = bound
                results.set(id("app.listener"), test: 0, "Test listener on 127.0.0.1", .passed,
                            "Listening on 127.0.0.1:\(bound), no firewall prompt expected.")
            } else {
                listenerProblem = "Couldn't listen on 127.0.0.1:\(port)."
                results.set(id("app.listener"), test: 0, "Test listener on 127.0.0.1", .failed, listenerProblem ?? "")
            }
        } catch {
            listenerProblem = "Couldn't create the listener: \(error)"
            results.set(id("app.listener"), test: 0, "Test listener on 127.0.0.1", .failed, listenerProblem ?? "")
        }
    }

    private func writeSharedConfig() {
        if options.phase == .first {
            // A report an earlier run's widget left behind isn't this run's.
            StoreTestShared.remove("widget-report.json")
        }
        guard let port = listenerPort, let token = options.token else { return }
        let config = StoreTestShared.Config(port: Int(port), token: token, lanURL: options.lanURL?.absoluteString,
                                            writtenAt: Date())
        do {
            try StoreTestShared.write(config, "config.json")
            results.set(id("app.group"), test: 0, "Settings shared with the widget", .passed,
                        "Wrote config.json to the App Group container.")
        } catch {
            results.set(id("app.group"), test: 0, "Settings shared with the widget", .failed,
                        "Couldn't write to the App Group container: \(error.localizedDescription)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Test 2: plain HTTP with only NSAllowsLocalNetworking

    func runLoopbackChecks() async {
        guard let port = listenerPort else {
            results.set(id("net.loopback-ip"), test: 2, "App → http://127.0.0.1", .skipped, "The test listener isn't running.")
            return
        }
        let ip = await URLCheck.run(name: "loopback-ip", url: URL(string: "http://127.0.0.1:\(port)/ping")!)
        record(ip, id: id("net.loopback-ip"), title: "App → http://127.0.0.1")
        let local = await URLCheck.run(name: "localhost", url: URL(string: "http://localhost:\(port)/ping")!)
        record(local, id: id("net.localhost"), title: "App → http://localhost")
        let control = await URLCheck.run(name: "internet", url: URL(string: "http://example.com/")!)
        let facts = Self.facts(control)
        if control.blockedByATS {
            results.set(id("net.ats-control"), test: 2, "ATS still refuses plain HTTP to the internet", .passed,
                        control.summary, facts: facts)
        } else {
            results.set(id("net.ats-control"), test: 2, "ATS still refuses plain HTTP to the internet", .failed,
                        "Expected App Transport Security to refuse http://example.com/, got: \(control.summary)", facts: facts)
        }
    }

    /// Reads the dashboard address on the network. On the first run it keeps trying for a while, since
    /// the first read raises the Local Network prompt and fails until it is answered.
    func runLANCheck(patient: Bool = true) async {
        guard let url = options.lanURL else {
            results.set(id("net.lan"), test: 2, "App → your network", .skipped, "No --lan-url was given.")
            return
        }
        lanRunning = true
        defer { lanRunning = false }
        let started = Date()
        var attempts = 0
        var first: URLCheckOutcome?
        var last: URLCheckOutcome
        repeat {
            attempts += 1
            last = await URLCheck.run(name: "lan", url: url, timeout: 8)
            if first == nil { first = last }
            if last.ok || !patient { break }
            results.set(id("net.lan"), test: 2, "App → your network", .running,
                        "Attempt \(attempts): \(last.summary). If macOS asks about your local network, click Allow.")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        } while Date().timeIntervalSince(started) < 90
        var facts = Self.facts(last)
        facts["attempts"] = "\(attempts)"
        facts["seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        if let first, attempts > 1 { facts["firstAttempt"] = first.summary }
        if let host = url.host {
            facts["tcpProbe"] = await URLCheck.probe(host: host, port: UInt16(exactly: url.port ?? 80) ?? 80)
        }
        let detail = last.ok ? "\(last.summary) after \(attempts) attempt\(attempts == 1 ? "" : "s")" : last.summary
        results.set(id("net.lan"), test: 2, "App → your network", last.ok ? .passed : .failed, detail, facts: facts)
    }

    func answer(_ id: String, test: Int, _ title: String, _ value: String) {
        results.set(self.id(id), test: test, title, .info, value)
    }

    private func record(_ outcome: URLCheckOutcome, id: String, title: String) {
        results.set(id, test: 2, title, outcome.ok ? .passed : .failed, outcome.summary, facts: Self.facts(outcome))
    }

    static func facts(_ outcome: URLCheckOutcome) -> [String: String] {
        var facts = ["url": outcome.url, "ms": "\(outcome.milliseconds)"]
        if let code = outcome.errorCode { facts["error"] = "\(outcome.errorDomain ?? "") \(code)" }
        if outcome.localNetworkDenied { facts["localNetworkDenied"] = "yes" }
        if outcome.blockedByATS { facts["blockedByATS"] = "yes" }
        if let path = outcome.path { facts["path"] = path }
        return facts
    }

    func askWidgetAgain() {
        WidgetCenter.shared.reloadAllTimelines()
        results.event("Asked WidgetKit to reload the test widget's timeline.")
    }

    /// The widget sends each report to the listener, and also leaves it in the App Group container,
    /// which this checks every few seconds in case a report was sent while the app wasn't listening.
    private func watchWidgetReports() {
        Task { [weak self] in
            while let self, !self.done {
                if let report = StoreTestShared.read(StoreTestShared.WidgetReport.self, "widget-report.json") {
                    self.take(report)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func take(_ report: StoreTestShared.WidgetReport) {
        // The widget both sends each report and leaves it in the App Group container, so the same one
        // can arrive twice; one from before this run started isn't this run's.
        guard report.at >= startedAt.addingTimeInterval(-1), seenWidgetReports.insert(report.id).inserted else { return }
        widgetReports.append(report)
        if !report.configFound {
            results.set("widget.config", test: 2, "Widget read the shared settings", .failed,
                        "The widget couldn't read config.json from the App Group container.")
            return
        }
        results.set("widget.config", test: 2, "Widget read the shared settings", .passed,
                    "The widget ran (\(report.source), \(report.family)).")
        for outcome in report.outcomes {
            var facts = Self.facts(outcome)
            facts["source"] = report.source
            facts["family"] = report.family
            let title = outcome.name == "lan" ? "Widget → your network" : "Widget → http://127.0.0.1"
            results.set("widget.\(outcome.name)", test: 2, title, outcome.ok ? .passed : .failed, outcome.summary, facts: facts)
        }
    }

    // MARK: - Test 3: folders

    func choose(_ kind: FolderKind) {
        let title = "Open panel → \(kind.folderName)"
        guard let url = FolderAccess.choose(kind) else {
            results.set("folders.\(kind.rawValue)", test: 3, title, .failed, "The Open panel was cancelled.")
            return
        }
        var facts = ["picked": url.lastPathComponent]
        var saved = false
        do {
            facts["bookmarkBytes"] = "\(try FolderAccess.saveBookmark(for: url, kind: kind))"
            saved = true
        } catch {
            facts["bookmarkError"] = "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)"
        }
        let reading = FolderAccess.inspect(url, kind: kind)
        facts.merge(reading.facts) { first, _ in first }
        let rightFolder = url.lastPathComponent == kind.folderName
        var detail = reading.summary
        if !rightFolder { detail += " (that is \(url.lastPathComponent), not \(kind.folderName))" }
        if !saved { detail += " The bookmark couldn't be saved." }
        results.set("folders.\(kind.rawValue)", test: 3, title, reading.ok && rightFolder && saved ? .passed : .failed,
                    detail, facts: facts)
    }

    // MARK: - Test 4: status line hand-off

    func makeSnippet(userCommand: String, purpose: String) -> String {
        guard let port = listenerPort, let token = options.token else { return "" }
        let command = StatusLineSnippet.command(port: Int(port), token: token, userCommand: userCommand)
        if purpose != "test" {
            snippet = command
            let trimmed = userCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            results.set("statusline.snippet", test: 4, "Status line snippet built", .passed,
                        "\(command.count) characters, wrapping \(trimmed.isEmpty ? "no existing status line" : "your existing status line command").",
                        facts: ["usesJQ": command.contains("/usr/bin/jq") ? "yes, with a sed fallback" : "no"])
        }
        return command
    }

    private func receiveStatusLine(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            results.event("Status line: got \(body.count) bytes that aren't a JSON object.")
            return
        }
        let keys = object.keys.sorted()
        let limits = object["rate_limits"] as? [String: Any]
        var windows: [String: StatusLineReading.Window] = [:]
        for (name, value) in limits ?? [:] {
            guard let window = value as? [String: Any] else { continue }
            windows[name] = StatusLineReading.Window(usedPercentage: (window["used_percentage"] as? NSNumber)?.doubleValue,
                                                     resetsAt: (window["resets_at"] as? NSNumber)?.doubleValue)
        }
        let selfTest = selfTestRunning || windows.values.contains { $0.resetsAt == Self.sampleResetsAt }
        let reading = StatusLineReading(at: Date(), hasRateLimits: limits != nil, windows: windows,
                                        topLevelKeys: keys, selfTest: selfTest, bytes: body.count)
        statusReadings.append(reading)
        let names = windows.keys.sorted()
        results.event("Status line \(selfTest ? "self-test" : "reading"): keys \(keys), windows \(names)")
        if selfTest {
            sampleReadings += 1
            if !Self.isExactSample(reading) { sampleMismatches += 1 }
            results.set("statusline.selftest-content", test: 4, "Self-tests sent exactly the sample's limits",
                        sampleMismatches == 0 ? .passed : .failed,
                        sampleMismatches == 0
                            ? "All \(sampleReadings) self-test readings held only rate_limits, with the sample's numbers."
                            : "\(sampleMismatches) of \(sampleReadings) didn't; the last had keys \(keys) and windows \(names).")
            return
        }
        claudeReadings.append(reading)
        var facts: [String: String] = ["readings": "\(claudeReadings.count)", "keysSent": keys.joined(separator: ", ")]
        for (name, window) in windows {
            let used = window.usedPercentage.map { String(format: "%.0f%% used", $0) } ?? "no percentage"
            let reset = window.resetsAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "no reset time"
            facts[name] = "\(used), resets \(reset)"
        }
        let onlyLimits = keys == ["rate_limits"]
        let status: CheckStatus = !onlyLimits ? .failed : (windows.isEmpty ? .info : .passed)
        let detail: String
        if !onlyLimits {
            detail = "The snippet sent more than rate_limits: \(keys.joined(separator: ", "))."
        } else if limits == nil {
            detail = "A reading arrived without rate_limits (Claude Code adds them after its first reply)."
        } else if windows.isEmpty {
            detail = "A reading arrived with rate_limits but no windows in it."
        } else {
            detail = "Got \(names.joined(separator: " and ")) from Claude Code."
        }
        results.set("statusline.claude", test: 4, "Readings from Claude Code's status line", status, detail, facts: facts)
        let everWeekly = claudeReadings.contains { $0.windows["seven_day"] != nil }
        let everFiveHour = claudeReadings.contains { $0.windows["five_hour"] != nil }
        results.set("statusline.windows", test: 4, "Which limits Claude Code reports for this account",
                    everWeekly ? .passed : .info,
                    "Weekly: \(everWeekly ? "yes" : "no"); 5-hour: \(everFiveHour ? "yes" : "no").")
    }

    /// The runner's sample has exactly these two windows, both resetting in 2100.
    static func isExactSample(_ reading: StatusLineReading) -> Bool {
        reading.topLevelKeys == ["rate_limits"] && reading.windows.count == 2
            && reading.windows["five_hour"]?.usedPercentage == 11.5
            && reading.windows["seven_day"]?.usedPercentage == 22.5
            && reading.windows.values.allSatisfy { $0.resetsAt == sampleResetsAt }
    }

    // MARK: - Automatic phases

    private func runAutomaticPhase() async {
        results.set(id("phase"), test: 0, "Automatic checks after the \(phaseName)", .running, "Running…")
        await runLoopbackChecks()
        if options.lanURL != nil { await runLANCheck(patient: false) }
        for kind in FolderKind.allCases {
            let reading = FolderAccess.readSaved(kind)
            results.set(id("folders.\(kind.rawValue)"), test: 3, "Bookmark to \(kind.folderName) after the \(phaseName)",
                        reading.ok ? .passed : .failed, reading.summary, facts: reading.facts)
        }
        await codexAfterRestart(signOutAfter: options.phase == .update)
        results.set(id("phase"), test: 0, "Automatic checks after the \(phaseName)", .passed, "Finished.")
        done = true
        // The runner quits the app after saving the results; if it doesn't, quit after a while.
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            NSApp.terminate(nil)
        }
    }

    // MARK: - The runner's requests

    func handle(_ head: HTTPRequestHead, _ body: Data) async -> HTTPResponse {
        let path = head.path
        if head.method == "GET", path == "/ping" {
            return .json(["ok": true, "app": "AI Usage Store Test", "phase": options.phase.rawValue])
        }
        guard let token = options.token, head.headers["x-ai-usage-token"] == token else {
            results.event("Refused \(head.method) \(path): wrong or missing token.")
            return .text("Forbidden", status: 403)
        }
        switch (head.method, path) {
        case ("GET", "/state"):
            return .text(stateLine())
        case ("GET", "/results"):
            return .encoded(report())
        case ("GET", "/summary"):
            return .text(summaryText())
        case ("POST", "/snippet"):
            let command = makeSnippet(userCommand: String(decoding: body, as: UTF8.self),
                                      purpose: head.headers["x-snippet-purpose"] ?? "real")
            return command.isEmpty ? .text("The listener isn't ready.", status: 503) : .text(command)
        case ("POST", "/note"):
            return note(body)
        case ("POST", "/claude-status"):
            receiveStatusLine(body)
            return .text("")
        case ("POST", "/selftest"):
            selfTestRunning = String(decoding: body, as: UTF8.self) == "start"
            results.event("Status line self-tests \(selfTestRunning ? "started" : "finished").")
            return .text("")
        case ("POST", "/widget-result"):
            if let report = try? StoreTestShared.decoder.decode(StoreTestShared.WidgetReport.self, from: body) {
                take(report)
            }
            return .text("")
        case ("POST", "/quit"):
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return .text("Quitting")
        default:
            return .text("Not found", status: 404)
        }
    }

    private struct Note: Decodable {
        var id: String
        var test: Int
        var title: String
        var status: CheckStatus
        var detail: String
        var facts: [String: String]?
    }

    /// The runner records what it saw (self-test timings, your answers in Terminal) with the app's results.
    private func note(_ body: Data) -> HTTPResponse {
        guard let note = try? JSONDecoder().decode(Note.self, from: body) else {
            return .text("Bad note", status: 400)
        }
        results.set(note.id, test: note.test, note.title, note.status, note.detail, facts: note.facts ?? [:])
        return .text("")
    }

    func stateLine() -> String {
        "phase=\(options.phase.rawValue) handoff=\(handoff ? 1 : 0) done=\(done ? 1 : 0) claude=\(claudeReadings.count) sample=\(sampleReadings) samplebad=\(sampleMismatches) widget=\(widgetReports.count) codex=\(codexRunning ? "busy" : "idle")"
    }

    func report() -> Report {
        Report(app: AppInfo(version: version, build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                            phase: options.phase.rawValue, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                            sandboxed: StoreTestShared.sandboxed, appGroup: StoreTestShared.appGroup != nil,
                            listenerPort: listenerPort.map(Int.init),
                            helperSigning: CodexHelper.executable.map(CodeSigning.summary(of:)) ?? "missing",
                            codexVersion: codexVersion, startedAt: startedAt),
               checks: results.checks, events: results.events, codexLog: codexLog, contacts: contacts,
               widgetReports: widgetReports, statusReadings: statusReadings, handoff: handoff, done: done)
    }

    func summaryText() -> String {
        results.summary(header: "AI Usage Store Test \(version), \(phaseName), \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func copyResults() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText(), forType: .string)
        results.event("Copied the results to the clipboard.")
    }

    func continueInTerminal() {
        handoff = true
        results.event("Steps 1 to 3 finished; Terminal takes over for the status line check.")
    }
}

/// Reads a code signature: its identifier, whether the hardened runtime is on, and its entitlement keys.
enum CodeSigning {
    static func summary(of url: URL) -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return "signature unreadable"
        }
        var information: CFDictionary?
        // Entitlements come only with the requirement information.
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        let status = SecCodeCopySigningInformation(staticCode, flags, &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return "signature unreadable (\(status))"
        }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?.keys.sorted() ?? []
        let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? "?"
        let hardened = codeFlags & 0x10000 != 0
        return "\(identifier); hardened runtime \(hardened ? "on" : "off"); entitlements: \(entitlements.isEmpty ? "none" : entitlements.joined(separator: ", "))"
    }
}
