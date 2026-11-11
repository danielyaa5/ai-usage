import Foundation

public extension Reading {
    static let staleAfter: TimeInterval = 45 * 60

    /// The remaining quota for a provider's menu bar meter: All models for Claude, the lowest current
    /// limit for ChatGPT, and Gemini's weekly (7-day) limit for Google Antigravity.
    func menuBarQuota(for provider: HistoryProvider, at now: Date) -> Int? {
        guard let summary, now.timeIntervalSince(fetchedAt ?? summary.generatedAt) <= Self.staleAfter,
              error == nil || server == SharedStore.localURL else { return nil }
        let limits = summary.plans.filter { $0.vendor == provider.vendor }.flatMap(\.windows)
        let candidates = Self.menuBarCandidates(limits, for: provider)
        let remaining = candidates.filter { window in
            !window.isStale(now: now) && !window.resetPassed(now: now) && (0...100).contains(window.leftPct)
        }.map(\.leftPct).min()
        return remaining.map { Int($0.rounded()) }
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
