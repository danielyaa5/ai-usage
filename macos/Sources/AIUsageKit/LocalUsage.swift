import Foundation

/// Minimal accounting records. Session text, paths, account IDs and credentials are never published.
public enum HistoryProvider: String, CaseIterable, Codable, Sendable {
    case claude, codex, antigravity

    public var folder: String {
        switch self { case .claude: return ".claude"; case .codex: return ".codex"; case .antigravity: return ".gemini" }
    }
    public var title: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .antigravity: return "Antigravity" }
    }
    public var vendor: String {
        switch self { case .claude: return "anthropic"; case .codex: return "openai"; case .antigravity: return "google" }
    }
    public var logDirectories: [String] {
        switch self {
        case .claude: return ["projects"]
        case .codex: return ["sessions", "archived_sessions"]
        case .antigravity: return ["antigravity/conversations", "antigravity-cli/conversations"]
        }
    }
}

public struct UsageEvent: Sendable, Codable, Equatable {
    public let id: String
    public let date: Date
    public let model: String
    public let input, cached, writes, hourWrites, output: Int
    public let fast: Bool
    public let requests: Int

    public init(id: String, date: Date, model: String, input: Int, cached: Int, writes: Int = 0,
                hourWrites: Int = 0, output: Int, fast: Bool = false, requests: Int = 1) {
        self.id = id
        self.date = date
        self.model = model
        self.input = input
        self.cached = cached
        self.writes = writes
        self.hourWrites = hourWrites
        self.output = output
        self.fast = fast
        self.requests = max(1, requests)
    }

    enum CodingKeys: String, CodingKey {
        case id, date, model, input, cached, writes, hourWrites, output, fast, requests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        model = try container.decode(String.self, forKey: .model)
        input = try container.decode(Int.self, forKey: .input)
        cached = try container.decode(Int.self, forKey: .cached)
        writes = try container.decodeIfPresent(Int.self, forKey: .writes) ?? 0
        hourWrites = try container.decodeIfPresent(Int.self, forKey: .hourWrites) ?? 0
        output = try container.decode(Int.self, forKey: .output)
        fast = try container.decodeIfPresent(Bool.self, forKey: .fast) ?? false
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 1
    }
}

public struct LocalPrices: Decodable, Sendable {
    private struct Price: Decodable, Sendable {
        let input, output: Double
        let cache_read, cache_write, cache_write_1h, fast_multiplier: Double?
    }
    private let models: [String: Price]
    private let aliases: [String: String]
    public func estimate(_ event: UsageEvent) -> Double? {
        let name = String(event.model.lowercased().prefix(while: { $0 != "[" }))
        let model = aliases[name] ?? name
        guard let key = models.keys.filter({ model.hasPrefix($0) }).max(by: { $0.count < $1.count }),
              let p = models[key] else { return nil }
        let hour = min(event.writes, event.hourWrites)
        let charge = Double(event.input) * p.input + Double(event.output) * p.output
            + Double(event.cached) * (p.cache_read ?? p.input * 0.1)
            + Double(event.writes - hour) * (p.cache_write ?? p.input * 1.25)
            + Double(hour) * (p.cache_write_1h ?? p.input * 2)
        return charge / 1_000_000 * (event.fast ? p.fast_multiplier ?? 1 : 1)
    }
}

public struct LocalHistory: Sendable, Codable, Equatable {
    public var events: [String: UsageEvent] = [:]
    public var windows: [LimitWindow] = []
    public init() {}
    public mutating func merge(_ other: LocalHistory) {
        events.merge(other.events) { first, next in first.date > next.date ? first : next }
        if let newest = other.windows.compactMap(\.observedAt).max(),
           newest >= windows.compactMap(\.observedAt).max() ?? .distantPast { windows = other.windows }
    }
}

public enum LocalSummary {
    public static func build(histories: [HistoryProvider: LocalHistory], limits: [HistoryProvider: [LimitWindow]],
                             issues: [HistoryProvider: String], historyIssues: [HistoryProvider: String] = [:],
                             prices: LocalPrices?, now: Date) -> [String: UsageSummary] {
        let calendar = Calendar.current
        var result: [String: UsageSummary] = [:]
        for (range, label, days) in [("today", "Today", 0), ("7d", "Last 7 days", 7), ("30d", "Last 30 days", 30)] {
            let start = days == 0 ? calendar.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86400)
            var plans: [Plan] = []
            var totals = Totals(cost: 0, requests: 0, tokens: 0, output: 0, unpriced: 0, cacheShare: 0,
                                backgroundCost: 0, topBackgroundJob: nil)
            var cachedInput = 0, allInput = 0
            for source in HistoryProvider.allCases {
                let issue = issues[source] ?? (limits[source] == nil ? historyIssues[source] : nil)
                guard histories[source] != nil || limits[source] != nil || issue != nil else { continue }
                let history = histories[source] ?? LocalHistory()
                // Prefer the latest observation, including an account reply with fewer windows.
                let windows = limits[source] ?? history.windows
                var count = 0, tokens = 0, cost = 0.0
                for event in history.events.values where event.date >= start && event.date <= now {
                    let input = event.input + event.cached + event.writes
                    count += event.requests
                    tokens += input + event.output
                    cachedInput += event.cached
                    allInput += input
                    totals.output += event.output
                    if let amount = prices?.estimate(event) { cost += amount } else { totals.unpriced += event.requests }
                }
                let title = source == .codex ? "ChatGPT" : source == .claude ? "Claude" : source.title
                plans.append(Plan(plan: title, title: title, short: title, vendor: source.vendor, monthlyUsd: nil,
                                  cost: cost, proratedUsd: nil, requests: count, tokens: tokens, windows: windows,
                                  notes: [], warning: issue, warningShort: issue == nil ? nil : "Check setup"))
                totals.cost += cost
                totals.tokens += tokens
                totals.requests += count
            }
            totals.cacheShare = allInput == 0 ? 0 : Int((Double(cachedInput) / Double(allInput) * 100).rounded())
            guard !plans.isEmpty else { continue }
            var summary = UsageSummary(generatedAt: now, host: "This Mac", range: range, rangeLabel: label, lastScan: now,
                                       plans: plans, totals: totals)
            summary.hasHistory = !histories.isEmpty
            result[range] = summary
        }
        return result
    }
}

public enum LocalLimits {
    public static func window(_ used: Double?, minutes: Int?, reset: Double?, at date: Date,
                              group: String? = nil, fallback: String = "Limit") -> LimitWindow? {
        guard let used, used.isFinite, (0...100).contains(used) else { return nil }
        let label: String
        switch minutes { case 300: label = "5-hour"; case 10080: label = "Weekly"; case 1440: label = "Daily"
        case let value? where value > 0: label = "\(value) min"; default: label = fallback }
        return LimitWindow(label: label, group: group, groupShort: group, leftPct: 100 - used,
                           resetsAt: reset.map(Date.init(timeIntervalSince1970:)), observedAt: date)
    }
}
