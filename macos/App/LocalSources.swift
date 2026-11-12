import AppKit
import Combine
import AIUsageKit

enum ClaudeDesktopConnection: Equatable {
    case checking, reading([LimitWindow]), unavailable(ClaudeDesktopUsage.Problem)

    var windows: [LimitWindow] {
        if case .reading(let values) = self { return values }
        return []
    }
}

@MainActor
final class LocalSources: ObservableObject {
    private let defaults: UserDefaults
    #if CLAUDE_QUOTA_TEST
    let claudeLive: ClaudeTestQuota
    private var claudeObserver: AnyCancellable?
    #endif
    private let history = HistoryReader(cacheURL: HistoryReader.defaultCacheURL)
    private let account = ChatGPTAccount()
    private var listener: LoopbackServer?
    private var googleQuotaCheck: Task<[LimitWindow], Error>?
    private var listenerGeneration = 0
    private let prices: LocalPrices? = Bundle.main.url(forResource: "pricing", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(LocalPrices.self, from: $0) }
    @Published private(set) var selected: Set<HistoryProvider> = []
    @Published private(set) var chatConnected = false
    @Published private(set) var accountBusy = false
    @Published private(set) var chatQuotaIssue: String?
    @Published private var codexHistoryObservedAt: Date?
    @Published private(set) var statusLineEnabled = false
    @Published private(set) var statusLineReady = false
    @Published private(set) var claudeRequestCopied = false
    @Published private(set) var claudeSetupError: String?
    @Published private(set) var claudeDesktop: ClaudeDesktopConnection?
    @Published private(set) var enteredDesktopUsage: ClaudeDesktopUsage.Entry?
    @Published private(set) var googleQuotaConnected = false
    @Published private(set) var googleQuotaObservedAt: Date?
    private static let googleQuotaHelp = "See the quota Google reports for Gemini and other model groups. Sign in to the Antigravity desktop app on this Mac and keep it running. Connect opens it and asks for folder access if needed."
    @Published private(set) var googleQuotaStatus = LocalSources.googleQuotaHelp
    @Published private(set) var messages: [HistoryProvider: String] = [:]
    @Published private(set) var historyIssues: [HistoryProvider: String] = [:]
    @Published var notice: String?
    var changed: (() -> Void)?
    var connectionStateChanged: (() -> Void)?
    private var active = false
    private(set) var revision = 0
    @Published private var windows: [HistoryProvider: [LimitWindow]] = [:]

    var hasSources: Bool {
        #if CLAUDE_QUOTA_TEST
        if claudeLive.enabled { return true }
        #endif
        return !selected.isEmpty || chatConnected || claudeDesktop != nil || statusLineEnabled || googleQuotaConnected
    }

