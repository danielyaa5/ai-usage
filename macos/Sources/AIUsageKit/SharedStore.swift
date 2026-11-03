import Foundation
#if os(macOS)
import Security
#endif

/// Settings and the last good reading, shared by the app and the widget extension through the App
/// Group container: `config.json` (the dashboard address) and `summary-<range>.json` (cached replies,
/// shown when the dashboard can't be reached).
///
/// On macOS the group is the team-prefixed kind ("TEAMID.com.example.AIUsage"), which needs no
/// provisioning profile entry; a `group.` container would need one, and since macOS 15 access to it is
/// denied without one. Each target's Info.plist names the group (`AIUsageAppGroup`, filled in from the
/// build settings), so no team ID is written in the code.
public enum SharedStore {
    public static let appGroup: String? = Bundle.main.object(forInfoDictionaryKey: "AIUsageAppGroup") as? String

    public struct Config: Codable, Equatable, Sendable {
        public var server: URL?

        public init(server: URL? = nil) {
            self.server = server
        }
    }

    public struct Cached: Codable, Sendable {
        public var summary: UsageSummary
        public var fetchedAt: Date
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

    public static func clearCache() {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("summary-") && name.hasSuffix(".json") {
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

    private static func safe(_ range: String) -> String {
        String(range.filter { $0.isLetter || $0.isNumber }.prefix(8))
    }

    private static let cacheDecoder = UsageSummary.decoder
    private static let cacheEncoder = UsageSummary.encoder
}

/// One fetch with the cache as fallback: what the widgets and the app show.
public struct Reading: Sendable {
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
    public static func load(range: String, reuse: TimeInterval = 0, tolerate: TimeInterval = 0,
                            timeout: TimeInterval = 15, now: Date = Date()) async -> Reading {
        let server = SharedStore.server
        if reuse > 0, let kept = SharedStore.cached(range: range), now.timeIntervalSince(kept.fetchedAt) < reuse,
           kept.fetchedAt <= now {
            return Reading(summary: kept.summary, fetchedAt: kept.fetchedAt, error: nil, server: server)
        }
        do {
            let summary = try await UsageClient.fetch(server: server, range: range, timeout: timeout)
            SharedStore.cache(summary, range: range, at: now)
            return Reading(summary: summary, fetchedAt: now, error: nil, server: server)
        } catch {
            let cached = SharedStore.cached(range: range)
            let recent = cached.map { now.timeIntervalSince($0.fetchedAt) < tolerate } ?? false
            return Reading(summary: cached?.summary, fetchedAt: cached?.fetchedAt,
                           error: recent ? nil : error.localizedDescription, server: server)
        }
    }
}
