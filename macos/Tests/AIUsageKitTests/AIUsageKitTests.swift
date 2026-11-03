import XCTest
@testable import AIUsageKit

/// A reply from `/api/widget` on the dashboard's demo data (`scripts/demo.py`), with fixed times.
let fixture = #"""
{
 "generated_at": 1793700000,
 "host": "my-mac",
 "range": "7d",
 "range_label": "Last 7 days",
 "last_scan": 1793699970,
 "plans": [
  {
   "plan": "Claude Max 20x",
   "title": "Claude Max 20x",
   "short": "Claude",
   "vendor": "anthropic",
   "monthly_usd": 200,
   "cost": 41.8653,
   "prorated_usd": 43.68,
   "requests": 961,
   "tokens": 44763456,
   "windows": [
    {
     "label": "5-hour",
     "group": null,
     "group_short": null,
     "left_pct": 66.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    },
    {
     "label": "Weekly",
     "group": null,
     "group_short": null,
     "left_pct": 42.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    }
   ],
   "notes": [
    "Extra usage: off"
   ],
   "warning": null
  },
  {
   "plan": "ChatGPT Pro",
   "title": "ChatGPT Pro",
   "short": "ChatGPT",
   "vendor": "openai",
   "monthly_usd": 200,
   "cost": 34.0966,
   "prorated_usd": 43.68,
   "requests": 245,
   "tokens": 25166686,
   "windows": [
    {
     "label": "5-hour",
     "group": null,
     "group_short": null,
     "left_pct": 88.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    },
    {
     "label": "Weekly",
     "group": null,
     "group_short": null,
     "left_pct": 59.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    }
   ],
   "notes": [],
   "warning": "codex app-server timed out"
  },
  {
   "plan": "Google (Antigravity)",
   "title": "Google AI Ultra (Antigravity)",
   "short": "Antigravity",
   "vendor": "google",
   "monthly_usd": 99.99,
   "cost": 6.4954,
   "prorated_usd": 21.84,
   "requests": 152,
   "tokens": 14503025,
   "windows": [
    {
     "label": "5-hour",
     "group": "Gemini",
     "group_short": "Gemini",
     "left_pct": 78.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    },
    {
     "label": "Weekly",
     "group": "Gemini",
     "group_short": "Gemini",
     "left_pct": 53.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    },
    {
     "label": "5-hour",
     "group": "Claude and GPT-OSS",
     "group_short": "Claude and GPT-OSS",
     "left_pct": 92.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    },
    {
     "label": "Weekly",
     "group": "Claude and GPT-OSS",
     "group_short": "Claude and GPT-OSS",
     "left_pct": 85.0,
     "level": "good",
     "resets_at": 1793703600,
     "observed_at": 1793699880
    }
   ],
   "notes": [],
   "warning": null
  }
 ],
 "totals": {
  "cost": 82.4572,
  "requests": 1358,
  "tokens": 84433167,
  "output": 1771440,
  "unpriced": 0,
  "cache_share": 88,
  "background_cost": 6.6208,
  "top_background_job": {
   "job": "Scheduled: Morning Brief",
   "cost": 2.7008
  }
 }
}

