import Foundation

public extension UsageSummary {
    /// Fictional numbers for widget placeholders, the widget gallery and screenshots.
    static func sample(now: Date = Date()) -> UsageSummary {
        func window(_ label: String, _ left: Double, resetsIn: TimeInterval, group: String? = nil) -> LimitWindow {
            LimitWindow(label: label, group: group.map { "\($0) Models" }, groupShort: group, leftPct: left,
                        resetsAt: now.addingTimeInterval(resetsIn), observedAt: now.addingTimeInterval(-180))
        }
        let plans = [
            Plan(plan: "Claude Max 20x", title: "Claude Max 20x", short: "Claude", vendor: "anthropic", monthlyUsd: 200,
                 cost: 508.2, proratedUsd: 41.7, requests: 4661, tokens: 1_400_000_000,
                 windows: [window("5-hour", 72, resetsIn: 2 * 3600 + 900), window("Weekly", 58, resetsIn: 2 * 86400 + 3600)],
                 notes: ["Extra usage: off"]),
            Plan(plan: "ChatGPT Pro", title: "ChatGPT Pro", short: "ChatGPT", vendor: "openai", monthlyUsd: 200,
                 cost: 448.1, proratedUsd: 41.7, requests: 2632, tokens: 347_000_000,
                 windows: [window("Weekly", 31, resetsIn: 15 * 3600 + 58 * 60)]),
            Plan(plan: "Google (Antigravity)", title: "Google AI Ultra (Antigravity)", short: "Antigravity", vendor: "google",
                 monthlyUsd: 199.99, cost: 118.4, proratedUsd: 41.69, requests: 3739, tokens: 376_000_000,
                 windows: [window("5-hour", 98, resetsIn: 300, group: "Gemini"),
                           window("Weekly", 83, resetsIn: 2 * 86400 + 10 * 3600, group: "Gemini"),
                           window("5-hour", 100, resetsIn: 4 * 3600 + 52 * 60, group: "Claude and GPT"),
                           window("Weekly", 94, resetsIn: 2 * 86400 + 19 * 3600, group: "Claude and GPT")]),
        ]
        return UsageSummary(generatedAt: now, host: "my-mac", range: "7d", rangeLabel: "Last 7 days", lastScan: now,
                            plans: plans,
                            totals: Totals(cost: 1073.4, requests: 11032, tokens: 2_100_000_000, output: 9_100_000,
                                           unpriced: 78, cacheShare: 96, backgroundCost: 141.2,
                                           topBackgroundJob: TopJob(job: "Nightly report", cost: 73.39)))
    }
}
