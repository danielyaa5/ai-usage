import AppKit
import AIUsageKit

@MainActor
final class LocalSources: ObservableObject {
    private let defaults: UserDefaults
    private let history = HistoryReader()
    private let account = ChatGPTAccount()
    private var listener: LoopbackServer?
    private var googleQuotaCheck: Task<[LimitWindow], Error>?
    private var listenerGeneration = 0
    private let prices: LocalPrices? = Bundle.main.url(forResource: "pricing", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(LocalPrices.self, from: $0) }
    @Published private(set) var selected: Set<HistoryProvider> = []
    @Published private(set) var chatConnected = false
    @Published private(set) var accountBusy = false
    @Published private(set) var statusLineEnabled = false
    @Published private(set) var statusLineReady = false
    @Published private(set) var googleQuotaConnected = false
    private static let googleQuotaHelp = "Read remaining percentages and reset times. Connect opens Antigravity if needed."
    @Published private(set) var googleQuotaStatus = LocalSources.googleQuotaHelp
    @Published private(set) var messages: [HistoryProvider: String] = [:]
    @Published var notice: String?
    var changed: (() -> Void)?
    private var active = false
    private var revision = 0
    private var windows: [HistoryProvider: [LimitWindow]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = Set(HistoryProvider.allCases.filter { defaults.data(forKey: bookmarkKey($0)) != nil })
        chatConnected = defaults.bool(forKey: "chatConnected")
        statusLineEnabled = defaults.bool(forKey: "claudeStatusLine")
        googleQuotaConnected = defaults.data(forKey: "googleQuotaFolder") != nil
        if googleQuotaConnected { googleQuotaStatus = "Waiting for the next quota check…" }
        for provider in [HistoryProvider.claude, .codex] {
            if let data = defaults.data(forKey: windowKey(provider)),
               let saved = try? JSONDecoder().decode([LimitWindow].self, from: data) { windows[provider] = saved }
        }
    }

    private func bookmarkKey(_ p: HistoryProvider) -> String { "source.bookmark.\(p.rawValue)" }
    private func windowKey(_ p: HistoryProvider) -> String { "source.windows.\(p.rawValue)" }
    private func keep(_ values: [LimitWindow]?, for provider: HistoryProvider) {
        windows[provider] = values
        if let values { defaults.set(try? JSONEncoder().encode(values), forKey: windowKey(provider)) }
        else { defaults.removeObject(forKey: windowKey(provider)) }
    }
    func activate(_ enabled: Bool, receiveStatusLine: Bool = true) {
        active = enabled
        revision += 1
        if enabled && receiveStatusLine && statusLineEnabled { startListener() }
        if !enabled { stopListener(); account.cancel(); cancelGoogleQuotaCheck() }
    }

