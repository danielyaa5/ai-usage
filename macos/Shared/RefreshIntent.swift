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

    func perform() async throws -> some IntentResult {
        // macOS doesn't redraw a widget while its button's intent runs, so keep this short.
        async let today = Reading.load(range: "today", timeout: 8)
        async let week = Reading.load(range: "7d", timeout: 8)
        async let month = Reading.load(range: "30d", timeout: 8)
        _ = await (today, week, month)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
