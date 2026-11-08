import AIUsageKit
import XCTest

final class AntigravityQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testModelGroupsAreOrderedAndOnlyQuotaFieldsReachTheSummary() throws {
        let body = Data(#"""
        {"response":{"groups":[
          {"displayName":"Gemini Models","description":"unused detail","buckets":[
            {"bucketId":"g-week","window":"weekly","remainingFraction":0,"resetTime":"2027-01-05T00:00:00Z"},
            {"bucketId":"g-short","window":"5h","remainingFraction":0.75,"resetTime":"2027-01-01T01:00:00.125Z"}]},
          {"displayName":"Other Models","buckets":[
            {"bucketId":"o-week","window":"weekly","remainingFraction":1}]}
        ]},"account":"unused personal field"}
        """#.utf8)
        let windows = try AntigravityQuota.windows(in: body, at: now)
        XCTAssertEqual(windows.map(\.label), ["5-hour", "Weekly", "Weekly"])
        XCTAssertEqual(windows.map(\.leftPct), [75, 0, 100])
        XCTAssertEqual(windows.map(\.groupShort), ["Gemini", "Gemini", "Other"])
        XCTAssertEqual(windows.map(\.observedAt), [now, now, now])
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
        XCTAssertNil(windows[2].resetsAt)
        let summary = try XCTUnwrap(LocalSummary.build(histories: [:], limits: [.antigravity: windows],
                                                      issues: [:], prices: nil, now: now)["7d"])
        XCTAssertEqual(summary.hasHistory, false)
        XCTAssertEqual(summary.plan(vendor: "google")?.windows, windows)
        let shared = String(decoding: try UsageSummary.encoder.encode(summary), as: UTF8.self)
        XCTAssertFalse(shared.contains("unused"))
    }

    func testIncompleteInvalidAndDuplicateBucketsDoNotCreateExtraReadings() throws {
        let body = Data(#"""
        {"groups":[{"displayName":"Example Models","buckets":[
          {"bucketId":"missing","window":"weekly"},
          {"bucketId":"invalid","window":"5h","remainingFraction":1.3},
          {"bucketId":"weekly","window":"weekly","remainingFraction":0.5,"resetTime":"unknown"},
          {"bucketId":"repeat","window":"weekly","remainingFraction":0.5},
          {"window":"5h","remainingFraction":0.2}
        ]}]}
        """#.utf8)
        let windows = try AntigravityQuota.windows(in: body, at: now)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.leftPct, 50)
        XCTAssertNil(windows.first?.resetsAt)
        XCTAssertEqual(try AntigravityQuota.windows(in: Data("{}".utf8), at: now), [])
        XCTAssertThrowsError(try AntigravityQuota.windows(in: Data("invalid".utf8), at: now))
    }
}
