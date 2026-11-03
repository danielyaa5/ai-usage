import AppIntents
import SwiftUI
import WidgetKit
import os
import AIUsageKit

@main
struct AIUsageWidgets: WidgetBundle {
    var body: some Widget {
        PlanLimitsWidget()
        UsageTotalsWidget()
    }
}

// MARK: - Choices in Edit Widget

enum PlanChoice: String, AppEnum {
    case all, claude, chatgpt, google

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Plan"
    static let caseDisplayRepresentations: [PlanChoice: DisplayRepresentation] = [
        .all: "All plans",
        .claude: "Claude",
        .chatgpt: "ChatGPT",
        .google: "Google AI (Antigravity)",
    ]

    /// The dashboard's vendor name; nil for all plans.
    var vendor: String? {
        switch self {
        case .all: return nil
        case .claude: return "anthropic"
        case .chatgpt: return "openai"
        case .google: return "google"
        }
    }
}

struct PlanLimitsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Plan limits"
    static let description = IntentDescription("Show every plan, or one plan in more detail.")

    @Parameter(title: "Plan", default: .all)
    var plan: PlanChoice

    init() {}

    init(plan: PlanChoice) {
        self.plan = plan
    }
}

enum PeriodChoice: String, AppEnum {
    case today, week, month

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [PeriodChoice: DisplayRepresentation] = [
        .today: "Today",
        .week: "Last 7 days",
        .month: "Last 30 days",
    ]

    var range: String {
        switch self {
        case .today: return "today"
        case .week: return "7d"
        case .month: return "30d"
        }
    }
}

struct UsageTotalsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage totals"
    static let description = IntentDescription("Choose the period to total.")

    @Parameter(title: "Period", default: .week)
    var period: PeriodChoice

    init() {}

    init(period: PeriodChoice) {
        self.period = period
    }
}

// MARK: - Timelines

enum Timelines {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AIUsageWidgets", category: "timeline")

    /// Logs the size macOS gives the widget, which differs from the iPhone sizes in PreviewSize, so
    /// the renders can be kept close to real widgets. Read it with
    /// `/usr/bin/log show --last 1h --predicate 'category == "timeline"'` (zsh's `log` is another command).
    static func note(_ context: TimelineProviderContext) {
        let size = context.displaySize
        log.notice("\(String(describing: context.family), privacy: .public) widget: \(Double(size.width), format: .fixed(precision: 1)) x \(Double(size.height), format: .fixed(precision: 1)) points")
    }

    /// The app refreshes the shared reading every 5 minutes; a widget asks the dashboard itself only
    /// when that reading is older than this (the app isn't running, or is backing off).
    static let reuse: TimeInterval = 6 * 60
    /// If the widget's own request fails, a shared reading this recent still counts as current.
    static let tolerate: TimeInterval = 15 * 60

    /// One reading, redrawn every 5 minutes for two hours: reset countdowns keep moving and an old
    /// reading turns into "Refresh needed" on time, even when macOS puts off the next reload.
    static func timeline(range: String, vendor: String?) async -> Timeline<UsageEntry> {
        let now = Date()
        let reading = await Reading.load(range: range, reuse: reuse, tolerate: tolerate, timeout: 10, now: now)
        let first = UsageEntry(date: now, reading: reading, vendor: vendor)
        let entries = (0...24).map { step -> UsageEntry in
            var entry = first
            entry.date = now.addingTimeInterval(Double(step) * 5 * 60)
            return entry
        }
        // Ask again sooner while the dashboard can't be reached.
        let next = now.addingTimeInterval(reading.error == nil ? 15 * 60 : 5 * 60)
        return Timeline(entries: entries, policy: .after(next))
    }

    static func snapshot(range: String, vendor: String?, context: TimelineProviderContext) async -> UsageEntry {
        // The widget gallery shows made-up numbers at once instead of waiting on the network.
        if context.isPreview { return .sample(vendor: vendor) }
        let reading = await Reading.load(range: range, reuse: reuse, tolerate: tolerate, timeout: 10)
        return UsageEntry(reading: reading, vendor: vendor)
    }
}

struct LimitsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: PlanLimitsIntent, in context: Context) async -> UsageEntry {
        await Timelines.snapshot(range: UsageRanges.limits, vendor: configuration.plan.vendor, context: context)
    }

    func timeline(for configuration: PlanLimitsIntent, in context: Context) async -> Timeline<UsageEntry> {
        Timelines.note(context)
        return await Timelines.timeline(range: UsageRanges.limits, vendor: configuration.plan.vendor)
    }
}

struct TotalsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: UsageTotalsIntent, in context: Context) async -> UsageEntry {
        await Timelines.snapshot(range: configuration.period.range, vendor: nil, context: context)
    }

    func timeline(for configuration: UsageTotalsIntent, in context: Context) async -> Timeline<UsageEntry> {
        Timelines.note(context)
        return await Timelines.timeline(range: configuration.period.range, vendor: nil)
    }
}

// MARK: - Widgets

struct PlanLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PlanLimits", intent: PlanLimitsIntent.self, provider: LimitsProvider()) { entry in
            LimitsEntryView(entry: entry)
        }
        .configurationDisplayName("AI plan limits")
        .description("What's left of your Claude, ChatGPT and Google AI plan limits, and when each resets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct UsageTotalsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageTotals", intent: UsageTotalsIntent.self, provider: TotalsProvider()) { entry in
            TotalsEntryView(entry: entry)
        }
        .configurationDisplayName("AI usage totals")
        .description("API-equivalent value, model requests, tokens and background jobs for today, 7 or 30 days.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LimitsEntryView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        MeasuredWidget { LimitsWidgetView(entry: entry, family: family) }
            .modifier(WidgetBackground())
            .widgetURL(entry.tapURL)
    }
}

struct TotalsEntryView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        MeasuredWidget { UsageWidgetView(entry: entry, family: family) }
            .modifier(WidgetBackground())
            .widgetURL(entry.tapURL)
    }
}

/// The dashboard's background. macOS drops it when it draws the widget without color.
struct WidgetBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.containerBackground(Palette(scheme: scheme).background, for: .widget)
    }
}
