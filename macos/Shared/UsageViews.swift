import AppIntents
import AppKit
import SwiftUI
import WidgetKit
import AIUsageKit

// The widget layouts. The app draws the same views for its previews and its menu bar panel, so each
// takes its size as a parameter instead of reading it from the widget environment.
//
// They are planned for macOS's widget content areas (16-point margins): small 138×138, medium 332×138,
// large 332×350, extra large 717×350. Percentages are never cut short; the labels beside them give way
// first. Titles don't shrink to fit, so plans side by side read at the same size.

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

/// "72%", or "72% left", in the level's color, with a clock when the reading is old or the window has
/// reset since. Always drawn whole: the views beside it give way.
struct PercentLeft: View {
    var window: LimitWindow
    var now: Date
    var size: CGFloat = 12
    var left = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let status = window.status
        let old = window.isOld(now: now)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if old || status != .good {
                Image(systemName: old ? "clock.badge.exclamationmark" : status.symbol)
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(old ? palette.stale : palette.text(status))
            }
            (Text(Format.percent(window.leftPct))
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(status == .good ? palette.primary : palette.text(status))
             + Text(left ? " left" : "")
                .font(.system(size: size * 0.8))
                .foregroundStyle(palette.muted))
        }
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }
}

extension LimitWindow {
    /// "Weekly", or "Gemini weekly" when the plan has model groups.
    var name: String {
        guard let groupShort else { return label }
        return "\(groupShort) \(label.lowercased())"
    }

    /// The reading is old, or the window has reset since it was taken: the percentage is out of date.
    func isOld(now: Date) -> Bool {
        isStale(now: now) || resetPassed(now: now)
    }

    /// What the line under a bar says: when it resets, or that the reading is old.
    func caption(now: Date) -> String {
        if resetPassed(now: now) { return "reset due · as of \(Format.ago(observedAt, now: now))" }
        if isStale(now: now) { return "as of \(Format.ago(observedAt, now: now))" }
        return Format.resets(resetsAt, now: now)
    }

    /// The short form for table cells: "2h 15m" to the reset, "reset due", or nothing.
    func untilReset(now: Date) -> String {
        if resetPassed(now: now) { return "reset due" }
        return Format.remaining(until: resetsAt, now: now) ?? ""
    }
}

extension Plan {
    /// Whether the plan's windows come in model groups, as Antigravity's do.
    var hasGroups: Bool { windows.contains { $0.groupShort != nil } }
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

/// The width of a line of text in the system font, for sizing a column to its longest label.
func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
}

/// Label, percent left, bar and when it resets. `inline` puts the time to the reset after the label
/// instead of under the bar, which saves a line in the medium widget.
struct WindowRow: View {
    var window: LimitWindow
    var now: Date
    var percentSize: CGFloat = 13
    var inline = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let until = window.untilReset(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(inline && !until.isEmpty ? "\(window.label) · \(until)" : window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                PercentLeft(window: window, now: now, size: percentSize, left: true)
            }
            MeterBar(left: window.leftPct, level: window.status)
            if !inline {
                Text(window.caption(now: now))
                    .font(.system(size: 9.5))
                    .foregroundStyle(window.isOld(now: now) ? palette.stale : palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

/// Half a small widget: "5h 98%", a thin bar and the time to the reset.
struct MiniCell: View {
    var window: LimitWindow
    var now: Date
    var caption = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.shortLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                PercentLeft(window: window, now: now, size: 11)
            }
            MeterBar(left: window.leftPct, level: window.status, height: 4)
            if caption {
                Text(window.untilReset(now: now))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(window.resetPassed(now: now) ? palette.stale : palette.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The plan's swatch and name. `full` uses the whole title ("Claude Max 20x") when it fits and the
/// short name ("Antigravity") when it doesn't.
struct PlanTitle: View {
    var plan: Plan
    var full = false
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(spacing: 5) {
            PlanSwatch(vendor: plan.vendor, size: size * 0.66)
            if full {
                ViewThatFits(in: .horizontal) {
                    name(plan.title, palette)
                    name(plan.short, palette)
                }
            } else {
                name(plan.short, palette)
            }
            if plan.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.text(.warning))
                    .help(plan.warning ?? "")
            }
        }
    }

    private func name(_ text: String, _ palette: Palette) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(palette.primary)
            .lineLimit(1)
    }

    /// The width this title takes, for sizing a table's label column.
    static func width(_ plan: Plan, full: Bool, size: CGFloat, limit: CGFloat) -> CGFloat {
        let extras = size * 0.66 + 5 + (plan.warning != nil ? 5 + size * 0.9 : 0)
        let whole = textWidth(plan.title, size: size, weight: .semibold) + extras
        if full && whole <= limit { return whole }
        return textWidth(plan.short, size: size, weight: .semibold) + extras
    }
}

/// The line a widget shows when its data isn't current. Clicking it reads the dashboard again.
struct FreshnessNote: View {
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

/// Reader problems the dashboard reports, such as "Probe: Claude CLI not found".
struct WarningLines: View {
    var plans: [Plan]
    var lines = 2
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let warnings = plans.compactMap(\.warning)
        if !warnings.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warnings.joined(separator: " · "))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Palette(scheme: scheme).text(.warning))
            .lineLimit(lines)
        }
    }
}

