import AppIntents
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
        if await Self.refreshInApp() { return .result() }
        // macOS doesn't redraw a widget while its button's intent runs, so this returns at once. The
        // request makes the timelines macOS reloads next read the dashboard rather than reuse the
        // shared reading; the reads below redraw every widget again when they finish.
        SharedStore.requestRefresh()
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for range in UsageRanges.all {
                    group.addTask { _ = await Reading.load(range: range, timeout: 8) }
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }

    @MainActor private static func refreshInApp() -> Bool {
        guard let inApp else { return false }
        inApp()
        return true
    }
}
