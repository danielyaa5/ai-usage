import Foundation

/// Each file keeps only accounting records and the offset of its last complete line.
public actor HistoryReader {
    private struct Timeline {
        var model = "unknown", session = ""
        var turns: [String: String] = [:]
        var explicitRecords = false
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var size: UInt64 = 0
        var inode: UInt64 = 0
        var history = LocalHistory()
    }
    private var files: [URL: Timeline] = [:]
    private let iso = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private let manager = FileManager.default
    private let maxLine = 4_000_000

    public init() {}

    public func scan(_ provider: HistoryProvider, at root: URL, now: Date = Date()) throws -> LocalHistory {
        var merged = LocalHistory()
        let cutoff = now.addingTimeInterval(-30 * 86400)
        for name in provider.logDirectories {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            // The selected directory grants no implied permission to follow a link outside it.
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { continue }
            guard manager.fileExists(atPath: directory.path) else { continue }
            var enumerationError: Error?
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
            guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                        enumerationError = error
                        return true
                    }) else { throw CocoaError(.fileReadNoPermission) }
            for case let url as URL in walker {
                if Task.isCancelled { throw CancellationError() }
                let ext = provider == .antigravity ? "db" : "jsonl"
                guard url.pathExtension == ext else { continue }
                if provider == .codex && !url.lastPathComponent.hasPrefix("rollout-") { continue }
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                var state = files[url] ?? Timeline()
                let attr = try manager.attributesOfItem(atPath: url.path)
                let size = (attr[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attr[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                if state.modified != modified || state.size != size || state.inode != inode || provider == .antigravity {
                    if provider == .antigravity {
                        // SQLite may have new rows in a WAL before the main file changes.
                        state.history = try AntigravityHistory.read(url, since: cutoff)
                    } else {
                        if inode != state.inode || size <= state.size { state = Timeline() }
                        try read(url, provider: provider, state: &state, cutoff: cutoff)
                    }
                    state.modified = modified
                    state.size = size
                    state.inode = inode
                }
                state.history.events = state.history.events.filter { $0.value.date >= cutoff }
                files[url] = state
                merged.merge(state.history)
            }
            if let enumerationError { throw enumerationError }
        }
        // A disconnected or deleted log never contributes to this scan.
        files = files.filter { $0.value.modified >= cutoff }
        return merged
    }

    public func forget() { files.removeAll() }

    private func read(_ url: URL, provider: HistoryProvider, state: inout Timeline, cutoff: Date) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: state.offset)
        var pending = Data(), skip = false, position = state.offset
        while let chunk = try file.read(upToCount: 262144), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            var begin = chunk.startIndex
            while begin < chunk.endIndex {
                let end = chunk[begin...].firstIndex(of: 10) ?? chunk.endIndex
                let count = end - begin
                if !skip && pending.count + count <= maxLine { pending.append(chunk[begin..<end]) }
                else { skip = true; pending.removeAll(keepingCapacity: false) }
                position += UInt64(count)
                if end == chunk.endIndex { break }
                if !skip { parse(pending, provider: provider, state: &state, cutoff: cutoff) }
                position += 1
                state.offset = position
                pending.removeAll(keepingCapacity: true)
                skip = false
                begin = end + 1
            }
        }
        // A partial line is retried when the tool appends the rest.
    }

    private func parse(_ line: Data, provider: HistoryProvider, state: inout Timeline, cutoff: Date) {
        // Most records carry no usage. Avoid decoding lengthy tool output and conversations.
        let markers = provider == .claude ? Self.claudeMarkers : Self.codexMarkers
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = row["type"] as? String else { return }
        let payload = row["payload"] as? [String: Any] ?? [:]
        if kind == "session_meta" {
            state.session = payload["id"] as? String ?? payload["session_id"] as? String ?? ""
            return
        }
        if kind == "turn_context", let model = payload["model"] as? String {
            state.model = model
            if let turn = payload["turn_id"] as? String { state.turns[turn] = model }
            return
        }
        guard let timestamp = row["timestamp"] as? String,
              let date = fractional.date(from: timestamp) ?? iso.date(from: timestamp), date >= cutoff else { return }
        if provider == .claude, kind == "assistant", let message = row["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any], let model = message["model"] as? String,
           !model.hasPrefix("<"), let id = message["id"] as? String ?? row["uuid"] as? String {
            add(UsageEvent(id: id, date: date, model: model, input: Self.count(usage,"input_tokens"),
                    cached: Self.count(usage,"cache_read_input_tokens"), writes: Self.count(usage,"cache_creation_input_tokens"),
                    hourWrites: Self.count(usage["cache_creation"] as? [String: Any] ?? [:],"ephemeral_1h_input_tokens"),
                    output: Self.count(usage,"output_tokens"), fast: usage["speed"] as? String == "fast"), to: &state)
        } else if provider == .codex {
            var usage: [String: Any]?, id: String?, model = state.model
            if kind == "token_usage_record" {
                state.explicitRecords = true
                usage = payload["usage"] as? [String: Any]
                id = payload["response_id"] as? String ?? "\(state.session):\(timestamp)"
                if let turn = payload["turn_id"] as? String { model = state.turns[turn] ?? model }
            } else if kind == "event_msg", payload["type"] as? String == "token_count" {
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let windows = ["primary","secondary"].compactMap { slot -> LimitWindow? in
                        guard let v = limits[slot] as? [String: Any] else { return nil }
                        return LocalLimits.window((v["used_percent"] as? NSNumber)?.doubleValue,
                            minutes: v["window_minutes"] as? Int, reset: (v["resets_at"] as? NSNumber)?.doubleValue,
                            at: date, fallback: slot.capitalized)
                    }
                    if !windows.isEmpty { state.history.windows = windows }
                }
                if !state.explicitRecords, let info = payload["info"] as? [String: Any] {
                    usage = info["last_token_usage"] as? [String: Any]
                    let total = info["total_token_usage"] as? [String: Any]
                    id = "\(state.session):\(total?["total_tokens"].map(String.init(describing:)) ?? timestamp)"
                }
            }
            if let usage, let id {
                let input = Self.count(usage,"input_tokens")
                let cached = min(input, Self.count(usage,"cached_input_tokens"))
                add(UsageEvent(id: id, date: date, model: model, input: input - cached, cached: cached,
                               writes: Self.count(usage,"cache_write_input_tokens"), output: Self.count(usage,"output_tokens")), to: &state)
            }
        }
    }
    private static let claudeMarkers = [Data("\"usage\"".utf8)]
    private static let codexMarkers = ["\"token_usage_record\"","\"token_count\"","\"session_meta\"","\"turn_context\""].map { Data($0.utf8) }
    private static func count(_ dict: [String: Any], _ key: String) -> Int {
        max(0, min((dict[key] as? NSNumber)?.intValue ?? 0, 1_000_000_000))
    }
    private func add(_ event: UsageEvent, to state: inout Timeline) {
        guard event.input + event.cached + event.writes + event.output > 0 else { return }
        state.history.events[event.id] = event
    }
}
