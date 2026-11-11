import Foundation
#if os(macOS)
import Security
#endif

/// Settings and the last good reading, shared by the app and the widget extension through the App
/// Group container: `config.json` (the dashboard address), `summary-<range>.json` (cached replies,
/// shown when the dashboard can't be reached), `failure-<range>.json` (the app's last failed read,
/// cleared when a read succeeds) and `refresh.json` (when a widget's refresh button was last clicked).
///
/// On macOS the group is the team-prefixed kind ("TEAMID.com.example.AIUsage"), which needs no
/// provisioning profile entry; a `group.` container would need one, and since macOS 15 access to it is
/// denied without one. Each target's Info.plist names the group (`AIUsageAppGroup`, filled in from the
/// build settings), so no team ID is written in the code.
public enum SharedStore {
    public static let appGroup: String? = Bundle.main.object(forInfoDictionaryKey: "AIUsageAppGroup") as? String

    public enum Source: String, Codable, CaseIterable, Sendable { case local, dashboard, demo }

    public struct Config: Codable, Equatable, Sendable {
        public var server: URL?

        // Older installs saved only the address. Preserve their chosen dashboard on update.
        private var selectedSource: Source?
        public var source: Source { selectedSource ?? (server == nil ? .local : .dashboard) }

        public init(server: URL? = nil, source: Source? = nil) {
            self.selectedSource = source
            self.server = server
        }
    }

    public struct Cached: Codable, Sendable {
        public var summary: UsageSummary
        public var fetchedAt: Date
    }

    /// A read of the dashboard that failed.
    public struct Failure: Codable, Equatable, Sendable {
        public var at: Date
        public var error: String
    }

    private struct RefreshStatus: Codable {
        var at: Date?
        var requestedAt: Date?
        var refreshingStartedAt: Date?

        var resolvedRequestedAt: Date? {
            requestedAt ?? at
        }
    }

    /// Tests point this at a temporary folder.
    nonisolated(unsafe) public static var folderOverride: URL?

    public static var folder: URL? {
        if let folderOverride { return folderOverride }
        // Only a build signed with the group may open it: macOS asks the user before an app reads a
        // group container it isn't entitled to, and an unsigned test build would stop at that prompt.
        guard let appGroup, entitledGroups.contains(appGroup) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// The App Groups in this process's code signature.
    public static let entitledGroups: [String] = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
        #else
        return []
        #endif
    }()

    public static var server: URL {
        loadConfig().server ?? UsageClient.defaultServer
    }

    public static func loadConfig() -> Config {
        guard let url = folder?.appendingPathComponent("config.json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    /// Saves the settings. A new dashboard address drops the readings cached from the old one.
    public static func save(_ config: Config) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let changedServer = loadConfig().server != config.server
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: folder.appendingPathComponent("config.json"), options: .atomic)
        if changedServer { clearCache() }
    }

    public static let localURL = URL(string: "aiusage://local")!
    public static let demoURL = URL(string: "aiusage://demo")!

    /// Only sanitized summaries cross from the sandboxed app to its widgets. All three
    /// periods change together so a widget cannot read part of an imported history.
    public struct LocalSnapshot: Codable, Sendable {
        public var summaries: [String: UsageSummary]
        public var issue: String?
        /// Older snapshots did not record whether a source had already been selected.
        public var hasSources: Bool?
        public init(summaries: [String: UsageSummary], issue: String? = nil, hasSources: Bool? = nil) {
            self.summaries = summaries
            self.issue = issue
            self.hasSources = hasSources
        }
    }

    public static func readLocalSnapshot() -> LocalSnapshot? {
        read(LocalSnapshot.self, "this-mac.json")
    }

