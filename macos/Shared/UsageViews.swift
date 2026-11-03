import AppIntents
import SwiftUI
import WidgetKit
import AIUsageKit

// The widget layouts. The app draws the same views for its previews and its menu bar panel, so each
// takes its size as a parameter instead of reading it from the widget environment.

// MARK: - Building blocks

/// A percent-left bar. Its outline keeps the shape readable when the desktop draws widgets without
/// color (vibrant, behind other windows, and accented modes).
struct MeterBar: View {
    var left: Double
    var level: Level
    var height: CGFloat = 5
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let fraction = max(0, min(1, left / 100))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule().fill(palette.fill(level))
                    .frame(width: geometry.size.width * fraction)
                    .widgetAccentable()
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(left.rounded())) percent left")
    }
}

struct PlanSwatch: View {
    var vendor: String
    var size: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Palette(scheme: scheme).plan(vendor))
            .frame(width: size, height: size)
            .widgetAccentable()
    }
}

/// "98%" in the level's color, with a clock when the reading is old or the window has reset since.
struct PercentLeft: View {
    var window: LimitWindow
    var now: Date
    var size: CGFloat = 12
    var suffix = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let status = window.status
        HStack(spacing: 2) {
            if window.isStale(now: now) || window.resetPassed(now: now) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.stale)
            } else if status != .good {
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.text(status))
            }
            Text(Format.percent(window.leftPct) + suffix)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(status == .good ? palette.primary : palette.text(status))
        }
        .lineLimit(1)
    }
}

extension LimitWindow {
    /// "Weekly", or "Gemini weekly" when the plan has model groups.
    var name: String {
        guard let groupShort else { return label }
        return "\(groupShort) \(label.lowercased())"
    }

    /// What the line under a bar says: when it resets, or that the reading is old.
    func caption(now: Date) -> String {
        if resetPassed(now: now) { return "reset due · as of \(Format.ago(observedAt, now: now))" }
        if isStale(now: now) { return "as of \(Format.ago(observedAt, now: now))" }
        return Format.resets(resetsAt, now: now)
    }
}

/// A plan's windows for one model group (Antigravity has two); `group` is nil for the other plans.
struct LimitGroup: Identifiable {
    var group: String?
    var windows: [LimitWindow]
    var id: String { group ?? "" }
}

/// Model groups in their order.
func grouped(_ windows: [LimitWindow]) -> [LimitGroup] {
    var out: [LimitGroup] = []
    for window in windows {
        if let index = out.firstIndex(where: { $0.group == window.groupShort }) {
            out[index].windows.append(window)
        } else {
            out.append(LimitGroup(group: window.groupShort, windows: [window]))
        }
    }
    return out
}

/// One line and a thin bar: for the narrow columns.
struct CompactWindowRow: View {
    var window: LimitWindow
    var now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(window.shortLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette(scheme: scheme).secondary)
                Spacer(minLength: 2)
                PercentLeft(window: window, now: now, size: 11)
            }
            MeterBar(left: window.leftPct, level: window.status, height: 4)
        }
    }
}

/// Label, percent, bar and when it resets.
struct WindowRow: View {
    var window: LimitWindow
    var now: Date
    var showGroup = false
    var percentSize: CGFloat = 13
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(showGroup ? window.name : window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                PercentLeft(window: window, now: now, size: percentSize, suffix: " left")
            }
            MeterBar(left: window.leftPct, level: window.status)
            Text(window.caption(now: now))
                .font(.system(size: 9.5))
                .foregroundStyle(window.isStale(now: now) || window.resetPassed(now: now) ? palette.stale : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

struct PlanTitle: View {
    var plan: Plan
    var short = true
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(spacing: 5) {
            PlanSwatch(vendor: plan.vendor, size: size * 0.66)
            Text(short ? plan.short : plan.title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if plan.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.text(.warning))
                    .help(plan.warning ?? "")
            }
        }
    }
}

/// A line at the bottom when the data isn't current. Clicking it reads the dashboard again.
struct FreshnessFooter: View {
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let note = entry.freshnessNote {
            Button(intent: RefreshUsageIntent()) {
                HStack(spacing: 3) {
                    Image(systemName: entry.error != nil ? "wifi.exclamationmark" : "arrow.clockwise")
                    Text(note)
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette(scheme: scheme).stale)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
            .help(entry.error ?? "Read the dashboard again")
        }
    }
}

/// No reading yet and none cached.
struct UnavailableView: View {
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 20))
                .foregroundStyle(palette.muted)
            Text("Can't reach AI Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
            Text(hostAndPort(entry.server))
                .font(.system(size: 10).monospaced())
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Click to check the dashboard address in AI Usage.")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(intent: RefreshUsageIntent()) {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func hostAndPort(_ url: URL) -> String {
    (url.host ?? url.absoluteString) + (url.port.map { ":\($0)" } ?? "") + (url.path.count > 1 ? url.path : "")
}

// MARK: - Plan limits widget

