import AppIntents
import AppKit
import WidgetKit
import AIUsageKit

/// The periods the widgets show. The plan limits widget reads the 7-day reply, which carries the
/// limits and each plan's own week of use.
enum UsageRanges {
    static let all = ["today", "7d", "30d"]
    static let limits = "7d"
}

/// The refresh control on a widget whose reading is old or offline. It runs in the widget extension
/// (it doesn't open the app), reads the dashboard again and redraws every AI Usage widget.
///
/// It is in both the app and the extension, so their App Intents metadata match: a button whose intent
/// only one side knows does nothing when clicked.
struct RefreshUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh AI usage"
    static let description = IntentDescription("Reads the AI Usage dashboard again and redraws the widgets.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    /// Set by the app. The same buttons show in the app's own windows (the settings preview and the
    /// menu bar panel), where the intent runs in the app: there the app reads again itself, so what it
    /// shows updates and its recorded failures clear. In the widget extension this stays nil.
    @MainActor static var inApp: (@MainActor () -> Void)?

    func perform() async throws -> some IntentResult {
        SharedStore.markRefreshing()
        WidgetCenter.shared.reloadAllTimelines()

        // 1. In-app trigger
        if await Self.refreshInApp() {
            let start = Date()
            while Date().timeIntervalSince(start) < 6.0 {
                if !SharedStore.isRefreshing() { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        // 2. Running in widget extension (inApp == nil)
        let config = SharedStore.loadConfig()
        let isLocal = (config.source == .local || config.server == SharedStore.localURL)

        if isLocal {
            let baselineSnapshot = SharedStore.readLocalSnapshot()
            let baselineTimestamp = baselineSnapshot?.summaries.values.compactMap(\.generatedAt).max() ?? .distantPast

            let hostBundleID: String
            if let bundleID = Bundle.main.bundleIdentifier {
                if bundleID.hasSuffix(".Widgets") {
                    hostBundleID = String(bundleID.dropLast(".Widgets".count))
                } else {
                    hostBundleID = bundleID
                }
            } else {
                hostBundleID = (Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String) ?? "AIUsage"
            }

            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("\(hostBundleID).refresh"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )

            let running = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
            if running.isEmpty {
                let openConfig = NSWorkspace.OpenConfiguration()
                openConfig.activates = false
                openConfig.addsToRecentItems = false
                NSWorkspace.shared.open(AppLink.refresh.url, configuration: openConfig, completionHandler: nil)
            }

            let pollStart = Date()
            while Date().timeIntervalSince(pollStart) < 6.0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let currentSnapshot = SharedStore.readLocalSnapshot()
                let currentTimestamp = currentSnapshot?.summaries.values.compactMap(\.generatedAt).max() ?? .distantPast
                if currentTimestamp > baselineTimestamp {
                    break
                }
            }

            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        } else {
            // Dashboard mode
            await withTaskGroup(of: Void.self) { group in
                for range in UsageRanges.all {
                    group.addTask { _ = await Reading.load(range: range, timeout: 8) }
                }
            }
            SharedStore.clearRefreshing()
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }
    }

    @MainActor private static func refreshInApp() -> Bool {
        guard let inApp else { return false }
        inApp()
        return true
    }
}