    public static func publishLocal(_ snapshot: LocalSnapshot) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try cacheEncoder.encode(snapshot).write(to: folder.appendingPathComponent("this-mac.json"), options: .atomic)
    }

    /// Keep an existing authorized reading while adding a source. On disconnect or replacement,
    /// remove the old data immediately and tell the widget whether another reading is on its way.
    @discardableResult
    public static func prepareLocal(hasSources: Bool, discardReadings: Bool = false) throws -> Bool {
        let previous = read(LocalSnapshot.self, "this-mac.json")
        if hasSources, !discardReadings, let previous, !previous.summaries.isEmpty { return false }
        if let previous, previous.summaries.isEmpty, previous.hasSources == hasSources { return false }
        try publishLocal(.init(summaries: [:], hasSources: hasSources))
        return true
    }

    public static func localReading(range: String) -> Reading {
        let snapshot = read(LocalSnapshot.self, "this-mac.json")
        let summary = snapshot?.summaries[range]
        var reading = Reading(summary: summary, fetchedAt: summary?.generatedAt, error: snapshot?.issue, server: localURL)
        if summary == nil {
            switch snapshot?.hasSources {
            case true: reading.localState = .readingSources
            case false: reading.localState = .needsSetup
            default: reading.localState = .openApp
            }
        }
        return reading
    }

    public static func clearCache() {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where (name.hasPrefix("summary-") || name.hasPrefix("failure-")) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    public static func cached(range: String) -> Cached? {
        guard let url = folder?.appendingPathComponent("summary-\(safe(range)).json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? cacheDecoder.decode(Cached.self, from: data)
    }

    /// Keeps a reading for when the dashboard can't be reached. A reading older than the one already
    /// kept is ignored, so two fetches finishing out of order never step the widgets back in time.
    public static func cache(_ summary: UsageSummary, range: String, at date: Date = Date()) {
        guard let folder else { return }
        if let kept = cached(range: range), kept.summary.generatedAt > summary.generatedAt { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try? cacheEncoder.encode(Cached(summary: summary, fetchedAt: date))
        try? data?.write(to: folder.appendingPathComponent("summary-\(safe(range)).json"), options: .atomic)
    }

    /// The app's last failed read of a period, if no read has succeeded since.
    public static func failure(range: String) -> Failure? {
        read(Failure.self, "failure-\(safe(range)).json")
    }

    /// The app records its failed reads, so the widgets can say "Offline" as soon as the app can't
    /// reach the dashboard either, instead of waiting until their own fallback reading gets old.
    public static func recordFailure(_ error: String, range: String, at date: Date = Date()) {
        write(Failure(at: date, error: error), "failure-\(safe(range)).json")
    }

    public static func clearFailure(range: String) {
        guard let url = folder?.appendingPathComponent("failure-\(safe(range)).json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A widget's refresh button asks for a new reading: until one arrives, the widgets read the
    /// dashboard themselves instead of reusing the shared reading.
    public static func requestRefresh(at date: Date = Date()) {
        markRefreshing(at: date)
    }

    public static func markRefreshing(at date: Date = Date()) {
        var status = read(RefreshStatus.self, "refresh.json") ?? RefreshStatus()
        status.refreshingStartedAt = date
        status.requestedAt = date
        write(status, "refresh.json")
    }

    public static func clearRefreshing() {
        guard var status = read(RefreshStatus.self, "refresh.json") else { return }
        status.refreshingStartedAt = nil
        write(status, "refresh.json")
    }

    public static func isRefreshing(now: Date = Date(), timeout: TimeInterval = 90) -> Bool {
        guard let startedAt = read(RefreshStatus.self, "refresh.json")?.refreshingStartedAt else { return false }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed > -5 && elapsed < timeout
    }

    public static var refreshRequested: Date? {
        read(RefreshStatus.self, "refresh.json")?.resolvedRequestedAt
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = folder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? cacheDecoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? cacheEncoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private static func safe(_ range: String) -> String {
        String(range.filter { $0.isLetter || $0.isNumber }.prefix(8))
    }

    private static let cacheDecoder = UsageSummary.decoder
    private static let cacheEncoder = UsageSummary.encoder
}

/// One fetch with the cache as fallback: what the widgets and the app show.
public struct Reading: Sendable {
    public func freshnessNote(now: Date = Date(), staleAfter: TimeInterval = Reading.staleAfter) -> String? {
        if SharedStore.isRefreshing(now: now) { return "Refreshing…" }
        guard summary != nil, let at = fetchedAt ?? summary?.generatedAt else { return nil }
        let time = at.formatted(date: Calendar.current.isDate(at, inSameDayAs: now) ? .omitted : .abbreviated,
                                time: .shortened)
        if error != nil { return "Offline · from \(time)" }
        let elapsed = now.timeIntervalSince(at)
        if elapsed > staleAfter { return "Refresh needed · from \(time)" }
        return nil
    }

    public enum LocalState: String, Sendable { case openApp, readingSources, needsSetup }
    public var localState: LocalState?
    public var summary: UsageSummary?
    /// When `summary` was fetched; older than now when it came from the cache.
    public var fetchedAt: Date?
    /// Why the latest fetch failed, if it did.
    public var error: String?
    public var server: URL

    public init(summary: UsageSummary?, fetchedAt: Date?, error: String?, server: URL) {
        self.summary = summary
        self.fetchedAt = fetchedAt
        self.error = error
        self.server = server
    }

    /// Fetches unless the kept reading is younger than `reuse` (the app refreshes the cache every few
    /// minutes, so the widgets rarely need to ask the dashboard themselves). When the fetch fails, a kept
    /// reading younger than `tolerate` is shown without an error: the app evidently still reaches the
    /// dashboard even if this process can't (a widget can lack the app's local network access).
    ///
    /// Neither applies once the app has recorded a failure since the kept reading, or a refresh was
    /// asked for since. The app passes `record`, so its failures and successes are recorded.
    public static func load(range: String, reuse: TimeInterval = 0, tolerate: TimeInterval = 0,
                            timeout: TimeInterval = 15, record: Bool = false, now: Date = Date()) async -> Reading {
        let config = SharedStore.loadConfig()
        switch config.source {
        case .local:
            return SharedStore.localReading(range: range)
        case .demo:
            let sample = UsageSummary.localSample(range: range, now: now)
            return Reading(summary: sample, fetchedAt: now, error: nil, server: SharedStore.demoURL)
        case .dashboard: break
        }
        guard let server = config.server else {
            return Reading(summary: nil, fetchedAt: nil, error: "Enter a dashboard address in AI Usage.", server: UsageClient.defaultServer)
        }
        let kept = SharedStore.cached(range: range)
        let since = { (date: Date?) -> Bool in
            guard let date else { return false }
            return kept.map { date > $0.fetchedAt } ?? true
        }
        let appFailed = since(SharedStore.failure(range: range)?.at)
        if reuse > 0, let kept, !appFailed, !since(SharedStore.refreshRequested),
           kept.fetchedAt <= now, now.timeIntervalSince(kept.fetchedAt) < reuse {
            return Reading(summary: kept.summary, fetchedAt: kept.fetchedAt, error: nil, server: server)
        }
        do {
            let summary = try await UsageClient.fetch(server: server, range: range, timeout: timeout)
            guard SharedStore.loadConfig() == config else { return await load(range: range, now: now) }
            SharedStore.cache(summary, range: range, at: now)
            if record { SharedStore.clearFailure(range: range) }
            return Reading(summary: summary, fetchedAt: now, error: nil, server: server)
        } catch {
            guard SharedStore.loadConfig() == config else { return await load(range: range, now: now) }
            let message = error.localizedDescription
            if record { SharedStore.recordFailure(message, range: range, at: now) }
            let fallback = SharedStore.cached(range: range)
            let recent = !appFailed && (fallback.map { now.timeIntervalSince($0.fetchedAt) < tolerate } ?? false)
            return Reading(summary: fallback?.summary, fetchedAt: fallback?.fetchedAt,
                           error: recent ? nil : message, server: server)
        }
    }
}
