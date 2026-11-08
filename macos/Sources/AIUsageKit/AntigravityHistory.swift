import Foundation
import SQLite3

/// Reads the same metadata fields as the dashboard's protowire reader. The immutable
/// connection never creates journals or shared-memory files in the selected folder.
enum AntigravityHistory {
    private enum Field { case integer(Int), bytes(Data) }
    private static func fields(_ data: Data?) -> [Int: Field] {
        guard let data else { return [:] }
        var i = data.startIndex, result: [Int: Field] = [:]
        func number() -> Int? {
            var value = 0
            for shift in stride(from: 0, through: 56, by: 7) {
                guard i < data.endIndex else { return nil }
                let byte = Int(data[i]); i += 1
                value |= (byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while i < data.endIndex {
            guard let key = number(), key >> 3 > 0 else { return [:] }
            if key & 7 == 0 {
                guard let n = number() else { return [:] }
                result[key >> 3] = .integer(n)
            } else {
                let count: Int
                switch key & 7 {
                case 1: count = 8
                case 5: count = 4
                case 2: guard let value = number() else { return [:] }; count = value
                default: return [:]
                }
                guard count <= data.endIndex - i else { return [:] }
                result[key >> 3] = .bytes(data.subdata(in: i..<i + count)); i += count
            }
        }
        return result
    }
    private static func bytes(_ f: Field?) -> Data? { if case let .bytes(d) = f { return d }; return nil }
    private static func int(_ f: Field?) -> Int { if case let .integer(n) = f { return n }; return 0 }

    static func read(_ url: URL, since cutoff: Date) throws -> LocalHistory {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.absoluteString + "?immutable=1", &db,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK else { throw CocoaError(.fileReadNoPermission) }
        var names: [Int: String] = [:]
        var history = LocalHistory()
        func rows(_ sql: String, optional: Bool = false, _ body: (Int, Data) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                if optional { return }; throw CocoaError(.fileReadCorruptFile)
            }
            defer { sqlite3_finalize(statement) }
            var rc = sqlite3_step(statement)
            while rc == SQLITE_ROW {
                if let ptr = sqlite3_column_blob(statement, 1) {
                    let n = Int(sqlite3_column_bytes(statement, 1))
                    if n < 4_000_000 { body(Int(sqlite3_column_int64(statement, 0)), Data(bytes: ptr, count: n)) }
                }
                rc = sqlite3_step(statement)
            }
            guard rc == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
        }
        try rows("SELECT 0, data FROM gen_metadata WHERE length(data) < 4000000", optional: true) { _, data in
            let outer = fields(bytes(fields(data)[1]))
            if let modelData = bytes(outer[19]), let model = String(data: modelData, encoding: .utf8) {
                let number = int(fields(bytes(outer[4]))[1])
                if number > 0 { names[number] = model }
            }
        }
        try rows("SELECT idx, metadata FROM steps WHERE length(metadata) < 4000000") { index, data in
            let meta = fields(data)
            let time = int(fields(bytes(meta[8] ?? meta[1]))[1])
            let date = Date(timeIntervalSince1970: Double(time))
            guard date >= cutoff else { return }
            let usage = fields(bytes(meta[9]))
            func count(_ field: Int) -> Int { min(int(usage[field]), 1_000_000_000) }
            guard count(2) + count(3) > 0 else { return }
            let id = bytes(usage[11]).flatMap { String(data: $0, encoding: .utf8) }
                ?? "\(url.lastPathComponent):\(index)"
            history.events[id] = UsageEvent(id: id, date: date, model: names[int(usage[1])] ?? "unknown",
                    input: count(2), cached: count(5), writes: count(4), output: count(3))
        }
        return history
    }
}