/// No reading yet and none kept.
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

/// Title, the dashboard's host, and the time of the reading, or the freshness note in its place.
struct WidgetHeader: View {
    var entry: UsageEntry
    var title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let host = entry.summary?.host {
                Text(host).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if entry.freshnessNote != nil {
                FreshnessNote(entry: entry).fixedSize().layoutPriority(2)
            } else if let at = entry.fetchedAt ?? entry.summary?.generatedAt {
                Text(at, style: .time).font(.system(size: 10)).foregroundStyle(palette.muted).fixedSize()
            }
        }
    }
}

// MARK: - The limits table (medium, large and extra large)

/// One line of the limits table: a plan, the heading over a plan's model groups, or one group.
struct LimitRow: Identifiable {
    enum Kind { case plan, heading, group }
    var kind: Kind
    var plan: Plan
    var name: String? = nil
    var windows: [LimitWindow] = []
    var id: String { "\(plan.id)|\(kind)|\(name ?? "")" }
}

func limitRows(_ plans: [Plan]) -> [LimitRow] {
    plans.flatMap { plan -> [LimitRow] in
        guard plan.hasGroups else { return [LimitRow(kind: .plan, plan: plan, windows: plan.windows)] }
        return [LimitRow(kind: .heading, plan: plan)]
            + grouped(plan.windows).map { LimitRow(kind: .group, plan: plan, name: $0.group ?? "Other", windows: $0.windows) }
    }
}

/// The window labels across the plans, shortest window first: usually "5-hour" and "Weekly".
func limitColumns(_ plans: [Plan]) -> [String] {
    var labels: [String] = []
    for window in plans.flatMap(\.windows) where !labels.contains(window.label) {
        labels.append(window.label)
    }
    let span = ["5-hour": 0, "Weekly": 1]
    return labels.enumerated()
        .sorted { (span[$0.element] ?? 2, $0.offset) < (span[$1.element] ?? 2, $1.offset) }
        .map { $0.element }
}

/// The plan limits as a table: a row per plan (for Antigravity, a heading and then a row per model
/// group) and a column per window, so every plan's 5-hour and weekly limits line up. The medium widget
/// draws each cell on one line; the large ones add the reset time under a longer bar.
struct LimitsTable: View {
    var plans: [Plan]
    var now: Date
    var width: CGFloat
    var roomy = false
    var fullTitles = false
    @Environment(\.colorScheme) private var scheme

    private var titleSize: CGFloat { roomy ? 12 : 11 }
    private var corner: String { roomy ? "" : "% left · resets in" }

    /// Wide enough for the longest label, so no label is cut and the limit columns share the rest.
    private var labelWidth: CGFloat {
        let limit = width * (fullTitles ? 0.4 : 0.34)
        let indent = titleSize * 0.66 + 5
        let widths = limitRows(plans).map { row -> CGFloat in
            switch row.kind {
            case .group: return indent + textWidth(row.name ?? "", size: titleSize - 1)
            case .plan, .heading: return PlanTitle.width(row.plan, full: fullTitles, size: titleSize, limit: limit)
            }
        }
        return min(limit, (widths + [textWidth(corner, size: 9)]).max() ?? 0) + 2
    }

