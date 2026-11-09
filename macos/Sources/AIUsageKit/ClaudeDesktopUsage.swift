import Foundation
import Darwin

/// Claude Desktop periodically saves complete samples of the plan's utilization. Only the two
/// plan-wide percentages and their original timestamp leave this decoder.
public enum ClaudeDesktopUsage {
    public static let filename = "plan-usage-history.json"
    public static let maxBytes = 8 * 1024 * 1024

    public enum Problem: String, Error, Sendable {
        case noSample = "Claude Desktop hasn’t saved a plan reading yet."
        case noWindows = "The latest Claude Desktop reading has no five-hour or weekly percentage."
        case unsupported = "AI Usage couldn’t read this version of Claude Desktop’s usage history."
        case access = "The Claude folder is unavailable. Choose it again to restore access."
    }

    /// An optional snapshot for a Mac where Claude Desktop has not written a recent reading.
    public struct Entry: Codable, Equatable, Sendable {
        public let fiveHour: Int?
        public let weekly: Int?
        public let recordedAt: Date

        public init?(fiveHourText: String, weeklyText: String, at date: Date) {
            let sessionText = fiveHourText.trimmingCharacters(in: .whitespacesAndNewlines)
            let weekText = weeklyText.trimmingCharacters(in: .whitespacesAndNewlines)
            fiveHour = Int(sessionText)
            weekly = Int(weekText)
            guard fiveHour != nil || weekly != nil,
                  sessionText.isEmpty || fiveHour.map((0...100).contains) == true,
                  weekText.isEmpty || weekly.map((0...100).contains) == true else { return nil }
            recordedAt = date
        }

        public var windows: [LimitWindow] {
            [(fiveHour, 300), (weekly, 10080)].compactMap { value, minutes in
                guard let value, var window = LocalLimits.window(Double(value), minutes: minutes, reset: nil, at: recordedAt) else { return nil }
                window.manuallyEntered = true
                return window
            }
        }
    }

    /// Reopen the fixed filename on each check because Claude replaces it atomically.
    public static func windows(in folder: URL, now: Date) throws -> [LimitWindow] {
        let path = folder.appendingPathComponent(filename).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? Problem.noSample : .access }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Problem.access }
        guard info.st_size <= maxBytes else { throw Problem.unsupported }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        return try windows(from: data, now: now)
    }

    private struct History: Decodable {
        let version: Int
        let samples: [Sample]
    }
    private struct Percentages: Decodable {
        let fiveHour: Double?
        let weekly: Double?
        enum CodingKeys: String, CodingKey { case fiveHour = "fh", weekly = "sd" }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? fields.decode(Double.self, forKey: .fiveHour)
            weekly = try? fields.decode(Double.self, forKey: .weekly)
        }
    }
    private struct Sample: Decodable {
        let time: Double?
        let nested: Percentages?
        let legacy: Percentages?
        enum CodingKeys: String, CodingKey { case time = "t", nested = "u" }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            time = try? fields.decode(Double.self, forKey: .time)
            nested = try? fields.decode(Percentages.self, forKey: .nested)
            legacy = try? Percentages(from: decoder)
        }
    }

    public static func windows(from data: Data, now: Date) throws -> [LimitWindow] {
        guard data.count <= maxBytes, let history = try? JSONDecoder().decode(History.self, from: data),
              history.version == 1 || history.version == 2 else { throw Problem.unsupported }
        let nowMillis = now.timeIntervalSince1970 * 1000
        var newest: Sample?
        for sample in history.samples {
            guard let time = sample.time, time.isFinite, time > 0, time <= nowMillis else { continue }
            if time >= (newest?.time ?? 0) { newest = sample }
        }
        guard let sample = newest, let milliseconds = sample.time else { throw Problem.noSample }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let usage = history.version == 1 ? sample.legacy : sample.nested
        // Missing windows in the latest sample can belong to a different plan or account.
        // Never fill them from an older observation. The file does not contain reset times.
        let windows = [
            LocalLimits.window(usage?.fiveHour, minutes: 300, reset: nil, at: date),
            LocalLimits.window(usage?.weekly, minutes: 10080, reset: nil, at: date)
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw Problem.noWindows }
        return windows
    }
}