    func lastQuotaReading(_ provider: HistoryProvider) -> Date? {
        #if CLAUDE_QUOTA_TEST
        if provider == .claude, claudeLive.enabled { return claudeLive.windows.first?.observedAt }
        #endif
        if provider == .claude, claudeDesktop != nil { return desktopWindows.first?.observedAt }
        if provider == .antigravity { return googleQuotaObservedAt }
        if provider == .codex && !chatConnected { return codexHistoryObservedAt }
        return windows[provider]?.compactMap(\.observedAt).max()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if CLAUDE_QUOTA_TEST
        claudeLive = ClaudeTestQuota(defaults: defaults)
        claudeObserver = claudeLive.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        claudeLive.changed = { [weak self] discard in self?.sourcesChanged(discardReadings: discard) }
        #endif
        selected = Set(HistoryProvider.allCases.filter { defaults.data(forKey: bookmarkKey($0)) != nil })
        chatConnected = defaults.bool(forKey: "chatConnected")
        statusLineEnabled = defaults.bool(forKey: "claudeStatusLine")
        if defaults.data(forKey: "claudeDesktopFolder") != nil {
            claudeDesktop = .checking
            if let data = defaults.data(forKey: "claudeDesktopEntry") {
                enteredDesktopUsage = try? JSONDecoder().decode(ClaudeDesktopUsage.Entry.self, from: data)
            }
        }
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
        if enabled { publishConnectionState() }
        if enabled && receiveStatusLine && statusLineEnabled { startListener() }
        #if CLAUDE_QUOTA_TEST
        if !enabled { claudeLive.suspend() }
        #endif
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
                .appendingPathComponent(provider.folder, isDirectory: true)
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
            let replacing = !selected.insert(provider).inserted
            if provider == .codex { codexHistoryObservedAt = nil }
            historyIssues[provider] = nil
            messages[provider] = "Reading history…"
            sourcesChanged(discardReadings: replacing, forgetProvider: replacing ? provider : nil)
        } catch { notice = "Could not save read-only access. Choose the folder again." }
    }
    func forget(_ provider: HistoryProvider) {
        defaults.removeObject(forKey: bookmarkKey(provider))
        selected.remove(provider)
        if provider == .codex { codexHistoryObservedAt = nil }
        historyIssues[provider] = nil
        messages[provider] = nil
        sourcesChanged(discardReadings: true, forgetProvider: provider)
    }

    private static var claudeDesktopDirectory: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    func connectClaudeDesktop() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil,
              let folder = Self.claudeDesktopDirectory else {
            notice = "Install and open Claude Desktop on this Mac, sign in, and try again."
            return
        }
        let panel = NSOpenPanel()
        panel.prompt = "Allow"
        panel.message = "Allow access to the Claude folder. AI Usage reads only the saved plan usage file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard selected.standardizedFileURL == folder.standardizedFileURL else {
            notice = "Choose the Claude folder inside Library/Application Support. The connection button opens that folder for you."
            return
        }
        do {
            let grant = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
            let replacing = claudeDesktop != nil || (statusLineEnabled && lastQuotaReading(.claude) != nil)
            defaults.set(grant, forKey: "claudeDesktopFolder")
            // Keep an already configured terminal connection intact for a future switch back.
            stopListener()
            claudeDesktop = .checking
            sourcesChanged(discardReadings: replacing)
        } catch { notice = "Couldn’t save read-only access to the Claude folder. Try again." }
    }

    func disconnectClaudeDesktop() {
        defaults.removeObject(forKey: "claudeDesktopFolder")
        defaults.removeObject(forKey: "claudeDesktopEntry")
        enteredDesktopUsage = nil
        claudeDesktop = nil
        if statusLineEnabled { startListener() }
        sourcesChanged(discardReadings: true)
    }

    var desktopWindows: [LimitWindow] {
        enteredDesktopUsage?.windows ?? claudeDesktop?.windows ?? []
    }

    func recordDesktopUsage(_ entry: ClaudeDesktopUsage.Entry) {
        guard claudeDesktop != nil, let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: "claudeDesktopEntry")
        enteredDesktopUsage = entry
        revision += 1
        changed?()
    }

    private func readClaudeDesktop(now: Date) async -> ClaudeDesktopConnection {
        guard let grant = defaults.data(forKey: "claudeDesktopFolder") else { return .unavailable(.access) }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: grant, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            guard folder.standardizedFileURL == Self.claudeDesktopDirectory?.standardizedFileURL,
                  folder.startAccessingSecurityScopedResource() else { return .unavailable(.access) }
            defer { folder.stopAccessingSecurityScopedResource() }
            if stale, let renewed = try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                             includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(renewed, forKey: "claudeDesktopFolder")
            }
            let values = try await Task.detached(priority: .utility) {
                try ClaudeDesktopUsage.windows(in: folder, now: now)
            }.value
            return .reading(values)
        } catch { return .unavailable((error as? ClaudeDesktopUsage.Problem) ?? .access) }
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
        sourcesChanged(discardReadings: false)
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
        googleQuotaObservedAt = nil
        googleQuotaStatus = Self.googleQuotaHelp
        sourcesChanged(discardReadings: true)
    }

    private func cancelGoogleQuotaCheck() {
        googleQuotaCheck?.cancel()
        googleQuotaCheck = nil
    }

    func cancelHungChecks() {
        cancelGoogleQuotaCheck()
        #if CLAUDE_QUOTA_TEST
        claudeLive.cancelStuckRead()
        #endif
    }

    private func readGoogleQuota() async throws -> [LimitWindow] {
        try Task.checkCancellation()
        guard let data = defaults.data(forKey: "googleQuotaFolder") else { throw AntigravityQuotaError.permission }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw AntigravityQuotaError.permission }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale, let updated = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(updated, forKey: "googleQuotaFolder")
        }
        guard let directory = AntigravityQuotaReader.directory(in: url) else { throw AntigravityQuotaError.permission }
        return try await AntigravityQuotaReader.read(directory: directory)
    }
    private func publishConnectionState(discardReadings: Bool = false) {
        guard active else { return }
        do {
            if try SharedStore.prepareLocal(hasSources: hasSources, discardReadings: discardReadings) {
                connectionStateChanged?()
            }
        }
        catch { notice = "Couldn’t update the widget’s connection status. Reopen AI Usage and try again." }
    }

    private func sourcesChanged(discardReadings: Bool, forgetProvider: HistoryProvider? = nil) {
        revision += 1
        publishConnectionState(discardReadings: discardReadings)
        if let forgetProvider { Task { await history.forget(provider: forgetProvider); changed?() } }
        else { changed?() }
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
                chatQuotaIssue = nil
                keep(nil, for:.codex)
                sourcesChanged(discardReadings: !chatConnected)
            } catch {
                notice = (error as? ChatGPTAccount.Problem)?.localizedDescription ?? "Could not connect to OpenAI. Try again."
            }
        }
    }

    func toggleStatusLine(_ enabled: Bool) {
        let wasEnabled = statusLineEnabled
        statusLineEnabled = enabled
        claudeSetupError = nil
        defaults.set(enabled, forKey:"claudeStatusLine")
        if enabled {
            if !wasEnabled { sourcesChanged(discardReadings: false) }
            startListener()
        }
        else {
            stopListener()
            claudeRequestCopied = false
            keep(nil, for: .claude)
            defaults.removeObject(forKey: "statusToken")
            sourcesChanged(discardReadings: true)
        }
    }
    private func stopListener() {
        listenerGeneration += 1
        listener?.stop(); listener = nil; statusLineReady = false
    }
    private func startListener() {
        guard active, statusLineEnabled, claudeDesktop == nil, listener == nil else { return }
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
                guard let bound else {
                    stopListener()
                    claudeSetupError = "AI Usage couldn’t start the connection. Close any other copy of this app and try again."
                    return
                }
                defaults.set(Int(bound),forKey:"statusPort")
                statusLineReady = true
                claudeSetupError = nil
                changed?()
            }
        } catch { claudeSetupError = "AI Usage couldn’t start the connection. Try again." }
    }
    private func receive(_ values: [LimitWindow], generation: Int) {
        guard active, statusLineEnabled, listenerGeneration == generation else { return }
        keep(values, for:.claude); changed?()
    }
    func copyClaudeSetupRequest() {
        guard let executable = Bundle.main.executableURL else { notice = "Reopen AI Usage from Applications and try again."; return }
        toggleStatusLine(true)
        NSPasteboard.general.clearContents()
        claudeRequestCopied = NSPasteboard.general.setString(ClaudeStatusReading.setupRequest(executable: executable), forType: .string)
        if !claudeRequestCopied { notice = "Couldn’t copy the setup request. Try again." }
    }

    func collectQuotas(now: Date) async -> (limits: [HistoryProvider: [LimitWindow]], issues: [HistoryProvider: String]) {
        let run = revision
        var issues: [HistoryProvider: String] = [:]
        var connectedLimits: [HistoryProvider: [LimitWindow]] = [:]

        if chatConnected && !accountBusy {
            do {
                let latest = try await account.limits()
                guard active && run == revision else { return ([:], [:]) }
                keep(latest, for: .codex)
                chatQuotaIssue = nil
            } catch {
                guard active && run == revision else { return ([:], [:]) }
                let message = "Couldn’t refresh ChatGPT limits. Check your connection and try Refresh now."
                issues[.codex] = message
                chatQuotaIssue = message
            }
        }
        if chatConnected { connectedLimits[.codex] = windows[.codex] ?? [] }

        #if CLAUDE_QUOTA_TEST
        if claudeLive.enabled {
            await claudeLive.checkIfDue()
            guard active && run == revision else { return ([:], [:]) }
            connectedLimits[.claude] = claudeLive.windows
            if claudeLive.state != .current { issues[.claude] = claudeLive.status }
        }
        #endif
        if connectedLimits[.claude] == nil, claudeDesktop != nil {
            let state = await readClaudeDesktop(now: now)
            guard active && run == revision else { return ([:], [:]) }
            if state != claudeDesktop { claudeDesktop = state }
            if let entry = enteredDesktopUsage, let saved = state.windows.first?.observedAt, saved >= entry.recordedAt {
                enteredDesktopUsage = nil
                defaults.removeObject(forKey: "claudeDesktopEntry")
            }
            connectedLimits[.claude] = desktopWindows
            if enteredDesktopUsage == nil, case .unavailable(let problem) = state { issues[.claude] = problem.rawValue }
        } else if connectedLimits[.claude] == nil, statusLineEnabled {
            connectedLimits[.claude] = windows[.claude] ?? []
            if let claudeSetupError { issues[.claude] = claudeSetupError }
        }

        if googleQuotaConnected {
            cancelGoogleQuotaCheck()
            let check = Task { try await readGoogleQuota() }
            googleQuotaCheck = check
            do {
                let windows = try await check.value
                guard active && run == revision else { return ([:], [:]) }
                connectedLimits[.antigravity] = windows
                googleQuotaObservedAt = windows.compactMap(\.observedAt).max()
                googleQuotaStatus = "Connected · \(windows.count) quota windows"
            } catch {
                guard active && run == revision else { return ([:], [:]) }
                let reason = (error as? AntigravityQuotaError)?.rawValue ?? AntigravityQuotaError.permission.rawValue
                connectedLimits[.antigravity] = []
                googleQuotaObservedAt = nil
                googleQuotaStatus = reason
                issues[.antigravity] = reason
            }
            googleQuotaCheck = nil
        }

        return (connectedLimits, issues)
    }

    func fastSnapshot(quotas: (limits: [HistoryProvider: [LimitWindow]], issues: [HistoryProvider: String]), now: Date) async -> SharedStore.LocalSnapshot {
        let cached = await history.cachedHistories(selected: selected, now: now)
        let prices = self.prices
        let currentHistoryIssues = self.historyIssues
        let summaries = await Task.detached(priority: .utility) {
            LocalSummary.build(histories: cached, limits: quotas.limits, issues: quotas.issues,
                               historyIssues: currentHistoryIssues, prices: prices, now: now)
        }.value
        return .init(summaries: summaries, hasSources: hasSources)
    }

    func scanHistories(now: Date) async -> (histories: [HistoryProvider: LocalHistory], historyErrors: [HistoryProvider: String]) {
        let run = revision
        var histories: [HistoryProvider: LocalHistory] = [:]
        var historyErrors: [HistoryProvider: String] = [:]
        var status: [HistoryProvider: String] = [:]
        for provider in selected {
            guard let data = defaults.data(forKey: bookmarkKey(provider)) else { continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                if stale, let updated = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(updated, forKey: bookmarkKey(provider))
                }
                let reading = try await history.scan(provider, at: url, now: now)
                histories[provider] = reading
                let requestCount = reading.events.values.reduce(0) { $0 + $1.requests }
                status[provider] = reading.events.isEmpty ? "Connected · no usage in the last 30 days" :
                    "Connected · \(requestCount.formatted()) recorded requests"
            } catch {
                let message = "History could not be read. Choose the folder again."
                historyErrors[provider] = message
                status[provider] = message
            }
            guard active && run == revision else { return ([:], [:]) }
        }
        await history.flushCache()
        codexHistoryObservedAt = histories[.codex]?.windows.compactMap(\.observedAt).max()
        if messages != status { messages = status }
        if historyIssues != historyErrors { historyIssues = historyErrors }
        return (histories, historyErrors)
    }

    func fullSnapshot(quotas: (limits: [HistoryProvider: [LimitWindow]], issues: [HistoryProvider: String]),
                      histories: [HistoryProvider: LocalHistory],
                      historyErrors: [HistoryProvider: String], now: Date) async -> SharedStore.LocalSnapshot {
        let prices = self.prices
        let summaries = await Task.detached(priority: .utility) {
            LocalSummary.build(histories: histories, limits: quotas.limits, issues: quotas.issues,
                               historyIssues: historyErrors, prices: prices, now: now)
        }.value
        return .init(summaries: summaries, hasSources: hasSources)
    }

    func collect(now: Date) async -> SharedStore.LocalSnapshot? {
        let run = revision
        let quotas = await collectQuotas(now: now)
        guard active && run == revision else { return nil }
        let (histories, historyErrors) = await scanHistories(now: now)
        guard active && run == revision else { return nil }
        return await fullSnapshot(quotas: quotas, histories: histories, historyErrors: historyErrors, now: now)
    }
}