    var body: some View {
        let palette = Palette(scheme: scheme)
        let columns = limitColumns(plans)
        let labelWidth = self.labelWidth
        Grid(alignment: .leading, horizontalSpacing: roomy ? 12 : 8, verticalSpacing: roomy ? 8 : 7) {
            GridRow {
                Text(corner)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                ForEach(columns, id: \.self) { column in
                    Text(column)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            ForEach(limitRows(plans)) { row in
                GridRow(alignment: .firstTextBaseline) {
                    label(row, palette: palette)
                        .frame(width: labelWidth, alignment: .leading)
                    cells(row, columns: columns, palette: palette)
                }
            }
        }
    }

    /// The row's cells, one per column, or a note across them when the plan has no reading.
    @ViewBuilder
    private func cells(_ row: LimitRow, columns: [String], palette: Palette) -> some View {
        if row.kind == .plan && row.windows.isEmpty {
            Text("No reading yet")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .gridCellColumns(max(1, columns.count))
        } else {
            ForEach(columns, id: \.self) { column in
                cell(row.windows.first { $0.label == column })
            }
        }
    }

    @ViewBuilder
    private func cell(_ window: LimitWindow?) -> some View {
        if let window {
            if roomy {
                StackedCell(window: window, now: now)
            } else {
                InlineCell(window: window, now: now)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func label(_ row: LimitRow, palette: Palette) -> some View {
        if row.kind == .group {
            Text(row.name ?? "")
                .font(.system(size: titleSize - 1))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .padding(.leading, titleSize * 0.66 + 5)
        } else {
            PlanTitle(plan: row.plan, full: fullTitles, size: titleSize)
        }
    }
}

/// A medium table cell on one line: percent left, a bar, and the time to the reset.
struct InlineCell: View {
    var window: LimitWindow
    var now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        HStack(spacing: 4) {
            // Wide enough for "100%", so the bars start in line.
            PercentLeft(window: window, now: now, size: 11)
                .frame(minWidth: 31, alignment: .trailing)
            MeterBar(left: window.leftPct, level: window.status, height: 4)
                .frame(minWidth: 14)
            Text(window.untilReset(now: now))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(window.resetPassed(now: now) ? palette.stale : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 42, alignment: .leading)
        }
    }
}

/// A large table cell: percent left, a bar, then when it resets or how old the reading is.
struct StackedCell: View {
    var window: LimitWindow
    var now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 3) {
            PercentLeft(window: window, now: now, size: 12, left: true)
            MeterBar(left: window.leftPct, level: window.status)
            Text(window.caption(now: now))
                .font(.system(size: 9.5))
                .foregroundStyle(window.isOld(now: now) ? palette.stale : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            PlanTitle(plan: plan, size: 12)
                            Spacer(minLength: 2)
                            PercentLeft(window: window, now: entry.date, size: 12, left: true)
                        }
                        MeterBar(left: window.leftPct, level: window.status)
                        if !note {
                            caption(window, palette: palette)
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        PlanTitle(plan: plan, size: 12)
                        Spacer(minLength: 2)
                        Text("no reading").font(.system(size: 10)).foregroundStyle(palette.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            FreshnessNote(entry: entry)
        }
    }

    /// "Weekly · resets in 2d 1h", shortened to "Gemini weekly · 2d 10h" when that doesn't fit.
    private func caption(_ window: LimitWindow, palette: Palette) -> some View {
        let until = window.untilReset(now: entry.date)
        let resets = window.resetPassed(now: entry.date) ? until : Format.resets(window.resetsAt, now: entry.date)
        return ViewThatFits(in: .horizontal) {
            Text(resets.isEmpty ? window.name : "\(window.name) · \(resets)")
            Text(until.isEmpty ? window.name : "\(window.name) · \(until)")
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(window.isOld(now: entry.date) ? palette.stale : palette.muted)
        .lineLimit(1)
    }
}

struct SinglePlanSmall: View {
    var plan: Plan
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let note = entry.freshnessNote != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                PlanTitle(plan: plan, full: true, size: 12)
                if plan.hasGroups {
                    Spacer(minLength: 4)
                    Text("% left").font(.system(size: 9)).foregroundStyle(palette.muted).fixedSize()
                }
            }
            if plan.windows.isEmpty {
                Text("No limit reading yet.").font(.system(size: 11)).foregroundStyle(palette.muted)
            } else if plan.hasGroups {
                ForEach(grouped(plan.windows)) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.group ?? "Other")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(group.windows.prefix(2)) { window in
                                MiniCell(window: window, now: entry.date, caption: !note)
                            }
                        }
                    }
                }
            } else {
                ForEach(plan.windows.prefix(2)) { window in
                    WindowRow(window: window, now: entry.date, percentSize: 15)
                }
            }
            Spacer(minLength: 0)
            if let warning = plan.warning, !note {
                Text(warning)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.text(.warning))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            FreshnessNote(entry: entry)
        }
    }
}

