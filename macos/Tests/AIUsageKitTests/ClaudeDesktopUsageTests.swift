import XCTest
@testable import AIUsageKit

final class ClaudeDesktopUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func read(_ json: String) throws -> [LimitWindow] {
        try ClaudeDesktopUsage.windows(from: Data(json.utf8), now: now)
    }

    func testLatestCompleteDesktopSamplePreservesItsAgeAndOmitsPersonalFields() throws {
        let input = #"{"version":2,"samples":[{"t":1799998000123,"org":"second-example","u":{"sd":22,"xu":98}},{"t":1799990000000,"org":"first-example","u":{"fh":80,"sd":90}},{"t":1810000000000,"u":{"fh":9}}]}"#
        let windows = try read(input)
        XCTAssertEqual(windows.map(\.label), ["Weekly"])
        XCTAssertEqual(windows.map(\.leftPct), [78])
        XCTAssertEqual(try XCTUnwrap(windows.first?.observedAt).timeIntervalSince1970, 1_799_998_000.123, accuracy: 0.001)
        XCTAssertNil(windows.first?.resetsAt)
        let output = String(decoding: try JSONEncoder().encode(windows), as: UTF8.self)
        XCTAssertFalse(output.contains("example"))
        XCTAssertFalse(output.contains("xu"))
    }

    func testLegacyAndCurrentSamplesAcceptOnlyValidPlanPercentages() throws {
        let legacy = try read(#"{"version":1,"samples":[{"t":1799990000000,"fh":0,"sd":100}]}"#)
        XCTAssertEqual(legacy.map(\.leftPct), [100, 0])
        for bad in ["null", "true", "-1", "101", #""unset""#] {
            let input = "{\"version\":2,\"samples\":[{\"t\":1799990000000,\"u\":{\"fh\":" + bad + ",\"sd\":25.5}}]}"
            XCTAssertEqual(try read(input).map(\.leftPct), [74.5])
        }
    }

    func testMissingWindowsNewAccountOrUnknownFormatCannotInventLimits() {
        let inputs: [(String, ClaudeDesktopUsage.Problem)] = [
            (#"{"version":2,"samples":[]}"#, .noSample),
            (#"{"version":2,"samples":[{"t":1790000000000,"u":{"sd":15}},{"t":1799999000000,"u":{"cw":20}}]}"#, .noWindows),
            (#"{"version":2,"samples":[{"t":1799999000000,"fh":30}]}"#, .noWindows),
            (#"{"version":3,"samples":[]}"#, .unsupported),
            ("{", .unsupported)
        ]
        for (input, expected) in inputs {
            XCTAssertThrowsError(try read(input)) { XCTAssertEqual($0 as? ClaudeDesktopUsage.Problem, expected) }
        }
    }

    func testEnteredReadingHasExplicitOriginAndCannotGuessAnUnreportedWindow() throws {
        let entry = try XCTUnwrap(ClaudeDesktopUsage.Entry(fiveHourText: " 20 ", weeklyText: "", at: now))
        XCTAssertEqual(entry.windows.map(\.leftPct), [80])
        XCTAssertEqual(entry.windows.first?.manuallyEntered, true)
        XCTAssertEqual(entry.windows.first?.observedAt, now)
        XCTAssertNil(entry.windows.first?.resetsAt)
        for value in ["", "101", "-1", "twenty"] {
            XCTAssertNil(ClaudeDesktopUsage.Entry(fiveHourText: "", weeklyText: value, at: now))
        }
    }

    func testFolderReadFollowsAtomicReplacementsAndRejectsLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent(ClaudeDesktopUsage.filename)
        XCTAssertThrowsError(try ClaudeDesktopUsage.windows(in: root, now: now)) {
            XCTAssertEqual($0 as? ClaudeDesktopUsage.Problem, .noSample)
        }
        for used in [12, 37] {
            let input = "{\"version\":2,\"samples\":[{\"t\":1799999000000,\"u\":{\"sd\":" + String(used) + "}}]}"
            try Data(input.utf8).write(to: file, options: .atomic)
            XCTAssertEqual(try ClaudeDesktopUsage.windows(in: root, now: now).first?.leftPct, Double(100 - used))
        }
        let alternate = root.appendingPathComponent("another-file")
        try manager.moveItem(at: file, to: alternate)
        try manager.createSymbolicLink(at: file, withDestinationURL: alternate)
        XCTAssertThrowsError(try ClaudeDesktopUsage.windows(in: root, now: now)) {
            XCTAssertEqual($0 as? ClaudeDesktopUsage.Problem, .access)
        }
    }
}
