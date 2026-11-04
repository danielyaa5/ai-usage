import Foundation
import Security
import os

/// What the app and its widget share. The app writes `config.json` (its test listener's port and
/// token, and the network address to try) to the App Group container, and the widget writes
/// `widget-report.json` there after each check, besides sending it to the app.
enum StoreTestShared {
    /// Unified log subsystem for everything the test records; the runner script collects it with
    /// `log show --predicate 'subsystem == "AIUsageStoreTest"'`.
    static let subsystem = "AIUsageStoreTest"

    /// The App Group in this process's own signature. scripts/sign.sh writes it into the
    /// entitlements (team ID plus the app's bundle ID), so no team ID appears in the code or the
    /// Info.plist. Checking the signature first also keeps an unsigned build from asking for access
    /// to another app's data.
    static let appGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first
    }()

    /// True when this process runs in the App Sandbox (it has the entitlement in its signature).
    static let sandboxed: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? Bool) ?? false
    }()

    static var folder: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    struct Config: Codable {
        var port: Int
        var token: String
        var lanURL: String?
        var writtenAt: Date
    }

    /// One run of the widget's checks.
    struct WidgetReport: Codable {
        var id = UUID()
        var at: Date
        /// "timeline" or "snapshot": which WidgetKit call ran the checks.
        var source: String
        var family: String
        var outcomes: [URLCheckOutcome]
        var configFound: Bool
    }

    static func write<T: Encodable>(_ value: T, _ name: String) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        guard let url = folder?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = folder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
