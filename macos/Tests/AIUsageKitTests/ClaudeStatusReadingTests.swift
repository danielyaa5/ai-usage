import XCTest
@testable import AIUsageKit

final class ClaudeStatusReadingTests: XCTestCase {
    func testOnlyLimitFieldsReachTheWidgetReceiver() throws {
        let raw = #"{"session_id":"fixture-private","workspace":{"path":"private"},"rate_limits":{"five_hour":{"used_percentage":18,"resets_at":1800000000,"extra":"private"},"seven_day":{"used_percentage":41},"unknown":4}}"#
        let safe = try XCTUnwrap(ClaudeStatusReading.payload(from: Data(raw.utf8)))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: safe) as? [String: [String: [String: Double]]])
        XCTAssertEqual(root, ["rate_limits": ["five_hour": ["used_percentage": 18, "resets_at": 1800000000],
                                              "seven_day": ["used_percentage": 41]]])
    }

    func testUnsupportedOrInvalidWindowsLeaveValidSiblingsIntact() throws {
        for bad in ["null", "{}", #"{"used_percentage":"unset"}"#, #"{"used_percentage":105}"#] {
            let input = "{\"rate_limits\":{\"five_hour\":" + bad + ",\"seven_day\":{\"used_percentage\":0}}}"
            let safe = try XCTUnwrap(ClaudeStatusReading.payload(from: Data(input.utf8)))
            let windows = try XCTUnwrap((JSONSerialization.jsonObject(with: safe) as? [String: [String: [String: Double]]])?["rate_limits"])
            XCTAssertEqual(windows, ["seven_day": ["used_percentage": 0]])
        }
        for bad in ["", "{}", #"{"rate_limits":null}"#, #"{"rate_limits":{"five_hour":{"used_percentage":-1}}}"#] {
            XCTAssertNil(ClaudeStatusReading.payload(from: Data(bad.utf8)))
        }
    }

    func testCopyRequestUsesOnlyTheInstalledCommand() {
        let path = URL(fileURLWithPath: "/Applications/User's Apps/AI Usage.app/Contents/MacOS/AI Usage")
        let text = ClaudeStatusReading.setupRequest(executable: path)
        XCTAssertTrue(text.hasPrefix("/statusline "))
        XCTAssertTrue(text.contains(#"'/Applications/User'\''s Apps/AI Usage.app/Contents/MacOS/AI Usage' --report-claude-limits"#))
        XCTAssertTrue(text.contains("--pass-through"))
        XCTAssertFalse(text.contains("127.0.0.1"))
        XCTAssertFalse(text.contains("token"))
    }
}
