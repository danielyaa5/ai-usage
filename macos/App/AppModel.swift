import AppKit
import Foundation
import WidgetKit
import AIUsageKit

enum SettingsPage { case connections, widgets, menuBar, advanced }

/// Reads the dashboard on a timer, keeps the shared reading the widgets fall back on, and asks macOS to
/// redraw the widgets when what they show has changed.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var readings: [String: Reading] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var server: URL

    @Published private(set) var source: SharedStore.Source
    @Published var settingsPage = SettingsPage.connections
    @Published var settingsProvider = HistoryProvider.claude
    @Published private(set) var setup: SetupJourney?
    @Published var showsSetup = true
    private let defaults: UserDefaults
    @Published private(set) var meterProviders: Set<HistoryProvider>
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    let supportDraft = SupportDraft()
    @Published var showsSupport = false

    func openSupport() {
        supportDraft.prepareForDisplay(model: self)
        showsSupport = true
    }

    let local: LocalSources

    init(sampleSetup: Bool = false) {
        let config = sampleSetup ? SharedStore.Config() : SharedStore.loadConfig()
        let defaults = sampleSetup ? UserDefaults(suiteName: "store-preview-" + UUID().uuidString)! : .standard
        self.defaults = defaults
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        meterProviders = Set((defaults.stringArray(forKey: "menuBarMeters") ?? []).compactMap(HistoryProvider.init(rawValue:)))
        setup = SetupJourney.restore(defaults.data(forKey: "setupJourney"))
        source = config.source
        server = config.server ?? UsageClient.defaultServer
        local = LocalSources(defaults: defaults)
    }

    func setMeter(_ provider: HistoryProvider, enabled: Bool) {
        if enabled { meterProviders.insert(provider) } else { meterProviders.remove(provider) }
        defaults.set(HistoryProvider.allCases.filter(meterProviders.contains).map(\.rawValue), forKey: "menuBarMeters")
    }

    static func sampleMenuBar(_ summary: UsageSummary) -> AppModel {
        let model = AppModel(sampleSetup: true)
        model.source = .demo
        model.showsSetup = false
        model.settingsPage = .menuBar
        model.meterProviders = Set(HistoryProvider.allCases)
        model.readings[UsageRanges.limits] = Reading(summary: summary, fetchedAt: summary.generatedAt,
                                                      error: nil, server: SharedStore.demoURL)
        return model
    }

    func prepareSetupIfNeeded() {
        guard source == .local, setup == nil, !defaults.bool(forKey: "setupShown") else { return }
        beginSetup()
    }

    func beginSetup() {
        if source != .local { setSource(.local) }
        guard source == .local else { return }
        showsSetup = true
        saveSetup(SetupJourney())
    }

    func editSetup(_ edit: (inout SetupJourney) -> Void) {
        guard var progress = setup else { return }
        edit(&progress)
        saveSetup(progress)
    }

    func finishSetup(page: SettingsPage = .connections) {
        if let tool = setup?.tools.first { settingsProvider = tool }
        showsSetup = false
        saveSetup(nil)
        settingsPage = page
        if source == .local, local.hasSources {
            reloadAfterSetup = true
            refresh()
        }
    }

    private func saveSetup(_ progress: SetupJourney?) {
        defaults.set(true, forKey: "setupShown")
        if let progress, let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "setupJourney") }
        else { defaults.removeObject(forKey: "setupJourney") }
        setup = progress
    }
    private var refreshAgain = false
    private var reloadAfterSetup = false

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
        UsageEntry(date: now, reading: readings[range] ?? Reading(summary: nil, fetchedAt: nil, error: nil, server: source == .local ? SharedStore.localURL : server),
                   vendor: vendor)
    }

    func start() {
        local.changed = { [weak self] in self?.refresh() }
        local.activate(source == .local)
        local.connectionStateChanged = { [weak self] in
            guard let self, self.source == .local else { return }
            for range in UsageRanges.all { self.readings[range] = SharedStore.localReading(range: range) }
            self.shown = Self.signature(self.readings)
            self.reloadWidgets()
        }
        // A dashboard reading is never shown in local or demonstration mode.
        for range in UsageRanges.all {
            if source == .local { readings[range] = SharedStore.localReading(range: range) }
            if source == .dashboard, let kept = SharedStore.cached(range: range) {
                readings[range] = Reading(summary: kept.summary, fetchedAt: kept.fetchedAt, error: nil, server: server)
            }
        }
        reloadWidgets()
        refresh()
    }

    /// Reads every period now unless a read is already running (one at a time).
    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        timer?.invalidate()
        let run = generation
        Task { await self.readAll(run: run) }
    }

    private func readAll(run: Int) async {
        let now = Date()
        let revision = local.revision
        var results: [String: Reading] = [:]
        if source == .local {
            let snapshot = await local.collect(now: now)
            guard run == generation else { return }
            guard let snapshot, revision == local.revision else { restartLocalRead(); return }
            do { try SharedStore.publishLocal(snapshot) }
            catch { local.notice = "Could not share the reading with the widget. Reopen AI Usage and try again." }
        }
        guard run == generation else { return }
        if source == .local && revision != local.revision { restartLocalRead(); return }
        await withTaskGroup(of: (String, Reading).self) { group in
            for range in UsageRanges.all {
                group.addTask { (range, await Reading.load(range: range, record: true, now: now)) }
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
        if reloadAfterSetup || signature != shown || lastReload.map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true {
            reloadAfterSetup = false
            shown = signature
            reloadWidgets(at: now)
        }
        if refreshAgain { refreshAgain = false; refresh() } else { schedule() }
    }

    /// The connected sources changed while their reading was in flight. Read the new set without
    /// publishing the interrupted result or replacing the app's preview with an empty entry.
    private func restartLocalRead() {
        refreshing = false
        refreshAgain = false
        refresh()
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
            guard let summary = reading.summary else { return "\(range):\(reading.localState?.rawValue ?? "none"):\(reading.error != nil)" }
            let plans = summary.plans.map { plan in
                plan.vendor + ":" + plan.windows.map { window in
                    "\(window.id)=\(Int(window.leftPct.rounded()))@\(Int((window.resetsAt ?? window.observedAt)?.timeIntervalSince1970 ?? 0))"
                }.joined(separator: ",") + ":" + (plan.warning ?? "") + ":\(Int(plan.cost))"
            }.joined(separator: ";")
            let totals = summary.totals
            return "\(range):\(plans):\(Int(totals.cost)):\(totals.requests):\(totals.tokens):"
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
            try SharedStore.save(.init(server: url, source: .dashboard))
        } catch {
            return "Couldn't save the address: \(error.localizedDescription)"
        }
        change(to: .dashboard, server: url)
        return nil
    }

    func setSource(_ value: SharedStore.Source) {
        guard source != value else { return }
        let address = SharedStore.loadConfig().server
        do { try SharedStore.save(.init(server: address, source: value)) }
        catch { local.notice = "Could not save the source."; return }
        change(to: value, server: address ?? UsageClient.defaultServer)
    }

    private func change(to value: SharedStore.Source, server url: URL) {
        reloadAfterSetup = false
        source = value
        server = url
        local.activate(value == .local)
        refreshAgain = false
        generation += 1
        readings = [:]
        shown = nil
        failures = 0
        reloadWidgets()
        refreshing = false
        refresh()
    }

    func openDashboard() {
        if source == .dashboard, let address = SharedStore.loadConfig().server { NSWorkspace.shared.open(address) }
        else { SettingsWindow.show(model: self, page: .widgets) }
    }
}