struct LimitsWidgetView: View {
    var entry: UsageEntry
    var family: WidgetFamily

    var body: some View {
        if entry.summary == nil {
            UnavailableView(entry: entry)
        } else if let plan = entry.plans.first, entry.vendor != nil {
            switch family {
            case .systemSmall: SinglePlanSmall(plan: plan, entry: entry)
            default: SinglePlanWide(plan: plan, entry: entry, family: family)
            }
        } else {
            switch family {
            case .systemSmall: AllPlansSmall(entry: entry)
            case .systemMedium: AllPlansMedium(entry: entry)
            default: AllPlansLarge(entry: entry, family: family)
            }
        }
    }
}

/// Each plan's tightest window: what runs out first.
struct AllPlansSmall: View {
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let note = entry.freshnessNote != nil
        VStack(alignment: .leading, spacing: note ? 4 : 7) {
            ForEach(entry.plans) { plan in
                if let window = plan.tightest {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            PlanTitle(plan: plan, size: 12)
                            Spacer(minLength: 2)
                            PercentLeft(window: window, now: entry.date, size: 12)
                        }
                        MeterBar(left: window.leftPct, level: window.status)
                        if !note {
                            Text("\(window.name) · \(Format.remaining(until: window.resetsAt, now: entry.date) ?? "reset due")")
                                .font(.system(size: 9.5))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                } else {
                    HStack {
                        PlanTitle(plan: plan, size: 12)
                        Spacer()
                        Text("no reading").font(.system(size: 10)).foregroundStyle(palette.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            FreshnessFooter(entry: entry)
        }
    }
}

struct SinglePlanSmall: View {
    var plan: Plan
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            PlanTitle(plan: plan, short: false, size: 12)
            if plan.windows.isEmpty {
                Text("No limit reading yet.").font(.system(size: 11)).foregroundStyle(palette.muted)
            } else if plan.windows.count <= 2 {
                ForEach(plan.windows) { window in
                    WindowRow(window: window, now: entry.date, percentSize: 15)
                }
            } else {
                ForEach(grouped(plan.windows)) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        if let name = group.group {
                            Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        ForEach(group.windows) { CompactWindowRow(window: $0, now: entry.date) }
                    }
                }
            }
            Spacer(minLength: 0)
            if let warning = plan.warning, entry.freshnessNote == nil {
                Text(warning)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.text(.warning))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            FreshnessFooter(entry: entry)
        }
    }
}

/// One plan in a medium, large or extra-large widget: its windows two to a row, and its value.
struct SinglePlanWide: View {
    var plan: Plan
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
        VStack(alignment: .leading, spacing: family == .systemMedium ? 7 : 10) {
            HStack(alignment: .firstTextBaseline) {
                PlanTitle(plan: plan, short: false, size: 13)
                Spacer()
                if let monthly = plan.monthlyUsd {
                    Text(Format.usd(monthly) + "/mo").font(.system(size: 10)).foregroundStyle(palette.muted)
                }
            }
            if plan.windows.isEmpty {
                Text("No limit reading yet.").font(.system(size: 11)).foregroundStyle(palette.muted)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: family == .systemMedium ? 6 : 10) {
                    ForEach(plan.windows) { window in
                        WindowRow(window: window, now: entry.date, showGroup: window.groupShort != nil)
                    }
                }
            }
            Spacer(minLength: 0)
            if family != .systemMedium || plan.windows.count <= 2 {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(Format.usd(plan.cost)).fontWeight(.semibold) + Text(" at API prices")
                        + Text(plan.proratedUsd.map { " vs \(Format.usd($0)) of plan price" } ?? ""))
                    Text("\(Format.grouped(plan.requests)) requests · \(Format.tokens(plan.tokens)) tokens · \(entry.summary?.rangeLabel.lowercased() ?? "")")
                        .foregroundStyle(palette.muted)
                }
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            if let warning = plan.warning {
                Text(warning).font(.system(size: 9.5, weight: .medium)).foregroundStyle(palette.text(.warning)).lineLimit(1)
            }
            FreshnessFooter(entry: entry)
        }
    }
}

/// The three plans side by side, one line per window.
struct AllPlansMedium: View {
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(entry.plans) { plan in
                    VStack(alignment: .leading, spacing: 5) {
                        PlanTitle(plan: plan, size: 11)
                        if plan.windows.isEmpty {
                            Text("No reading").font(.system(size: 10)).foregroundStyle(palette.muted)
                        }
                        ForEach(grouped(plan.windows)) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                if let name = group.group {
                                    Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.muted).lineLimit(1)
                                }
                                ForEach(group.windows) { CompactWindowRow(window: $0, now: entry.date) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            FreshnessFooter(entry: entry)
        }
    }
}

