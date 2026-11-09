import XCTest
@testable import AIUsageKit

final class MenuBarQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLowestCurrentWindowForEachProvider() {
        var summary = UsageSummary.localSample(range: "7d", now: now)
        let index = summary.plans.firstIndex { $0.vendor == "google" }!
        summary.plans[index].windows[0].leftPct = 0
        var reading = Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        XCTAssertEqual(reading.menuBarQuota(for: .antigravity, at: now), 0)
        XCTAssertEqual(reading.menuBarQuota(for: .claude, at: now), 58)
        XCTAssertEqual(reading.menuBarQuota(for: .codex, at: now), 31)

        summary.plans[index].windows[0].resetsAt = now
        summary.plans[index].windows[1].observedAt = now.addingTimeInterval(-7 * 3600)
        reading.summary = summary
        XCTAssertEqual(reading.menuBarQuota(for: .antigravity, at: now), 94)
    }

    func testUnavailableReadingsNeverBecomeFullOrEmptyMeters() {
        let summary = UsageSummary.localSample(range: "7d", now: now)
        let cached = Reading(summary: summary, fetchedAt: now, error: "Offline", server: UsageClient.defaultServer)
        XCTAssertNil(cached.menuBarQuota(for: .claude, at: now))
        var local = Reading(summary: summary, fetchedAt: now, error: "Unrelated history issue", server: SharedStore.localURL)
        XCTAssertEqual(local.menuBarQuota(for: .claude, at: now), 58)
        XCTAssertNil(local.menuBarQuota(for: .claude, at: now.addingTimeInterval(46 * 60)))
        local.summary?.plans.removeAll { $0.vendor == "anthropic" }
        XCTAssertNil(local.menuBarQuota(for: .claude, at: now))
    }
}