"""#

final class SummaryTests: XCTestCase {
    func testDecodesTheDashboardReply() throws {
        let summary = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        XCTAssertEqual(summary.host, "my-mac")
        XCTAssertEqual(summary.rangeLabel, "Last 7 days")
        XCTAssertEqual(summary.generatedAt, Date(timeIntervalSince1970: 1793700000))
        XCTAssertEqual(summary.plans.map(\.vendor), ["anthropic", "openai", "google"])
        let claude = try XCTUnwrap(summary.plan(vendor: "anthropic"))
        XCTAssertEqual(claude.monthlyUsd, 200)
        XCTAssertEqual(claude.requests, 961)
        XCTAssertEqual(claude.notes, ["Extra usage: off"])
        XCTAssertNil(claude.warning)
        XCTAssertEqual(claude.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(claude.tightest?.label, "Weekly")
        XCTAssertEqual(summary.plan(vendor: "openai")?.warning, "codex app-server timed out")
        let google = try XCTUnwrap(summary.plan(vendor: "google"))
        XCTAssertEqual(google.windows.count, 4)
        XCTAssertEqual(google.windows[0].groupShort, "Gemini")
        XCTAssertEqual(google.windows[0].resetsAt, Date(timeIntervalSince1970: 1793703600))
        XCTAssertEqual(summary.totals.cacheShare, 88)
        XCTAssertEqual(summary.totals.topBackgroundJob?.job, "Scheduled: Morning Brief")
    }

    func testCacheRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SharedStore.folderOverride = folder
        defer {
            SharedStore.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertEqual(SharedStore.server, UsageClient.defaultServer)
        let server = try XCTUnwrap(UsageClient.normalize("my-mac.local:8796"))
        try SharedStore.save(.init(server: server))
        XCTAssertEqual(SharedStore.server.absoluteString, "http://my-mac.local:8796/")
        let summary = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        let at = Date(timeIntervalSince1970: 1793700100)
        SharedStore.cache(summary, range: "7d", at: at)
        let cached = try XCTUnwrap(SharedStore.cached(range: "7d"))
        XCTAssertEqual(cached.summary, summary)
        XCTAssertEqual(cached.fetchedAt, at)
        XCTAssertNil(SharedStore.cached(range: "30d"))
    }

    func testCacheKeepsTheNewerReadingAndForgetsAnOldServer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SharedStore.folderOverride = folder
        defer {
            SharedStore.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        var newer = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        var older = newer
        older.generatedAt = newer.generatedAt.addingTimeInterval(-600)
        older.host = "older"
        SharedStore.cache(newer, range: "7d", at: newer.generatedAt)
        SharedStore.cache(older, range: "7d", at: newer.generatedAt.addingTimeInterval(5))
        XCTAssertEqual(SharedStore.cached(range: "7d")?.summary.host, "my-mac")
        newer.host = "newest"
        newer.generatedAt = newer.generatedAt.addingTimeInterval(60)
        SharedStore.cache(newer, range: "7d")
        XCTAssertEqual(SharedStore.cached(range: "7d")?.summary.host, "newest")

        SharedStore.recordFailure("timed out", range: "7d")
        try SharedStore.save(.init(server: UsageClient.normalize("other-mac.local:8796")))
        XCTAssertNil(SharedStore.cached(range: "7d"))
        XCTAssertNil(SharedStore.failure(range: "7d"), "the old address's failures go too")
    }

    func testRecentCacheIsReusedWithoutAsking() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SharedStore.folderOverride = folder
        defer {
            SharedStore.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        // Nothing listens on the discard port, so only the cache can answer.
        try SharedStore.save(.init(server: URL(string: "http://127.0.0.1:9/")!))
        let summary = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        let fetchedAt = Date(timeIntervalSince1970: 1793700100)
        SharedStore.cache(summary, range: "7d", at: fetchedAt)

        let reused = await Reading.load(range: "7d", reuse: 240, now: fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(reused.summary, summary)
        XCTAssertEqual(reused.fetchedAt, fetchedAt)
        XCTAssertNil(reused.error)

        let offline = await Reading.load(range: "7d", reuse: 240, timeout: 3, now: fetchedAt.addingTimeInterval(600))
        XCTAssertEqual(offline.summary, summary, "falls back to the kept reading")
        XCTAssertEqual(offline.fetchedAt, fetchedAt, "and never restamps it")
        XCTAssertNotNil(offline.error)

        // A widget whose own request fails still shows a reading the app kept fresh, without an error.
        let shared = await Reading.load(range: "7d", reuse: 240, tolerate: 900, timeout: 3,
                                        now: fetchedAt.addingTimeInterval(600))
        XCTAssertEqual(shared.summary, summary)
        XCTAssertNil(shared.error)
    }

    func testAppFailureMakesTheWidgetsSayOffline() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SharedStore.folderOverride = folder
        defer {
            SharedStore.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        try SharedStore.save(.init(server: URL(string: "http://127.0.0.1:9/")!))
        let summary = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        let fetchedAt = Date(timeIntervalSince1970: 1793700100)
        SharedStore.cache(summary, range: "7d", at: fetchedAt)

        // The app's own read fails, and it records that.
        let app = await Reading.load(range: "7d", timeout: 3, record: true, now: fetchedAt.addingTimeInterval(300))
        XCTAssertNotNil(app.error)
        XCTAssertEqual(SharedStore.failure(range: "7d")?.at, fetchedAt.addingTimeInterval(300))

        // A widget then neither reuses nor excuses the kept reading: it says at once that it's old.
        let widget = await Reading.load(range: "7d", reuse: 360, tolerate: 900, timeout: 3,
                                        now: fetchedAt.addingTimeInterval(330))
        XCTAssertEqual(widget.summary, summary)
        XCTAssertEqual(widget.fetchedAt, fetchedAt)
        XCTAssertNotNil(widget.error)

        // A reading taken after the failure counts as current again.
        SharedStore.cache(summary, range: "7d", at: fetchedAt.addingTimeInterval(400))
        let later = await Reading.load(range: "7d", reuse: 360, now: fetchedAt.addingTimeInterval(450))
        XCTAssertNil(later.error)
        SharedStore.clearFailure(range: "7d")
        XCTAssertNil(SharedStore.failure(range: "7d"))
    }

    func testRefreshRequestSkipsTheSharedReading() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SharedStore.folderOverride = folder
        defer {
            SharedStore.folderOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        try SharedStore.save(.init(server: URL(string: "http://127.0.0.1:9/")!))
        let summary = try UsageSummary.decoder.decode(UsageSummary.self, from: Data(fixture.utf8))
        let fetchedAt = Date(timeIntervalSince1970: 1793700100)
        SharedStore.cache(summary, range: "7d", at: fetchedAt)
        SharedStore.requestRefresh(at: fetchedAt.addingTimeInterval(30))
        XCTAssertEqual(SharedStore.refreshRequested, fetchedAt.addingTimeInterval(30))

        // Without the request this reading would be reused (see above); with it, the dashboard is asked.
        let asked = await Reading.load(range: "7d", reuse: 360, timeout: 3, now: fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(asked.fetchedAt, fetchedAt)
        XCTAssertNotNil(asked.error, "it tried the dashboard, which isn't there")
    }

    func testSampleIsComplete() {
        let sample = UsageSummary.sample()
        XCTAssertEqual(sample.plans.count, 3)
        XCTAssertTrue(sample.plans.allSatisfy { !$0.windows.isEmpty })
    }
}

final class ClientTests: XCTestCase {
    func testNormalizesAddresses() {
        XCTAssertEqual(UsageClient.normalize("my-mac.local:8796")?.absoluteString, "http://my-mac.local:8796/")
        XCTAssertEqual(UsageClient.normalize(" http://my-server.local:8088/ai-usage ")?.absoluteString,
                       "http://my-server.local:8088/ai-usage/")
        XCTAssertEqual(UsageClient.normalize("HTTP://192.168.1.20:8796/?range=7d#x")?.absoluteString,
                       "http://192.168.1.20:8796/")
        XCTAssertNil(UsageClient.normalize(""))
        XCTAssertNil(UsageClient.normalize("ftp://my-mac.local"))
        XCTAssertNil(UsageClient.normalize("http://"))
    }

    func testEndpointKeepsThePath() {
        let server = URL(string: "http://my-server.local:8088/ai-usage/")!
        XCTAssertEqual(UsageClient.endpoint(server: server, range: "30d").absoluteString,
                       "http://my-server.local:8088/ai-usage/api/widget?range=30d")
        XCTAssertEqual(UsageClient.endpoint(server: UsageClient.defaultServer, range: "7d").absoluteString,
                       "http://localhost:8796/api/widget?range=7d")
    }

    func testUnreachableServerIsAnError() async {
        do {
            _ = try await UsageClient.fetch(server: URL(string: "http://127.0.0.1:9/")!, timeout: 3)
            XCTFail("expected an error")
        } catch let error as UsageError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("127.0.0.1:9"))
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class FormatTests: XCTestCase {
    func testMoneyAndTokens() {
        XCTAssertEqual(Format.usd(nil), "–")
        XCTAssertEqual(Format.usd(0), "$0")
        XCTAssertEqual(Format.usd(0.004), "<$0.01")
        XCTAssertEqual(Format.usd(41.7), "$41.70")
        XCTAssertEqual(Format.usd(1073.4), "$1,073")
        XCTAssertEqual(Format.price(200), "$200")
        XCTAssertEqual(Format.price(199.99), "$199.99")
        XCTAssertEqual(Format.price(99.5), "$99.50")
        XCTAssertEqual(Format.tokens(0), "0")
        XCTAssertEqual(Format.tokens(950), "950")
        XCTAssertEqual(Format.tokens(9_100_000), "9.1M")
        XCTAssertEqual(Format.tokens(347_000_000), "347M")
        XCTAssertEqual(Format.tokens(2_100_000_000), "2.1B")
        XCTAssertEqual(Format.percent(97.6), "98%")
    }

    func testTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.resets(now.addingTimeInterval(2 * 86400 + 3700), now: now), "resets in 2d 1h")
        XCTAssertEqual(Format.resets(now.addingTimeInterval(4 * 3600 + 52 * 60 + 5), now: now), "resets in 4h 52m")
        XCTAssertEqual(Format.resets(now.addingTimeInterval(20), now: now), "resets in 1m")
        XCTAssertEqual(Format.resets(now.addingTimeInterval(-5), now: now), "reset due")
        XCTAssertEqual(Format.resets(nil, now: now), "")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-360), now: now), "6 min ago")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-21 * 3600), now: now), "21 h ago")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-3 * 86400), now: now), "3 d ago")
    }

    func testLevelsAndStaleness() {
        XCTAssertEqual(Level(leftPct: 10), .critical)
        XCTAssertEqual(Level(leftPct: 30), .warning)
        XCTAssertEqual(Level(leftPct: 31), .good)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = LimitWindow(label: "Weekly", leftPct: 50, resetsAt: now.addingTimeInterval(-1),
                                observedAt: now.addingTimeInterval(-3600))
        XCTAssertFalse(fresh.isStale(now: now))
        XCTAssertTrue(fresh.resetPassed(now: now))
        XCTAssertEqual(fresh.shortLabel, "Week")
        XCTAssertEqual(fresh.status, .good)
        let old = LimitWindow(label: "5-hour", leftPct: 5, resetsAt: nil, observedAt: now.addingTimeInterval(-7 * 3600))
        XCTAssertTrue(old.isStale(now: now))
        XCTAssertEqual(old.status, .critical)
        XCTAssertEqual(old.shortLabel, "5h")
    }
}