    func pick(_ provider: HistoryProvider) {
        let panel = NSOpenPanel()
        panel.prompt = "Connect"
        panel.message = "Choose the \(provider.folder) folder for \(provider.title). AI Usage reads its usage history."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ok = provider.logDirectories.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            guard url.lastPathComponent == provider.folder || ok else {
                notice = "Choose the \(provider.folder) folder, or a custom folder containing \(provider.logDirectories.first!)."
                return
            }
            let bookmark = try url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys:nil, relativeTo:nil)
            defaults.set(bookmark, forKey:bookmarkKey(provider))
            selected.insert(provider)
            messages[provider] = "Reading history…"
            invalidateHistory()
        } catch { notice = "Could not save read-only access. Choose the folder again." }
    }
    func forget(_ provider: HistoryProvider) {
        defaults.removeObject(forKey: bookmarkKey(provider))
        selected.remove(provider)
        messages[provider] = nil
        invalidateHistory()
    }

    @discardableResult
    func connectGoogleQuota() -> String? {
        guard !googleQuotaConnected else { return nil }
        let appID = "com.google.antigravity"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else {
            googleQuotaStatus = "Install and open the Antigravity desktop app, sign in, then connect quota."
            return googleQuotaStatus
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: options) { [weak self] _, error in
                Task { @MainActor in
                    guard error == nil else { return }
                    try? await Task.sleep(for: .seconds(4))
                    if let self, self.active && self.googleQuotaConnected { self.changed?() }
                }
            }
        }
        var bookmark = antigravityHistoryGrant()
        if bookmark == nil {
            let panel = NSOpenPanel()
            panel.prompt = "Allow"
            panel.message = "Allow read-only access to Antigravity’s daemon folder so AI Usage can connect to its quota service on this Mac."
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.showsHiddenFiles = true
            panel.directoryURL = AntigravityQuotaReader.registrationDirectory
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            guard let daemon = AntigravityQuotaReader.directory(in: url) else {
                googleQuotaStatus = "Choose the daemon folder in ~/.gemini/antigravity. Open Antigravity once if it’s missing."
                return googleQuotaStatus
            }
            bookmark = (try? daemon.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                          includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        guard let bookmark else { googleQuotaStatus = AntigravityQuotaError.permission.rawValue; return googleQuotaStatus }
        defaults.set(bookmark, forKey: "googleQuotaFolder")
        googleQuotaConnected = true
        googleQuotaStatus = "Checking Antigravity on this Mac…"
        revision += 1
        changed?()
        return nil
    }

    private func antigravityHistoryGrant() -> Data? {
        guard let data = defaults.data(forKey: bookmarkKey(.antigravity)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let daemon = AntigravityQuotaReader.directory(in: url) else { return nil }
        return (try? daemon.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data
    }

    func disconnectGoogleQuota() {
        cancelGoogleQuotaCheck()
        defaults.removeObject(forKey: "googleQuotaFolder")
        googleQuotaConnected = false
        googleQuotaStatus = Self.googleQuotaHelp
        invalidateHistory()
    }

    private func cancelGoogleQuotaCheck() {
        googleQuotaCheck?.cancel()
        googleQuotaCheck = nil
    }

    private func readGoogleQuota() async throws -> [LimitWindow] {
        try Task.checkCancellation()
        guard let data = defaults.data(forKey: "googleQuotaFolder") else { throw AntigravityQuotaError.permission }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw AntigravityQuotaError.permission }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale {
            let updated = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(updated, forKey: "googleQuotaFolder")
        }
        guard let directory = AntigravityQuotaReader.directory(in: url) else { throw AntigravityQuotaError.permission }
        return try await AntigravityQuotaReader.read(directory: directory)
    }
    private func invalidateHistory() {
        revision += 1
        // Immediately drop previous totals on disconnect or replacement, even if a scan is in flight.
        try? SharedStore.publishLocal(.init(summaries: [:]))
        Task { await history.forget(); changed?() }
    }
    func cancelLogin() { account.cancel() }
    func toggleAccount() {
        guard !accountBusy else { return }
        accountBusy = true
        Task {
            defer { accountBusy = false; changed?() }
            do {
                if chatConnected { try await account.disconnect(); chatConnected = false }
                else { try await account.connect(); chatConnected = true }
                defaults.set(chatConnected, forKey:"chatConnected")
                keep(nil, for:.codex)
                invalidateHistory()
            } catch {
                notice = (error as? ChatGPTAccount.Problem)?.localizedDescription ?? "Could not connect to OpenAI. Try again."
            }
        }
    }

    func toggleStatusLine(_ enabled: Bool) {
        statusLineEnabled = enabled
        defaults.set(enabled, forKey:"claudeStatusLine")
        if enabled { startListener() }
        else { stopListener(); keep(nil,for:.claude); defaults.removeObject(forKey:"statusToken"); revision += 1; changed?() }
    }
    private func stopListener() {
        listenerGeneration += 1
        listener?.stop(); listener = nil; statusLineReady = false
    }
    private func startListener() {
        guard active, statusLineEnabled, listener == nil else { return }
        let generation = listenerGeneration
        let token = defaults.string(forKey:"statusToken") ?? UUID().uuidString
        defaults.set(token,forKey:"statusToken")
        do {
            let port = UInt16(exactly: defaults.integer(forKey:"statusPort")) ?? 0
            let server = try LoopbackServer(port:port) { [weak self] head, data in
                guard head.method == "POST", head.path == "/claude-status",
                      head.headers["x-ai-usage-token"] == token else { return .text("Forbidden",status:403) }
                guard data.count <= 8192, let obj = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                      obj.count == 1, let limits = obj["rate_limits"] as? [String:Any] else { return .text("Invalid reading",status:400) }
                let now = Date()
                let values: [LimitWindow] = [("five_hour",300),("seven_day",10080)].compactMap { name, minutes in
                    guard let w = limits[name] as? [String:Any] else { return nil }
                    return LocalLimits.window((w["used_percentage"] as? NSNumber)?.doubleValue, minutes:minutes,
                                    reset:(w["resets_at"] as? NSNumber)?.doubleValue, at:now)
                }
                guard !values.isEmpty else { return .text("No limit windows",status:400) }
                await self?.receive(values, generation:generation)
                return .text("OK")
            }
            listener = server
            Task {
                let bound = await server.start { _ in }
                guard generation == listenerGeneration else { return }
                guard let bound else { stopListener(); notice = "The local status-line port is unavailable. Close the other listener and try again."; return }
                defaults.set(Int(bound),forKey:"statusPort")
                statusLineReady = true
                changed?()
            }
        } catch { notice = "Could not start the local status-line receiver." }
    }
    private func receive(_ values: [LimitWindow], generation: Int) {
        guard active, statusLineEnabled, listenerGeneration == generation else { return }
        keep(values, for:.claude); changed?()
    }
    func copyStatusLine(previousCommand: String) {
        guard statusLineReady, let token = defaults.string(forKey:"statusToken") else { return }
        let command = StatusLineSnippet.command(port:defaults.integer(forKey:"statusPort"),token:token,userCommand:previousCommand)
        guard !command.isEmpty, let data = try? JSONSerialization.data(withJSONObject:["statusLine":["type":"command","command":command]],
                        options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]), let json = String(data:data,encoding:.utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType:.string)
        notice = "Copied the statusLine setting. Merge that one setting into your Claude Code settings, then send a message in Claude Code."
    }

    func collect(now: Date) async -> SharedStore.LocalSnapshot? {
        let run = revision
        var histories: [HistoryProvider:LocalHistory] = [:], issues: [HistoryProvider:String] = [:], status: [HistoryProvider:String] = [:]
        for provider in selected {
            guard let data = defaults.data(forKey:bookmarkKey(provider)) else { continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData:data, options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                if stale {
                    defaults.set(try url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys:nil,relativeTo:nil),forKey:bookmarkKey(provider))
                }
                let reading = try await history.scan(provider,at:url,now:now)
                histories[provider] = reading
                status[provider] = reading.events.isEmpty ? "Connected · no usage in the last 30 days" :
                    "Connected · \(reading.events.count.formatted()) recorded requests"
            } catch { issues[provider] = "History could not be read. Choose the folder again." }
            guard active && run == revision else { return nil }
        }
        if chatConnected && !accountBusy {
            do { let latest = try await account.limits(); guard active && run == revision else { return nil }; keep(latest,for:.codex) }
            catch { issues[.codex] = "Could not refresh ChatGPT limits. Check your connection or reconnect." }
        }
        guard active && run == revision else { return nil }
        var connectedLimits: [HistoryProvider:[LimitWindow]] = [:]
        if chatConnected { connectedLimits[.codex] = windows[.codex] ?? [] }
        if statusLineEnabled { connectedLimits[.claude] = windows[.claude] ?? [] }
        if messages != status.merging(issues, uniquingKeysWith: { _, warning in warning }) {
            messages = status.merging(issues, uniquingKeysWith: { _, warning in warning })
        }
        if googleQuotaConnected {
            cancelGoogleQuotaCheck()
            let check = Task { try await readGoogleQuota() }
            googleQuotaCheck = check
            do {
                let windows = try await check.value
                guard active && run == revision else { return nil }
                connectedLimits[.antigravity] = windows
                googleQuotaStatus = "Connected · \(windows.count) quota windows"
            } catch {
                guard active && run == revision else { return nil }
                let reason = (error as? AntigravityQuotaError)?.rawValue ?? AntigravityQuotaError.permission.rawValue
                connectedLimits[.antigravity] = []
                googleQuotaStatus = reason
                issues[.antigravity] = reason
            }
            googleQuotaCheck = nil
        }
        let prices = self.prices
        let summaries = await Task.detached(priority: .utility) {
            LocalSummary.build(histories: histories, limits: connectedLimits, issues: issues, prices: prices, now: now)
        }.value
        guard active && run == revision else { return nil }
        return .init(summaries: summaries)
    }
}
