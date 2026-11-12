import XCTest
@testable import AIUsageKit

final class MenuBarQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLowestCurrentWindowForEachProvider() {
        var summary = UsageSummary.localSample(range: "7d", now: now)
        let index = summary.plans.firstIndex { $0.vendor == "google" }!
        // Lowering Gemini 5-hour to 0% must not affect Google's meter, which pins to Gemini Weekly (83%).
        summary.plans[index].windows[0].leftPct = 0
        var reading = Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        XCTAssertEqual(reading.menuBarQuota(for: .antigravity, at: now), 83)
        XCTAssertEqual(reading.menuBarQuota(for: .claude, at: now), 58)
        XCTAssertEqual(reading.menuBarQuota(for: .codex, at: now), 31)

        // When Gemini Weekly is stale, Google must report nil rather than falling through to Claude and GPT (94%).
        summary.plans[index].windows[0].resetsAt = now
        summary.plans[index].windows[1].observedAt = now.addingTimeInterval(-7 * 3600)
        reading.summary = summary
        XCTAssertNil(reading.menuBarQuota(for: .antigravity, at: now))
    }

    func testGoogleMeterAlwaysUsesGeminiWeeklyQuota() {
        let reset = now.addingTimeInterval(3600)
        func makeReading(_ windows: [LimitWindow], server: URL = SharedStore.localURL) -> Reading {
            let plan = Plan(plan: "Antigravity", title: "Antigravity", short: "Antigravity",
                            vendor: "google", monthlyUsd: nil, cost: 0, proratedUsd: nil,
                            requests: 0, tokens: 0, windows: windows)
            let summary = UsageSummary(generatedAt: now, host: "This Mac", range: "7d", rangeLabel: "Last 7 days",
                                       lastScan: now, plans: [plan],
                                       totals: Totals(cost: 0, requests: 0, tokens: 0, output: 0,
                                                      unpriced: 0, cacheShare: 0, backgroundCost: 0, topBackgroundJob: nil))
            return Reading(summary: summary, fetchedAt: now, error: nil, server: server)
        }

        // Exact scenario: Claude and GPT 5h is 22% and Weekly is 55%, while Gemini 5h is 85% and Weekly is 75%.
        let mixed = makeReading([
            LimitWindow(label: "5-hour", group: "Gemini Models", groupShort: "Gemini", leftPct: 85, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Gemini Models", groupShort: "Gemini", leftPct: 74.6, resetsAt: reset, observedAt: now),
            LimitWindow(label: "5-hour", group: "Claude and GPT models", groupShort: "Claude and GPT", leftPct: 21.6, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude and GPT models", groupShort: "Claude and GPT", leftPct: 55, resetsAt: reset, observedAt: now)
        ])
        XCTAssertEqual(mixed.menuBarQuota(for: .antigravity, at: now), 75)

        // Even if Gemini 5-hour session is lower than Gemini Weekly (40% vs 75%), Google meter still shows 75% (7-day).
        let lowerSession = makeReading([
            LimitWindow(label: "5-hour", group: "Gemini Models", groupShort: "Gemini", leftPct: 40, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Gemini Models", groupShort: "Gemini", leftPct: 75, resetsAt: reset, observedAt: now),
            LimitWindow(label: "5-hour", group: "Claude and GPT-OSS", groupShort: "Claude and GPT-OSS", leftPct: 12, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude and GPT-OSS", groupShort: "Claude and GPT-OSS", leftPct: 30, resetsAt: reset, observedAt: now)
        ], server: UsageClient.defaultServer)
        XCTAssertEqual(lowerSession.menuBarQuota(for: .antigravity, at: now), 75)

        // Fallback if Gemini has no Weekly split at all: uses Gemini's window, still never Claude and GPT.
        let geminiWithoutWeekly = makeReading([
            LimitWindow(label: "5-hour", group: "Gemini Models", groupShort: "Gemini", leftPct: 64, resetsAt: reset, observedAt: now),
            LimitWindow(label: "5-hour", group: "Claude and GPT models", groupShort: "Claude and GPT", leftPct: 18, resetsAt: reset, observedAt: now)
        ])
        XCTAssertEqual(geminiWithoutWeekly.menuBarQuota(for: .antigravity, at: now), 64)

        // Only non-Google groups present -> nil.
        let nonGoogleOnly = makeReading([
            LimitWindow(label: "Weekly", group: "Claude and GPT models", groupShort: "Claude and GPT", leftPct: 22, resetsAt: reset, observedAt: now)
        ])
        XCTAssertNil(nonGoogleOnly.menuBarQuota(for: .antigravity, at: now))
    }

    func testClaudeMeterAlwaysUsesAllModelsInLocalAndDashboardModes() {
        let reset = now.addingTimeInterval(3600)
        func makeClaude(_ windows: [LimitWindow], server: URL = SharedStore.localURL) -> Reading {
            let plan = Plan(plan: "Claude Max 20x", title: "Claude Max 20x", short: "Claude",
                            vendor: "anthropic", monthlyUsd: 200, cost: 0, proratedUsd: nil,
                            requests: 0, tokens: 0, windows: windows)
            let summary = UsageSummary(generatedAt: now, host: "This Mac", range: "7d", rangeLabel: "Last 7 days",
                                       lastScan: now, plans: [plan],
                                       totals: Totals(cost: 0, requests: 0, tokens: 0, output: 0,
                                                      unpriced: 0, cacheShare: 0, backgroundCost: 0, topBackgroundJob: nil))
            return Reading(summary: summary, fetchedAt: now, error: nil, server: server)
        }

        // Local mode: All models (40% 5h, 75% Weekly) vs Fable (10% Weekly) -> picks All models (40%), never Fable (10%).
        let localLowerSession = makeClaude([
            LimitWindow(label: "5-hour", group: "Claude Models", groupShort: "All models", leftPct: 40, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "All models", leftPct: 75, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "Fable", leftPct: 10, resetsAt: reset, observedAt: now)
        ])
        XCTAssertEqual(localLowerSession.menuBarQuota(for: .claude, at: now), 40)

        // Dashboard /api/widget mode: model-scoped unifiedWindows have nil groupShort and labels like "Weekly (Fable)".
        let dashboard = makeClaude([
            LimitWindow(label: "5-hour", group: nil, groupShort: nil, leftPct: 85, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly", group: nil, groupShort: nil, leftPct: 72, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly (Fable)", group: nil, groupShort: nil, leftPct: 9, resetsAt: reset, observedAt: now),
            LimitWindow(label: "Weekly (Opus)", group: nil, groupShort: nil, leftPct: 14, resetsAt: reset, observedAt: now)
        ], server: UsageClient.defaultServer)
        XCTAssertEqual(dashboard.menuBarQuota(for: .claude, at: now), 72)

        // Expired All models must return nil rather than falling through to Fable.
        let expiredAllModels = makeClaude([
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "All models", leftPct: 20, resetsAt: now, observedAt: now),
            LimitWindow(label: "Weekly", group: "Claude Models", groupShort: "Fable", leftPct: 10, resetsAt: reset, observedAt: now)
        ])
        XCTAssertNil(expiredAllModels.menuBarQuota(for: .claude, at: now))
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
        XCTAssertFalse(local.menuBarMeter(for: .claude, at: now).isRed)
    }

    func testMenuBarMeterTurnsRedStrictlyUnderTwentyPercent() {
        for redValue in [0.0, 0.4, 1.0, 10.0, 19.0, 19.9, 19.99] {
            let meter = MenuBarMeter(provider: .claude, remainingPct: redValue)
            XCTAssertTrue(meter.isRed, "Expected \(redValue)% to be red (< 20%)")
            let dark = meter.colors(dark: true)
            let light = meter.colors(dark: false)
            XCTAssertEqual(dark, MenuBarMeter.Colors(ink: MenuBarMeter.criticalDarkInk, track: MenuBarMeter.criticalDarkTrack))
            XCTAssertEqual(light, MenuBarMeter.Colors(ink: MenuBarMeter.criticalLightInk, track: MenuBarMeter.criticalLightTrack))
            XCTAssertGreaterThan(dark.ink.red, dark.ink.green)
            XCTAssertGreaterThan(dark.track.red, dark.track.green)
            XCTAssertGreaterThan(light.ink.red, light.ink.green)
            XCTAssertGreaterThan(light.track.red, light.track.green)
        }

        for nonRedValue in [20.0, 20.1, 25.0, 30.0, 50.0, 100.0] {
            let meter = MenuBarMeter(provider: .codex, remainingPct: nonRedValue)
            XCTAssertFalse(meter.isRed, "Expected \(nonRedValue)% to stay non-red (>= 20%)")
            XCTAssertEqual(meter.colors(dark: true), MenuBarMeter.Colors(ink: MenuBarMeter.sage, track: MenuBarMeter.forest))
            XCTAssertEqual(meter.colors(dark: false), MenuBarMeter.Colors(ink: MenuBarMeter.forest, track: MenuBarMeter.sage))
        }

        let missing = MenuBarMeter(provider: .antigravity, remainingPct: nil)
        XCTAssertFalse(missing.isRed)
        XCTAssertEqual(missing.colors(dark: true), MenuBarMeter.Colors(ink: MenuBarMeter.sage, track: MenuBarMeter.forest))
        XCTAssertEqual(missing.colors(dark: false), MenuBarMeter.Colors(ink: MenuBarMeter.forest, track: MenuBarMeter.sage))

        // Widget/dashboard thresholds remain untouched (30% warning, 10% critical).
        XCTAssertEqual(Level(leftPct: 19), .warning)
        XCTAssertEqual(Level(leftPct: 10), .critical)
        XCTAssertEqual(Level(leftPct: 30), .warning)
        XCTAssertEqual(Level(leftPct: 31), .good)
    }

    func testReadingMenuBarMeterPreservesFractionalBoundaryUnderTwentyPercent() {
        let reset = now.addingTimeInterval(3600)
        func makeReading(leftPct: Double) -> Reading {
            let plan = Plan(plan: "ChatGPT Pro", title: "ChatGPT Pro", short: "ChatGPT",
                            vendor: "openai", monthlyUsd: 200, cost: 0, proratedUsd: nil,
                            requests: 0, tokens: 0, windows: [
                                LimitWindow(label: "Weekly", leftPct: leftPct, resetsAt: reset, observedAt: now)
                            ])
            let summary = UsageSummary(generatedAt: now, host: "This Mac", range: "7d", rangeLabel: "Last 7 days",
                                       lastScan: now, plans: [plan],
                                       totals: Totals(cost: 0, requests: 0, tokens: 0, output: 0,
                                                      unpriced: 0, cacheShare: 0, backgroundCost: 0, topBackgroundJob: nil))
            return Reading(summary: summary, fetchedAt: now, error: nil, server: SharedStore.localURL)
        }

        // 19.9% rounds to 20 for text display, but is strictly under 20% so the meter turns red.
        let justUnder = makeReading(leftPct: 19.9).menuBarMeter(for: .codex, at: now)
        XCTAssertEqual(justUnder.remainingPct, 19.9)
        XCTAssertEqual(justUnder.percent, 20)
        XCTAssertTrue(justUnder.isRed)

        let exactTwenty = makeReading(leftPct: 20.0).menuBarMeter(for: .codex, at: now)
        XCTAssertEqual(exactTwenty.remainingPct, 20.0)
        XCTAssertEqual(exactTwenty.percent, 20)
        XCTAssertFalse(exactTwenty.isRed)

        let zero = makeReading(leftPct: 0.0).menuBarMeter(for: .codex, at: now)
        XCTAssertEqual(zero.remainingPct, 0.0)
        XCTAssertEqual(zero.percent, 0)
        XCTAssertTrue(zero.isRed)
    }
}
