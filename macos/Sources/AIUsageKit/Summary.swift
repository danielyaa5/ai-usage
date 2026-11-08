import Foundation

/// What the dashboard's `/api/widget` returns: each plan with its limit windows, and the period's totals.
public struct UsageSummary: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var host: String
    public var range: String
    public var rangeLabel: String
    public var lastScan: Date?
    public var plans: [Plan]
    /// Older dashboards always include totals. A standalone limit source may have no history.
    public var hasHistory: Bool?
    public var totals: Totals

    public init(generatedAt: Date, host: String, range: String, rangeLabel: String, lastScan: Date?,
                plans: [Plan], totals: Totals) {
        self.generatedAt = generatedAt
        self.host = host
        self.range = range
        self.rangeLabel = rangeLabel
        self.lastScan = lastScan
        self.plans = plans
        self.totals = totals
    }

    public func plan(vendor: String) -> Plan? {
        plans.first { $0.vendor == vendor }
    }

    /// The dashboard's own JSON spelling: snake_case keys, Unix seconds.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

public struct Plan: Codable, Equatable, Sendable, Identifiable {
    public var plan: String
    public var title: String
    public var short: String
    /// anthropic, openai or google.
    public var vendor: String
    public var monthlyUsd: Double?
    /// API-equivalent value of this plan's requests on the dashboard's Mac in the range.
    public var cost: Double
    public var proratedUsd: Double?
    public var requests: Int
    public var tokens: Int
    public var windows: [LimitWindow]
    public var notes: [String]
    /// A limit reader's last error, such as the Claude probe failing.
    public var warning: String?
    /// The same in a few words, written to follow the plan's name ("CLI not found"). Dashboards from
    /// before November 2026 don't send it.
    public var warningShort: String?

    public var id: String { plan }

    public init(plan: String, title: String, short: String, vendor: String, monthlyUsd: Double?, cost: Double,
                proratedUsd: Double?, requests: Int, tokens: Int, windows: [LimitWindow], notes: [String] = [],
                warning: String? = nil, warningShort: String? = nil) {
        self.plan = plan
        self.title = title
        self.short = short
        self.vendor = vendor
        self.monthlyUsd = monthlyUsd
        self.cost = cost
        self.proratedUsd = proratedUsd
        self.requests = requests
        self.tokens = tokens
        self.windows = windows
        self.notes = notes
        self.warning = warning
        self.warningShort = warningShort
    }

    /// The window with the least left: what runs out first.
    public var tightest: LimitWindow? {
        windows.min { $0.leftPct < $1.leftPct }
    }

    /// The reader's error in a few words, for narrow layouts. Without the dashboard's short form, a
    /// short error is used as it is, after any "Probe: " style prefix.
    public var warningPhrase: String? {
        guard let warning else { return nil }
        if let warningShort, !warningShort.isEmpty { return warningShort }
        var text = Substring(warning)
        if let colon = text.range(of: ": "), text.distance(from: text.startIndex, to: colon.lowerBound) <= 20 {
            text = text[colon.upperBound...]
        }
        return text.count <= 24 ? String(text) : "limit check failed"
    }

    /// When the oldest of the plan's readings that are more than six hours old was taken; nil when
    /// none is.
    public func oldestStaleReading(now: Date = Date()) -> Date? {
        windows.filter { $0.isStale(now: now) }.compactMap { $0.observedAt }.min()
    }
}

public struct LimitWindow: Codable, Equatable, Sendable, Identifiable {
    /// "5-hour" or "Weekly".
    public var label: String
    /// Antigravity's model group ("Gemini Models"); nil for Claude and ChatGPT.
    public var group: String?
    /// The group without "models" ("Gemini").
    public var groupShort: String?
    public var leftPct: Double
    /// good, warning or critical, by the dashboard's thresholds (30% and 10% left).
    public var level: String
    public var resetsAt: Date?
    public var observedAt: Date?

    public var id: String { "\(group ?? "")|\(label)" }

    public init(label: String, group: String? = nil, groupShort: String? = nil, leftPct: Double, level: String? = nil,
                resetsAt: Date?, observedAt: Date?) {
        self.label = label
        self.group = group
        self.groupShort = groupShort
        self.leftPct = leftPct
        self.level = level ?? Level(leftPct: leftPct).rawValue
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var status: Level { Level(rawValue: level) ?? Level(leftPct: leftPct) }

    /// "5h" or "Week": for the narrowest layouts.
    public var shortLabel: String {
        switch label {
        case "5-hour": return "5h"
        case "Weekly": return "Week"
        default: return label.replacingOccurrences(of: "Weekly", with: "Week")
        }
    }

    /// Limit readings older than six hours are flagged, as on the dashboard.
    public func isStale(now: Date = Date()) -> Bool {
        guard let observedAt else { return true }
        return now.timeIntervalSince(observedAt) > 6 * 3600
    }

    /// A window whose reset time has passed since the reading: the percentage is out of date.
    public func resetPassed(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

public enum Level: String, Codable, Sendable {
    case good, warning, critical

    public init(leftPct: Double) {
        self = leftPct <= 10 ? .critical : leftPct <= 30 ? .warning : .good
    }

    public var word: String {
        switch self {
        case .good: return "OK"
        case .warning: return "Running low"
        case .critical: return "Almost out"
        }
    }
}

public struct Totals: Codable, Equatable, Sendable {
    public var cost: Double
    public var requests: Int
    public var tokens: Int
    public var output: Int
    public var unpriced: Int
    public var cacheShare: Int
    public var backgroundCost: Double
    public var topBackgroundJob: TopJob?

    public init(cost: Double, requests: Int, tokens: Int, output: Int, unpriced: Int, cacheShare: Int,
                backgroundCost: Double, topBackgroundJob: TopJob?) {
        self.cost = cost
        self.requests = requests
        self.tokens = tokens
        self.output = output
        self.unpriced = unpriced
        self.cacheShare = cacheShare
        self.backgroundCost = backgroundCost
        self.topBackgroundJob = topBackgroundJob
    }
}

public struct TopJob: Codable, Equatable, Sendable {
    public var job: String
    public var cost: Double

    public init(job: String, cost: Double) {
        self.job = job
        self.cost = cost
    }
}
