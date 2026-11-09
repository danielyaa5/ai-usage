import XCTest
@testable import AIUsageKit

final class ClaudeQuotaReplyTests: XCTestCase {
    func testOnlyReturnedWholePlanWindowsAreShown() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":27,"resets_at":"2030-04-01T12:00:00.123456+00:00"},"seven_day_sonnet":{"utilization":86}}}"#.utf8)
        let windows = try ClaudeQuotaReply.windows(data, now: now)
        XCTAssertEqual(windows.map(\.label), ["Weekly"])
        XCTAssertEqual(windows.first?.leftPct, 73)
        XCTAssertEqual(windows.first?.observedAt, now)
        XCTAssertNotNil(windows.first?.resetsAt)
    }

    func testExpiredOrInvalidPercentagesAreOmitted() throws {
        let data = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":-1},"seven_day":{"utilization":0,"resets_at":"2000-04-01T12:00:00Z"}}}"#.utf8)
        XCTAssertTrue(try ClaudeQuotaReply.windows(data, now: Date()).isEmpty)
    }

    func testNoPlanAndInvalidResponseAreNotZeroPercent() {
        for json in [#"{"rate_limits_available":false,"rate_limits":null}"#, #"{"rate_limits_available":true}"#, "{}"] {
            XCTAssertThrowsError(try ClaudeQuotaReply.windows(Data(json.utf8), now: Date()))
        }
    }
}
