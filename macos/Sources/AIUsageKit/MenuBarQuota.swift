import Foundation

public extension Reading {
    static let staleAfter: TimeInterval = 45 * 60

    /// The least remaining quota among a provider's current plan and model-group limits.
    func menuBarQuota(for provider: HistoryProvider, at now: Date) -> Int? {
        guard let summary, now.timeIntervalSince(fetchedAt ?? summary.generatedAt) <= Self.staleAfter,
              error == nil || server == SharedStore.localURL else { return nil }
        let limits = summary.plans.filter { $0.vendor == provider.vendor }.flatMap(\.windows)
        let remaining = limits.filter {
            !$0.isStale(now: now) && !$0.resetPassed(now: now) && (0...100).contains($0.leftPct)
        }.map(\.leftPct).min()
        return remaining.map { Int($0.rounded()) }
    }
}