/// One plan in a medium, large or extra-large widget: its windows two to a row (under each model
/// group's name for Antigravity), then its API-equivalent value.
struct SinglePlanWide: View {
    var plan: Plan
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let medium = family == .systemMedium
        let note = entry.freshnessNote != nil
        let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
        VStack(alignment: .leading, spacing: medium ? 6 : 10) {
            HStack(alignment: .firstTextBaseline) {
                PlanTitle(plan: plan, full: true, size: 13)
                Spacer(minLength: 6)
                if let monthly = plan.monthlyUsd {
                    Text(Format.price(monthly) + "/mo").font(.system(size: 10)).foregroundStyle(palette.muted).fixedSize()
                }
            }
            if plan.windows.isEmpty {
                Text("No limit reading yet.").font(.system(size: 11)).foregroundStyle(palette.muted)
            } else {
                ForEach(grouped(plan.windows)) { group in
                    VStack(alignment: .leading, spacing: medium ? 2 : 4) {
                        if let name = group.group {
                            Text(name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: medium ? 6 : 10) {
                            ForEach(group.windows) { window in
                                WindowRow(window: window, now: entry.date, inline: medium && plan.hasGroups)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            // The medium size has room for the value only beside ungrouped windows, and drops it
            // when a warning and the freshness note both need a line.
            if !medium || (!plan.hasGroups && !(note && plan.warning != nil)) {
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
            if let warning = plan.warning, !(medium && note) {
                Text(warning)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.text(.warning))
                    .lineLimit(1)
            }
            FreshnessNote(entry: entry)
        }
    }
}

/// The plans as a table, a line per limit.
struct AllPlansMedium: View {
    var entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitsTable(plans: entry.plans, now: entry.date, width: PreviewSize.content(.systemMedium).width)
            Spacer(minLength: 6)
            FreshnessNote(entry: entry)
        }
    }
}

/// Large and extra large: the table with reset times, reader problems, then the period's totals.
struct AllPlansLarge: View {
    var entry: UsageEntry
    var family: WidgetFamily

    var body: some View {
        let wide = family == .systemExtraLarge
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                WidgetHeader(entry: entry, title: "AI plan limits")
                LimitsTable(plans: entry.plans, now: entry.date, width: PreviewSize.content(family).width,
                            roomy: true, fullTitles: wide)
                WarningLines(plans: entry.plans, lines: wide ? 1 : 2)
            }
            Spacer(minLength: 8)
            if let summary = entry.summary {
                TotalsSection(summary: summary, compact: !wide)
            }
        }
    }
}

// MARK: - Usage totals

struct Stat: Identifiable {
    var label: String
    /// The label in narrow places: "Requests" for "Model requests".
    var short: String
    var value: String
    var hint: String
    var id: String { label }
}

/// The dashboard's four totals. The hints leave out the period, which every widget shows elsewhere.
func stats(_ summary: UsageSummary) -> [Stat] {
    let t = summary.totals
    return [
        Stat(label: "API-equivalent value", short: "API value", value: Format.usd(t.cost),
             hint: t.unpriced > 0 ? "\(Format.grouped(t.unpriced)) requests unpriced" : "at API prices"),
        Stat(label: "Model requests", short: "Requests", value: Format.grouped(t.requests),
             hint: "\(Format.tokens(t.output)) output tokens"),
        Stat(label: "Tokens processed", short: "Tokens", value: Format.tokens(t.tokens), hint: "\(t.cacheShare)% from cache"),
        Stat(label: "Background jobs", short: "Background jobs", value: Format.usd(t.backgroundCost),
             hint: t.topBackgroundJob.map { "top: \($0.job) (\(Format.usd($0.cost)))" } ?? "none in this period"),
    ]
}

/// The totals under the large limits widget, with the period they cover.
struct TotalsSection: View {
    var summary: UsageSummary
    var compact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(palette.divider)
            Text(summary.rangeLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.muted)
            TotalsRow(summary: summary, compact: compact)
        }
    }
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
                    Text(compact ? stat.short : stat.label)
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
                        HStack(alignment: .firstTextBaseline) {
                            Text(stat.short).foregroundStyle(palette.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(stat.value).fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.primary)
                                .fixedSize()
                        }
                        .font(.system(size: 11))
                    }
                    FreshnessNote(entry: entry)
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

    /// The area inside the widget's 16-point margins.
    static func content(_ family: WidgetFamily) -> CGSize {
        let size = points(family)
        return CGSize(width: size.width - 32, height: size.height - 32)
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