/// Large and extra large: the plans with reset times, then the period's totals.
struct AllPlansLarge: View {
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(entry: entry, title: "AI plan limits")
            HStack(alignment: .top, spacing: 14) {
                ForEach(entry.plans) { plan in
                    VStack(alignment: .leading, spacing: 7) {
                        PlanTitle(plan: plan, short: family != .systemExtraLarge, size: 12)
                        if plan.windows.isEmpty {
                            Text("No limit reading yet.").font(.system(size: 10)).foregroundStyle(palette.muted)
                        }
                        ForEach(grouped(plan.windows)) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                if let name = group.group {
                                    Text(name).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(palette.muted).lineLimit(1)
                                }
                                ForEach(group.windows) { WindowRow(window: $0, now: entry.date, percentSize: 12) }
                            }
                        }
                        if let warning = plan.warning {
                            Text(warning).font(.system(size: 9.5)).foregroundStyle(palette.text(.warning)).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            if let summary = entry.summary {
                Divider().overlay(palette.divider)
                TotalsRow(summary: summary, compact: family != .systemExtraLarge)
            }
            FreshnessFooter(entry: entry)
        }
    }
}

struct WidgetHeader: View {
    var entry: UsageEntry
    var title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(palette.primary)
            if let host = entry.summary?.host {
                Text(host).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer()
            if entry.freshnessNote == nil, let at = entry.fetchedAt ?? entry.summary?.generatedAt {
                Text(at, style: .time).font(.system(size: 10)).foregroundStyle(palette.muted)
            }
        }
    }
}

// MARK: - Usage widget

struct Stat: Identifiable {
    var label: String
    var value: String
    var hint: String
    var id: String { label }
}

func stats(_ summary: UsageSummary) -> [Stat] {
    let t = summary.totals
    return [
        Stat(label: "API-equivalent value", value: Format.usd(t.cost),
             hint: (t.unpriced > 0 ? "\(Format.grouped(t.unpriced)) unpriced · " : "") + summary.rangeLabel.lowercased()),
        Stat(label: "Model requests", value: Format.grouped(t.requests), hint: "\(Format.tokens(t.output)) output tokens"),
        Stat(label: "Tokens processed", value: Format.tokens(t.tokens), hint: "\(t.cacheShare)% from cache"),
        Stat(label: "Background jobs", value: Format.usd(t.backgroundCost),
             hint: t.topBackgroundJob.map { "top: \($0.job) (\(Format.usd($0.cost)))" } ?? "none in this range"),
    ]
}

struct TotalsRow: View {
    var summary: UsageSummary
    var compact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(alignment: .top, spacing: 10) {
            ForEach(stats(summary)) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(compact ? shortLabel(stat.label) : stat.label)
                        .font(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                    Text(stat.value)
                        .font(.system(size: compact ? 14 : 17, weight: .bold)).monospacedDigit()
                        .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.7)
                    if !compact {
                        Text(stat.hint).font(.system(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func shortLabel(_ label: String) -> String {
        ["API-equivalent value": "API value", "Model requests": "Requests", "Tokens processed": "Tokens",
         "Background jobs": "Background"][label] ?? label
    }
}

struct UsageWidgetView: View {
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let summary = entry.summary {
            let palette = Palette(scheme: scheme)
            let all = stats(summary)
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API-equivalent value").font(.system(size: 10)).foregroundStyle(palette.muted)
                    Text(all[0].value)
                        .font(.system(size: 26, weight: .bold)).monospacedDigit()
                        .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.6)
                    Text(summary.rangeLabel).font(.system(size: 10)).foregroundStyle(palette.muted)
                    Spacer(minLength: 4)
                    ForEach(all.dropFirst()) { stat in
                        HStack {
                            Text(stat.label.replacingOccurrences(of: " processed", with: "").replacingOccurrences(of: "Model ", with: ""))
                                .foregroundStyle(palette.secondary)
                            Spacer(minLength: 4)
                            Text(stat.value).fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.primary)
                        }
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                    FreshnessFooter(entry: entry)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(entry: entry, title: summary.rangeLabel)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading, spacing: 8) {
                        ForEach(all) { stat in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stat.label).font(.system(size: 9.5)).foregroundStyle(palette.muted).lineLimit(1)
                                Text(stat.value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.6)
                                Text(stat.hint).font(.system(size: 9)).foregroundStyle(palette.muted)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                    FreshnessFooter(entry: entry)
                }
            }
        } else {
            UnavailableView(entry: entry)
        }
    }
}

// MARK: - Previews outside WidgetKit (the app's window and image renders)

enum PreviewSize {
    static func points(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: return CGSize(width: 170, height: 170)
        case .systemMedium: return CGSize(width: 364, height: 170)
        case .systemLarge: return CGSize(width: 364, height: 382)
        case .systemExtraLarge: return CGSize(width: 749, height: 382)
        default: return CGSize(width: 170, height: 170)
        }
    }
}

/// A widget-shaped card with the widget's default margins, for previews in the app and renders.
struct WidgetCard<Content: View>: View {
    var family: WidgetFamily
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = PreviewSize.points(family)
        content
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Palette(scheme: scheme).background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
