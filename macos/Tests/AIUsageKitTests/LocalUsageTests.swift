import XCTest
import SQLite3
@testable import AIUsageKit

final class LocalUsageTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { SharedStore.folderOverride = nil; try FileManager.default.removeItem(at: root) }

    func testFreshInstallDemoAndOldDashboard() async throws {
        SharedStore.folderOverride = root
        XCTAssertEqual(SharedStore.loadConfig().source,.local)
        let fresh = await Reading.load(range:"today")
        XCTAssertNil(fresh.summary)
        XCTAssertNil(fresh.error)
        XCTAssertEqual(fresh.server,SharedStore.localURL)
        try SharedStore.save(.init(source:.demo))
        let demo = await Reading.load(range:"30d")
        XCTAssertEqual(demo.summary?.host,"Demo")
        XCTAssertEqual(demo.summary?.range,"30d")
        try SharedStore.save(.init(source:.local))
        let empty = await Reading.load(range:"today")
        XCTAssertNil(empty.summary, "Fictional readings must never become a user's history")
        try Data(#"{"server":"https://example.org/usage/"}"#.utf8).write(to:root.appendingPathComponent("config.json"))
        XCTAssertEqual(SharedStore.loadConfig().source,.dashboard)
    }

    func testReadOnlyHistoryAndWidgetSnapshot() async throws {
        let project = root.appendingPathComponent("projects/project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let log = project.appendingPathComponent("session.jsonl")
        let now = Date(), stamp = ISO8601DateFormatter().string(from:now)
        func line(_ id: String) -> String {
            #"{"type":"assistant","timestamp":"STAMP","message":{"id":"ID","model":"fixture","content":[{"text":"PRIVATE_FIXTURE_TEXT"}],"usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":10}}}"#.replacingOccurrences(of:"STAMP",with:stamp).replacingOccurrences(of:"ID",with:id)
        }
        let first = Data((line("one") + "\n" + line("one") + "\n" + line("two")).utf8)
        try first.write(to:log)
        let reader = HistoryReader()
        let partial = try await reader.scan(.claude,at:root)
        XCTAssertEqual(partial.events.count,1)
        let handle = try FileHandle(forWritingTo:log)
        try handle.seekToEnd(); try handle.write(contentsOf:Data("\n".utf8)); try handle.close()
        let result = try await reader.scan(.claude,at:root)
        XCTAssertEqual(result.events.count,2)
        let prices = try JSONDecoder().decode(LocalPrices.self,from:Data(#"{"aliases":{},"models":{"fixture":{"input":2,"output":8}}}"#.utf8))
        let snapshot = SharedStore.LocalSnapshot(summaries:LocalSummary.build(histories:[.claude:result],limits:[:],issues:[:],prices:prices,now:now))
        SharedStore.folderOverride = root.appendingPathComponent("widget")
        try SharedStore.publishLocal(snapshot)
        let widget = await Reading.load(range:"7d")
        XCTAssertEqual(widget.summary?.totals.requests,2)
        XCTAssertEqual(widget.summary?.totals.tokens,260)
        XCTAssertEqual(widget.summary?.totals.unpriced,0)
        XCTAssertEqual(widget.summary?.totals.cost ?? 0,0.000568,accuracy:0.0000001)
        XCTAssertEqual(try Data(contentsOf:log), first + Data("\n".utf8))
        let exported = try String(contentsOf: SharedStore.folder!.appendingPathComponent("this-mac.json"),encoding:.utf8)
        XCTAssertFalse(exported.contains("PRIVATE_FIXTURE_TEXT"))
        XCTAssertFalse(exported.contains("session.jsonl"))
        try FileManager.default.removeItem(at:log)
        let removed = try await reader.scan(.claude,at:root)
        XCTAssertEqual(removed.events.count,0)
    }

    func testCodexLimitsAndAccounting() async throws {
        let logs = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
        let date = Date(), stamp = ISO8601DateFormatter().string(from:date)
        let content = """
        {"type":"session_meta","payload":{"id":"session"}}
        {"type":"turn_context","payload":{"model":"example","turn_id":"turn"}}
        {"type":"token_usage_record","timestamp":"STAMP","payload":{"response_id":"one","turn_id":"turn","usage":{"input_tokens":200,"cached_input_tokens":120,"output_tokens":50}}}
        {"type":"event_msg","timestamp":"STAMP","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200}},"rate_limits":{"primary":{"used_percent":23,"window_minutes":300}}}}
        """.replacingOccurrences(of:"STAMP",with:stamp) + "\n"
        try Data(content.utf8).write(to:logs.appendingPathComponent("rollout-test.jsonl"))
        let history = try await HistoryReader().scan(.codex,at:root)
        XCTAssertEqual(history.events.count,1)
        XCTAssertEqual(history.events["one"]?.input,80)
        XCTAssertEqual(history.windows.first?.leftPct,77)
        let summaries = LocalSummary.build(histories:[:],limits:[.codex:history.windows],issues:[:],prices:nil,now:date)
        XCTAssertEqual(summaries["today"]?.hasHistory,false)
        XCTAssertEqual(summaries["today"]?.plans.first?.windows.first?.label,"5-hour")
    }

    func testAntigravityMetadataOnly() async throws {
        let folder = root.appendingPathComponent("antigravity/conversations")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("session.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        let now = UInt64(Date().timeIntervalSince1970)
        func varint(_ value: UInt64) -> [UInt8] {
            var v = value, bytes: [UInt8] = []
            while v >= 128 { bytes.append(UInt8(v & 127) | 128); v >>= 7 }
            return bytes + [UInt8(v)]
        }
        let time = [UInt8(8)] + varint(now)
        let stats: [UInt8] = [16,20,24,5,40,3]
        let meta: [UInt8] = [10,UInt8(time.count)] + time + [74,UInt8(stats.count)] + stats
        let hex = meta.map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE steps(idx INTEGER, metadata BLOB); INSERT INTO steps VALUES(1,X'\(hex)')",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf:url)
        let history = try await HistoryReader().scan(.antigravity,at:root)
        XCTAssertEqual(history.events.count,1)
        XCTAssertEqual(history.events.values.first?.cached,3)
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["session.db"])
    }
}
