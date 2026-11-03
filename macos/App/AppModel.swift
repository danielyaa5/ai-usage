import AppKit
import Foundation
import WidgetKit
import AIUsageKit

/// Reads the dashboard on a timer, keeps the shared reading the widgets fall back on, and asks macOS to
/// redraw the widgets when what they show has changed.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var readings: [String: Reading] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var server: URL = SharedStore.server

    /// How often the dashboard is read while it answers. Failures back off to 30 minutes.
    static let interval: TimeInterval = 5 * 60

    private var timer: Timer?
    private var failures = 0
    /// Bumped when the address changes, so a read of the old address that finishes late is dropped.
    private var generation = 0
    private var shown: String?
    private var lastReload: Date?

    var limits: Reading? { readings[UsageRanges.limits] }

    /// What the menu bar panel and the settings preview draw.
    func entry(vendor: String? = nil, range: String = UsageRanges.limits, now: Date = Date()) -> UsageEntry {
        UsageEntry(date: now, reading: readings[range] ?? Reading(summary: nil, fetchedAt: nil, error: nil, server: server),
                   vendor: vendor)
    }

    func start() {
        // Show the kept readings at once, then read the dashboard.
        for range in UsageRanges.all {
            if let kept = SharedStore.cached(range: range) {
                readings[range] = Reading(summary: kept.summary, fetchedAt: kept.fetchedAt, error: nil, server: server)
            }
        }
        reloadWidgets()
        refresh()
    }

    /// Reads every period now unless a read is already running (one at a time).
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        timer?.invalidate()
        let run = generation
        Task { await self.readAll(run: run) }
    }

    private func readAll(run: Int) async {
        let now = Date()
        var results: [String: Reading] = [:]
        await withTaskGroup(of: (String, Reading).self) { group in
            for range in UsageRanges.all {
                group.addTask { (range, await Reading.load(range: range, now: now)) }
            }
            for await (range, reading) in group {
                results[range] = reading
            }
        }
        guard run == generation else { return }
        readings = results
        lastAttempt = now
        refreshing = false
        failures = results.values.contains { $0.error != nil } ? failures + 1 : 0

        // Redraw when something the widgets show changed, and at least every half hour so their
        // "as of" times stay true even when macOS defers their own reloads.
        let signature = Self.signature(results)
        if signature != shown || lastReload.map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true {
            shown = signature
            reloadWidgets(at: now)
        }
        schedule()
    }

    private func schedule() {
        let backoff = failures == 0 ? 1 : pow(2, Double(min(failures, 3)))
        let delay = min(30 * 60, Self.interval * backoff)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func reloadWidgets(at date: Date = Date()) {
        WidgetCenter.shared.reloadAllTimelines()
        lastReload = date
    }

    /// The readings as the widgets draw them: whole percents, reset times, warnings, rounded totals.
    static func signature(_ readings: [String: Reading]) -> String {
        readings.keys.sorted().map { range -> String in
            guard let reading = readings[range] else { return range }
            guard let summary = reading.summary else { return "\(range):none:\(reading.error != nil)" }
            let plans = summary.plans.map { plan in
                plan.vendor + ":" + plan.windows.map { window in
                    "\(window.id)=\(Int(window.leftPct.rounded()))@\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))"
                }.joined(separator: ",") + ":" + (plan.warning ?? "") + ":\(Int(plan.cost))"
            }.joined(separator: ";")
            let totals = summary.totals
            return "\(range):\(plans):\(Int(totals.cost)):\(totals.requests / 10):\(totals.tokens / 1_000_000):"
                + "\(Int(totals.backgroundCost)):\(reading.error != nil)"
        }.joined(separator: "|")
    }

    // MARK: - Settings

    /// Saves a new dashboard address and reads it. Returns why the address can't be used, if it can't.
    func setServer(_ text: String) -> String? {
        guard let url = UsageClient.normalize(text) else {
            return "Enter an address such as my-mac.local:8796."
        }
        do {
            try SharedStore.save(.init(server: url))
        } catch {
            return "Couldn't save the address: \(error.localizedDescription)"
        }
        server = url
        generation += 1
        readings = [:]
        shown = nil
        failures = 0
        reloadWidgets()
        refreshing = false
        refresh()
        return nil
    }

    func openDashboard() {
        NSWorkspace.shared.open(server)
    }
}
