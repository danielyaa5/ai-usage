import Foundation

public extension Reading {
    static let staleAfter: TimeInterval = 45 * 60

    /// The least remaining quota among a provider's current plan and model-group limits.
    func menuBarQuota(for provider: HistoryProvider, at now: Date) -> Int? {
        guard let summary, now.timeIntervalSince(fetchedAt ?? summary.generatedAt) <= Self.staleAfter,
              error == nil || server == SharedStore.localURL else { return nil }
        let limits = summary.plans.filter { $0.vendor == provider.vendor }.flatMap(\.windows)
        let remaining = limits.filter { window in
            if provider == .claude, let group = window.groupShort, group != "All models" {
                return false
            }
            return !window.isStale(now: now) && !window.resetPassed(now: now) && (0...100).contains(window.leftPct)
        }.map(\.leftPct).min()
        return remaining.map { Int($0.rounded()) }
    }
}
