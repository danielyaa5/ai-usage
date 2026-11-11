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

    func testModelScopedDecodesAndTagsGeneralWindows() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let json = """
        {
          "rate_limits_available": true,
          "rate_limits": {
            "five_hour": {"utilization": 15, "resets_at": "2030-04-01T12:00:00Z"},
            "seven_day": {"utilization": 25, "resets_at": "2030-04-01T12:00:00Z"},
            "model_scoped": [
              {"display_name": "Fable", "utilization": 87, "resets_at": "2030-04-01T12:00:00Z"}
            ]
          }
        }
        """
        let windows = try ClaudeQuotaReply.windows(Data(json.utf8), now: now)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].label, "5-hour")
        XCTAssertEqual(windows[0].group, "Claude Models")
        XCTAssertEqual(windows[0].groupShort, "All models")
        XCTAssertEqual(windows[0].leftPct, 85)

        XCTAssertEqual(windows[1].label, "Weekly")
        XCTAssertEqual(windows[1].group, "Claude Models")
        XCTAssertEqual(windows[1].groupShort, "All models")
        XCTAssertEqual(windows[1].leftPct, 75)

        XCTAssertEqual(windows[2].label, "Weekly")
        XCTAssertEqual(windows[2].group, "Claude Models")
        XCTAssertEqual(windows[2].groupShort, "Fable")
        XCTAssertEqual(windows[2].leftPct, 13)
    }

    func testModelScopedExpiredOrInvalidLeavesGeneralUngrouped() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let json = """
        {
          "rate_limits_available": true,
          "rate_limits": {
            "five_hour": {"utilization": 15, "resets_at": "2030-04-01T12:00:00Z"},
            "seven_day": {"utilization": 25, "resets_at": "2030-04-01T12:00:00Z"},
            "model_scoped": [
              {"display_name": "Fable", "utilization": -1, "resets_at": "2030-04-01T12:00:00Z"},
              {"display_name": "Old", "utilization": 50, "resets_at": "1999-01-01T00:00:00Z"}
            ]
          }
        }
        """
        let windows = try ClaudeQuotaReply.windows(Data(json.utf8), now: now)
        XCTAssertEqual(windows.count, 2)
        XCTAssertNil(windows[0].group)
        XCTAssertNil(windows[0].groupShort)
        XCTAssertNil(windows[1].group)
        XCTAssertNil(windows[1].groupShort)
    }

    func testMenuBarQuotaExcludesFableFromClaudeMeter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = [
            LimitWindow(label: "5-hour", group: "Claude Models", groupShort: "All models",
                        leftPct: 85, resetsAt: now.addingTimeInterval(3600), observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "All models",
                        leftPct: 75, resetsAt: now.addingTimeInterval(86400), observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "Fable",
                        leftPct: 13, resetsAt: now.addingTimeInterval(86400), observedAt: now)
        ]
        let plan = Plan(plan: "Claude Max 20x", title: "Claude Max 20x", short: "Claude",
                        vendor: "anthropic", monthlyUsd: 200, cost: 50, proratedUsd: 50,
                        requests: 10, tokens: 100, windows: windows)
        let summary = UsageSummary(generatedAt: now, host: "test", range: "7d", rangeLabel: "7d",
                                   lastScan: now, plans: [plan],
                                   totals: Totals(cost: 50, requests: 10, tokens: 100, output: 10,
                                                  unpriced: 0, cacheShare: 0, backgroundCost: 0, topBackgroundJob: nil))
        let reading = Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        // Even though Fable is at 13%, menu bar quota for Claude must reflect All models (min(85, 75) = 75).
        XCTAssertEqual(reading.menuBarQuota(for: .claude, at: now), 75)
    }

    func testNoPlanAndInvalidResponseAreNotZeroPercent() {
        for json in [#"{"rate_limits_available":false,"rate_limits":null}"#, #"{"rate_limits_available":true}"#, "{}"] {
            XCTAssertThrowsError(try ClaudeQuotaReply.windows(Data(json.utf8), now: Date()))
        }
    }
}
