import Foundation

public struct MenuBarMeter: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public struct Colors: Equatable, Sendable {
        public let ink: RGB
        public let track: RGB

        public init(ink: RGB, track: RGB) {
            self.ink = ink
            self.track = track
        }
    }

    public static let redThresholdPct: Double = 20

    public static let sage = RGB(red: 161 / 255, green: 173 / 255, blue: 141 / 255)
    public static let forest = RGB(red: 36 / 255, green: 49 / 255, blue: 32 / 255)
    public static let criticalDarkInk = RGB(red: 240 / 255, green: 104 / 255, blue: 104 / 255)
    public static let criticalDarkTrack = RGB(red: 84 / 255, green: 24 / 255, blue: 24 / 255)
    public static let criticalLightInk = RGB(red: 184 / 255, green: 36 / 255, blue: 36 / 255)
    public static let criticalLightTrack = RGB(red: 224 / 255, green: 158 / 255, blue: 158 / 255)

    public let provider: HistoryProvider
    public let remainingPct: Double?

    public init(provider: HistoryProvider, remainingPct: Double?) {
        self.provider = provider
        self.remainingPct = remainingPct
    }

    public init(provider: HistoryProvider, percent: Int?) {
        self.provider = provider
        self.remainingPct = percent.map(Double.init)
    }

    public var percent: Int? {
        remainingPct.map { Int($0.rounded()) }
    }

    /// Menu bar meters turn red when remaining quota is strictly below 20%.
    public var isRed: Bool {
        guard let remainingPct else { return false }
        return remainingPct < Self.redThresholdPct
    }

    public func colors(dark: Bool) -> Colors {
        if isRed {
            return dark
                ? Colors(ink: Self.criticalDarkInk, track: Self.criticalDarkTrack)
                : Colors(ink: Self.criticalLightInk, track: Self.criticalLightTrack)
        }
        return dark
            ? Colors(ink: Self.sage, track: Self.forest)
            : Colors(ink: Self.forest, track: Self.sage)
    }

    public var shortName: String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "GPT"
        case .antigravity: return "Google"
        }
    }

    public var detail: String {
        percent.map { "\($0)% left" } ?? "No current quota"
    }
}

public extension Reading {
    static let staleAfter: TimeInterval = 45 * 60

    /// Exact remaining quota percentage (0...100) for a provider's menu bar meter: All models for
    /// Claude, the lowest current limit for ChatGPT, and Gemini's weekly (7-day) limit for Google Antigravity.
    func menuBarRemaining(for provider: HistoryProvider, at now: Date) -> Double? {
        guard let summary, now.timeIntervalSince(fetchedAt ?? summary.generatedAt) <= Self.staleAfter,
              error == nil || server == SharedStore.localURL else { return nil }
        let limits = summary.plans.filter { $0.vendor == provider.vendor }.flatMap(\.windows)
        let candidates = Self.menuBarCandidates(limits, for: provider)
        return candidates.filter { window in
            !window.isStale(now: now) && !window.resetPassed(now: now) && (0...100).contains(window.leftPct)
        }.map(\.leftPct).min()
    }

    /// Rounded remaining quota for a provider's menu bar meter.
    func menuBarQuota(for provider: HistoryProvider, at now: Date) -> Int? {
        menuBarRemaining(for: provider, at: now).map { Int($0.rounded()) }
    }

    /// Complete menu bar meter state (preserving unrounded `< 20%` red threshold accuracy).
    func menuBarMeter(for provider: HistoryProvider, at now: Date) -> MenuBarMeter {
        MenuBarMeter(provider: provider, remainingPct: menuBarRemaining(for: provider, at: now))
    }

    private static func menuBarCandidates(_ limits: [LimitWindow], for provider: HistoryProvider) -> [LimitWindow] {
        switch provider {
        case .claude:
            return limits.filter { window in
                let isAllModelsGroup = window.groupShort.map {
                    $0.caseInsensitiveCompare("All models") == .orderedSame
                } ?? true
                return isAllModelsGroup && !window.label.contains("(")
                    && !window.label.localizedCaseInsensitiveContains("seven day ")
            }
        case .antigravity:
            let hasGroups = limits.contains { ($0.groupShort ?? $0.group) != nil }
            let googleWindows = hasGroups ? limits.filter(isGoogleModelWindow) : limits
            let weekly = googleWindows.filter { $0.label.caseInsensitiveCompare("Weekly") == .orderedSame }
            return weekly.isEmpty ? googleWindows : weekly
        case .codex:
            return limits
        }
    }

    private static func isGoogleModelWindow(_ window: LimitWindow) -> Bool {
        guard let group = (window.groupShort ?? window.group)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !group.isEmpty else { return false }
        return group.localizedCaseInsensitiveContains("gemini") || group.localizedCaseInsensitiveContains("google")
    }
}
