import Foundation
import WidgetKit
import AIUsageKit

enum AppLink: String {
    case settings, dashboard, refresh

    static let scheme = Bundle.main.object(forInfoDictionaryKey: "AIUsageURLScheme") as? String ?? "aiusage"
    var url: URL { URL(string: Self.scheme + "://" + rawValue)! }
}

/// What every widget draws: the latest reading (fresh or cached), why a refresh failed, and which plan
/// the widget was set to show (nil = all plans).
struct UsageEntry: TimelineEntry {
    var date: Date
    var summary: UsageSummary?
    var fetchedAt: Date?
    var error: String?
    var server: URL
    var localState: Reading.LocalState?
    var vendor: String?
    var isSample = false

    init(date: Date = Date(), reading: Reading, vendor: String? = nil) {
        self.date = date
        summary = reading.summary
        fetchedAt = reading.fetchedAt
        error = reading.error
        server = reading.server
        localState = reading.localState
        self.vendor = vendor
    }

    init(date: Date, summary: UsageSummary?, fetchedAt: Date?, error: String?, server: URL, vendor: String?,
         isSample: Bool = false) {
        self.date = date
        self.summary = summary
        self.fetchedAt = fetchedAt
        self.error = error
        self.server = server
        self.vendor = vendor
        self.isSample = isSample
    }

    static func sample(vendor: String? = nil, now: Date = Date()) -> UsageEntry {
        UsageEntry(date: now, summary: .sample(now: now), fetchedAt: now, error: nil,
                   server: UsageClient.defaultServer, vendor: vendor, isSample: true)
    }

    /// Readings older than this say "Refresh needed" instead of passing for current.
    static let staleAfter = Reading.staleAfter

    var dataAge: TimeInterval? {
        guard let at = fetchedAt ?? summary?.generatedAt else { return nil }
        return date.timeIntervalSince(at)
    }

    /// A short line for the bottom of a widget when the reading isn't current; nil when it is.
    var freshnessNote: String? {
        Reading(summary: summary, fetchedAt: fetchedAt, error: error, server: server)
            .freshnessNote(now: date, staleAfter: Self.staleAfter)
    }

    var plans: [Plan] {
        guard let summary else { return [] }
        if let vendor { return summary.plans.filter { $0.vendor == vendor } }
        return summary.plans
    }

    func missingLimits(for plan: Plan) -> String {
        server == SharedStore.localURL && plan.vendor == "google"
            ? "Open Settings and choose Google Antigravity to connect quota." : "No limit reading yet."
    }

    /// Where a click goes: the app, which opens the dashboard in the browser, or its settings when
    /// there's nothing to show.
    var tapURL: URL {
        if localState == .readingSources { return AppLink.refresh.url }
        return summary == nil || server == SharedStore.localURL || server == SharedStore.demoURL
            ? AppLink.settings.url : AppLink.dashboard.url
    }
}
