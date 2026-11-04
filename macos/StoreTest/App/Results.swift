import Combine
import Foundation
import os

enum CheckStatus: String, Codable {
    case pending, running, passed, failed, info, skipped

    var symbol: String {
        switch self {
        case .pending: return "·"
        case .running: return "…"
        case .passed: return "✓"
        case .failed: return "✗"
        case .info: return "i"
        case .skipped: return "-"
        }
    }
}

/// One result the test reports. `id` is stable (such as "net.loopback-ip") so a check that runs again
/// replaces its earlier result.
struct CheckRecord: Codable, Identifiable {
    var id: String
    var test: Int
    var title: String
    var status: CheckStatus
    var detail: String
    var facts: [String: String]
    var at: Date
}

/// Everything recorded so far: the checks, a running log of events, and the raw observations the
/// checks are drawn from. The runner script reads it as JSON from the test listener, and every entry
/// also goes to the unified log (subsystem AIUsageStoreTest) and to stdout.
@MainActor
final class Results: ObservableObject {
    @Published private(set) var checks: [CheckRecord] = []
    @Published private(set) var events: [String] = []

    private let resultLog = StoreTestShared.logger("result")
    private let eventLog = StoreTestShared.logger("event")
    private let started = Date()

    func set(_ id: String, test: Int, _ title: String, _ status: CheckStatus, _ detail: String,
             facts: [String: String] = [:]) {
        let record = CheckRecord(id: id, test: test, title: title, status: status, detail: detail, facts: facts, at: Date())
        if let index = checks.firstIndex(where: { $0.id == id }) {
            checks[index] = record
        } else {
            checks.append(record)
        }
        guard status != .running, status != .pending else { return }
        let line = (try? StoreTestShared.encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? id
        Self.emit(line, prefix: "RESULT", to: resultLog)
    }

    func check(_ id: String) -> CheckRecord? {
        checks.first { $0.id == id }
    }

    /// A line for the activity log. Callers redact anything that came from outside the app.
    func event(_ text: String) {
        let seconds = String(format: "%7.1f", Date().timeIntervalSince(started))
        let line = "[\(seconds) s] \(text)"
        events.append(line)
        if events.count > 800 { events.removeFirst(events.count - 800) }
        Self.emit(line, prefix: "EVENT", to: eventLog)
    }

    /// Unified log messages are cut at about 1 KB, so long lines go out in numbered parts.
    private static func emit(_ line: String, prefix: String, to logger: Logger) {
        print("\(prefix) \(line)")
        fflush(stdout)
        let characters = Array(line)
        let size = 700
        if characters.count <= size {
            logger.notice("\(prefix, privacy: .public) \(line, privacy: .public)")
            return
        }
        let parts = (characters.count + size - 1) / size
        for part in 0..<parts {
            let piece = String(characters[(part * size)..<min(characters.count, (part + 1) * size)])
            logger.notice("\(prefix, privacy: .public) [\(part + 1)/\(parts)] \(piece, privacy: .public)")
        }
    }

    /// The checks as text, for the runner's summary and the Copy button.
    func summary(header: String) -> String {
        var lines = [header]
        for test in 0...4 {
            let rows = checks.filter { $0.test == test }
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append(test == 0 ? "Setup" : "Test \(test): \(Self.testTitles[test] ?? "")")
            for row in rows {
                lines.append("  \(row.status.symbol) \(row.title): \(row.detail)")
                for key in row.facts.keys.sorted() {
                    lines.append("      \(key): \(row.facts[key] ?? "")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static let testTitles = [
        1: "ChatGPT limits through the bundled Codex",
        2: "Plain HTTP to this Mac and your network, with only NSAllowsLocalNetworking",
        3: "Reading ~/.claude and ~/.codex through Open panel bookmarks",
        4: "Claude limits from the status line snippet",
    ]
}
