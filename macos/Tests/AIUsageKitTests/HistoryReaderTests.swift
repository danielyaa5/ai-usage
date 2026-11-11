import XCTest
@testable import AIUsageKit

final class HistoryReaderTests: XCTestCase {
    private var root: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheURL = root.appendingPathComponent("history-cache.json")
    }

    override func tearDownWithError() throws {
        SharedStore.folderOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeClaudeLine(id: String, model: String = "fixture", date: Date = Date(), input: Int = 100, cached: Int = 20, output: Int = 10) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cached),"output_tokens":\#(output)}}}"#
    }

    func testCachePersistenceAcrossColdReinstantiation() async throws {
        let project = root.appendingPathComponent("projects/project1")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        let line1 = makeClaudeLine(id: "event_1") + "\n"
        try Data(line1.utf8).write(to: log)

        let reader1 = HistoryReader(cacheURL: cacheURL)
        let result1 = try await reader1.scan(.claude, at: root)
        await reader1.flushCache()
        XCTAssertEqual(result1.events.count, 1)
        XCTAssertEqual(result1.events["event_1"]?.input, 100)

        // Cache file must be persisted to disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // Create a completely new reader instance pointing to the same cache
        let reader2 = HistoryReader(cacheURL: cacheURL)
        let cached = await reader2.cachedHistories()
        XCTAssertEqual(cached[.claude]?.events.count, 1)
        XCTAssertEqual(cached[.claude]?.events["event_1"]?.input, 100)

        // Scanning with unchanged file reuses cached state without re-reading
        let result2 = try await reader2.scan(.claude, at: root)
        XCTAssertEqual(result2.events.count, 1)
        XCTAssertEqual(result2.events["event_1"]?.input, 100)
    }

    func testIncrementalAppend() async throws {
        let project = root.appendingPathComponent("projects/project2")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        let line1 = makeClaudeLine(id: "first_event") + "\n"
        try Data(line1.utf8).write(to: log)

        let reader = HistoryReader(cacheURL: cacheURL)
        let r1 = try await reader.scan(.claude, at: root)
        XCTAssertEqual(r1.events.count, 1)

        // Append line 2 to the log
        let line2 = makeClaudeLine(id: "second_event", input: 250) + "\n"
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line2.utf8))
        try handle.close()

        let r2 = try await reader.scan(.claude, at: root)
        XCTAssertEqual(r2.events.count, 2)
        XCTAssertEqual(r2.events["first_event"]?.input, 100)
        XCTAssertEqual(r2.events["second_event"]?.input, 250)
    }

    func testFileTruncationAndRewriteReset() async throws {
        let project = root.appendingPathComponent("projects/project3")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        let line1 = makeClaudeLine(id: "large_event_1", input: 500) + "\n"
        let line2 = makeClaudeLine(id: "large_event_2", input: 600) + "\n"
        try Data((line1 + line2).utf8).write(to: log)

        let reader = HistoryReader(cacheURL: cacheURL)
        let r1 = try await reader.scan(.claude, at: root)
        XCTAssertEqual(r1.events.count, 2)

        // Overwrite the file with a much smaller single line (file shrunk)
        let shorter = makeClaudeLine(id: "replacement", input: 42) + "\n"
        try Data(shorter.utf8).write(to: log)

        let r2 = try await reader.scan(.claude, at: root)
        XCTAssertEqual(r2.events.count, 1)
        XCTAssertEqual(r2.events["replacement"]?.input, 42)
    }

    func testOldFileMTimeSkipping() async throws {
        let project = root.appendingPathComponent("projects/old_project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        let oldDate = Date().addingTimeInterval(-40 * 86400) // 40 days ago
        let line = makeClaudeLine(id: "ancient", date: oldDate) + "\n"
        try Data(line.utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: log.path)

        let reader = HistoryReader(cacheURL: cacheURL)
        let result = try await reader.scan(.claude, at: root)
        XCTAssertEqual(result.events.count, 0)
    }

    func testStreamingChunkedLineParsingSpanningChunks() async throws {
        let project = root.appendingPathComponent("projects/streaming")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        // Create a line where the JSON string has enough padding to be ~280 KB (larger than 262144 chunk size)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let padding = String(repeating: "a", count: 280_000)
        let longLine = #"{"type":"assistant","timestamp":"\#(stamp)","extra":"\#(padding)","message":{"id":"big_msg","model":"fixture","usage":{"input_tokens":123,"cache_read_input_tokens":10,"output_tokens":20}}}"# + "\n"
        try Data(longLine.utf8).write(to: log)

        let reader = HistoryReader(cacheURL: cacheURL)
        let result = try await reader.scan(.claude, at: root)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events["big_msg"]?.input, 123)
    }

    func testForgetRemovesDiskCache() async throws {
        let project = root.appendingPathComponent("projects/forget_test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")
        try Data((makeClaudeLine(id: "foo") + "\n").utf8).write(to: log)

        let reader = HistoryReader(cacheURL: cacheURL)
        _ = try await reader.scan(.claude, at: root)
        await reader.flushCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        await reader.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testSharedStoreRefreshingStateAndAutoExpiry() {
        SharedStore.folderOverride = root
        let now = Date()

        XCTAssertFalse(SharedStore.isRefreshing(now: now))

        SharedStore.markRefreshing(at: now)
        XCTAssertTrue(SharedStore.isRefreshing(now: now))
        XCTAssertTrue(SharedStore.isRefreshing(now: now.addingTimeInterval(45)))

        // Auto-expires after 90 seconds
        XCTAssertFalse(SharedStore.isRefreshing(now: now.addingTimeInterval(91)))

        // Explicit clear
        SharedStore.clearRefreshing()
        XCTAssertFalse(SharedStore.isRefreshing(now: now))
    }

    func testReadingFreshnessNoteShowsRefreshing() {
        SharedStore.folderOverride = root
        let now = Date()
        SharedStore.markRefreshing(at: now)

        let summary = UsageSummary.localSample(range: "7d", now: now)
        let reading = Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        XCTAssertEqual(reading.freshnessNote(now: now), "Refreshing…")

        SharedStore.clearRefreshing()
        let freshReading = Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        XCTAssertNil(freshReading.freshnessNote(now: now))
    }

    func testReadingFreshnessNoteStaleCrossDay() {
        SharedStore.folderOverride = root
        SharedStore.clearRefreshing()
        let now = Date()
        // Yesterday reading past stale threshold
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let summary = UsageSummary.localSample(range: "7d", now: yesterday)
        let reading = Reading(summary: summary, fetchedAt: yesterday, error: nil, server: SharedStore.localURL)
        guard let note = reading.freshnessNote(now: now) else {
            XCTFail("Expected freshnessNote for stale reading")
            return
        }
        XCTAssertTrue(note.hasPrefix("Refresh needed · from "))
    }

    func testMultiProviderCacheSurvivalWhenOtherDirectoryUnmounted() async throws {
        let claudeRoot = root.appendingPathComponent("claude")
        let claudeProject = claudeRoot.appendingPathComponent("projects/p1")
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        let claudeLog = claudeProject.appendingPathComponent("session.jsonl")
        try Data((makeClaudeLine(id: "c1", input: 111) + "\n").utf8).write(to: claudeLog)

        let codexRoot = root.appendingPathComponent("codex")
        let codexSessions = codexRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        let codexLog = codexSessions.appendingPathComponent("rollout-1.jsonl")
        let codexLine = #"{"type":"token_usage_record","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","payload":{"usage":{"input_tokens":300,"cached_input_tokens":50,"output_tokens":40},"response_id":"codex_1"}}"# + "\n"
        try Data(codexLine.utf8).write(to: codexLog)

        let reader = HistoryReader(cacheURL: cacheURL)
        _ = try await reader.scan(.claude, at: claudeRoot)
        _ = try await reader.scan(.codex, at: codexRoot)
        await reader.flushCache()

        var cached = await reader.cachedHistories()
        XCTAssertEqual(cached[.claude]?.events["c1"]?.input, 111)
        XCTAssertEqual(cached[.codex]?.events["codex_1"]?.input, 250) // 300 - 50 = 250

        // Simulate codex directory being unmounted or inaccessible in sandbox:
        // We delete codexRoot to prove that scanning claudeRoot does NOT prune codex from cache.
        try FileManager.default.removeItem(at: codexRoot)

        _ = try await reader.scan(.claude, at: claudeRoot)
        await reader.flushCache()

        cached = await reader.cachedHistories()
        XCTAssertEqual(cached[.claude]?.events["c1"]?.input, 111)
        XCTAssertEqual(cached[.codex]?.events["codex_1"]?.input, 250, "Codex cache must survive unmounted/inaccessible directory during Claude scan")
    }

    func testHourlyBucketCompaction() async throws {
        let project = root.appendingPathComponent("projects/compact_test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("session.jsonl")

        // 25 lines within the same hour
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_100) // specific fixed second
        var content = ""
        for i in 1...25 {
            content += makeClaudeLine(id: "event_\(i)", model: "claude-3-5-sonnet", date: fixedDate.addingTimeInterval(Double(i * 10)), input: 10, cached: 5, output: 2) + "\n"
        }
        try Data(content.utf8).write(to: log)

        let reader = HistoryReader(cacheURL: cacheURL)
        let scanDate = fixedDate.addingTimeInterval(3 * 3600) // 3 hours later (> 7200s cutoff)
        let result = try await reader.scan(.claude, at: root, now: scanDate)

        // Compaction should reduce 25 events into 1 hourly bucket
        XCTAssertEqual(result.events.count, 1)
        guard let bucket = result.events.values.first else {
            XCTFail("Expected 1 compacted bucket")
            return
        }
        XCTAssertEqual(bucket.input, 25 * 10)
        XCTAssertEqual(bucket.cached, 25 * 5)
        XCTAssertEqual(bucket.output, 25 * 2)
        XCTAssertEqual(bucket.requests, 25)
    }

    func testCrossFileHourlyBucketNoCollisionAcrossParallelSessions() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_100)
        let subagentA = root.appendingPathComponent("projects/subagent-a")
        let subagentB = root.appendingPathComponent("projects/subagent-b")
        try FileManager.default.createDirectory(at: subagentA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subagentB, withIntermediateDirectories: true)

        let logA = subagentA.appendingPathComponent("session.jsonl")
        let logB = subagentB.appendingPathComponent("session.jsonl")

        // 30 turns in file A, 30 turns in file B, all in the exact same hour for the same model
        var contentA = ""
        var contentB = ""
        for i in 1...30 {
            contentA += makeClaudeLine(id: "msg_a_\(i)", model: "claude-3-5-sonnet", date: fixedDate.addingTimeInterval(Double(i * 10)), input: 10, cached: 5, output: 2) + "\n"
            contentB += makeClaudeLine(id: "msg_b_\(i)", model: "claude-3-5-sonnet", date: fixedDate.addingTimeInterval(Double(i * 10)), input: 20, cached: 10, output: 4) + "\n"
        }
        try Data(contentA.utf8).write(to: logA)
        try Data(contentB.utf8).write(to: logB)

        let scanDate = fixedDate.addingTimeInterval(3 * 3600) // 3 hours later (> 7200s compaction cutoff)
        let reader1 = HistoryReader(cacheURL: cacheURL)
        let merged1 = try await reader1.scan(.claude, at: root, now: scanDate)
        await reader1.flushCache()

        // Both files have >20 events, so each file compacts to its own hourly bucket with a distinct file hash in the key
        XCTAssertEqual(merged1.events.count, 2, "Merged events must contain both files' compacted hourly buckets without collision")
        let totalRequests1 = merged1.events.values.reduce(0) { $0 + $1.requests }
        let totalInput1 = merged1.events.values.reduce(0) { $0 + $1.input }
        let totalCached1 = merged1.events.values.reduce(0) { $0 + $1.cached }
        let totalOutput1 = merged1.events.values.reduce(0) { $0 + $1.output }

        XCTAssertEqual(totalRequests1, 60, "Combined requests must equal 30 + 30 = 60")
        XCTAssertEqual(totalInput1, 30 * 10 + 30 * 20, "Combined input tokens must be fully preserved")
        XCTAssertEqual(totalCached1, 30 * 5 + 30 * 10, "Combined cached tokens must be fully preserved")
        XCTAssertEqual(totalOutput1, 30 * 2 + 30 * 4, "Combined output tokens must be fully preserved")

        // Verify that cold cache reload from disk also preserves both buckets and exact counts
        let reader2 = HistoryReader(cacheURL: cacheURL)
        let cached = await reader2.cachedHistories(now: scanDate)
        guard let claudeHistory = cached[.claude] else {
            XCTFail("Expected cached Claude history")
            return
        }
        XCTAssertEqual(claudeHistory.events.count, 2)
        let totalRequests2 = claudeHistory.events.values.reduce(0) { $0 + $1.requests }
        let totalInput2 = claudeHistory.events.values.reduce(0) { $0 + $1.input }
        XCTAssertEqual(totalRequests2, 60, "Cold cache reload must preserve requests count == 60")
        XCTAssertEqual(totalInput2, totalInput1, "Cold cache reload must preserve all tokens")
    }

    func testForgetProvider() async throws {
        let claudeRoot = root.appendingPathComponent("claude")
        let claudeProject = claudeRoot.appendingPathComponent("projects/p1")
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        let claudeLog = claudeProject.appendingPathComponent("session.jsonl")
        try Data((makeClaudeLine(id: "c_keep", input: 100) + "\n").utf8).write(to: claudeLog)

        let codexRoot = root.appendingPathComponent("codex")
        let codexSessions = codexRoot.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        let codexLog = codexSessions.appendingPathComponent("rollout-1.jsonl")
        let codexLine = #"{"type":"token_usage_record","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","payload":{"usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":30},"response_id":"cdx_keep"}}"# + "\n"
        try Data(codexLine.utf8).write(to: codexLog)

        let reader = HistoryReader(cacheURL: cacheURL)
        _ = try await reader.scan(.claude, at: claudeRoot)
        _ = try await reader.scan(.codex, at: codexRoot)
        await reader.flushCache()

        var cached = await reader.cachedHistories()
        XCTAssertNotNil(cached[.claude])
        XCTAssertNotNil(cached[.codex])

        // Forget only Claude
        await reader.forget(provider: .claude)
        cached = await reader.cachedHistories()
        XCTAssertNil(cached[.claude])
        XCTAssertNotNil(cached[.codex])

        // Retain only Antigravity
        await reader.retainOnly(providers: [.antigravity])
        cached = await reader.cachedHistories()
        XCTAssertNil(cached[.codex])
    }
}
