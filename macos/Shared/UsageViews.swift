import AppIntents
import AppKit
import SwiftUI
import WidgetKit
import AIUsageKit

// The widget layouts. The app draws the same views for its previews and its menu bar panel, so each
// takes its size as a parameter instead of reading it from the widget environment.
//
// They are planned for macOS's widget content areas (16-point margins): small 138×138, medium 332×138,
// large 332×350, extra large 717×350. Percentages are never cut short. Where text could run out of
// room, the layouts measure it and pick a shorter form, the same one for every row, or offer leaner
// versions of themselves to a ViewThatFits. A reading that is out of date is drawn in gray with a faded
// bar, and its time is given in amber where there is room for it. Table cells get fixed slots, so the
// bars line up whatever the numbers are.

// MARK: - Building blocks

/// A percent-left bar. Its outline keeps the shape readable when the desktop draws widgets without
/// color (vibrant, behind other windows, and accented modes).
struct MeterBar: View {
    var left: Double
    var level: Level
    var height: CGFloat = 5
    /// Faded, for a reading that is out of date.
    var dim = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let fraction = max(0, min(1, left / 100))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule().fill(palette.fill(level).opacity(dim ? (palette.dark ? 0.55 : 0.45) : 1))
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

/// "72%", or "72% left", in the level's color, or gray when the reading is old or the window has reset
/// since (the line under it, or a line at the bottom of the widget, says how old). `icons` adds the
/// level's icon in front of a low, current reading; narrow layouts leave it out. Always drawn whole:
/// the views beside it give way.
struct PercentLeft: View {
    var window: LimitWindow
    var now: Date
    var size: CGFloat = 12
    var left = false
    var icons = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let status = window.status
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if icons && status != .good && !window.isOld(now: now) {
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.text(status))
            }
            Self.text(window, now: now, size: size, left: left, palette: palette)
        }
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }

    /// The percentage, and " left" when `left`, in its color.
    static func text(_ window: LimitWindow, now: Date, size: CGFloat, left: Bool, palette: Palette) -> Text {
        let status = window.status
        let color = window.isOld(now: now) ? palette.muted : status == .good ? palette.primary : palette.text(status)
        let percent = Text(Format.percent(window.leftPct))
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
        guard left else { return percent }
        return percent + Text(" left").font(.system(size: size * 0.8)).foregroundStyle(palette.muted)
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
        captions(now: now).first ?? ""
    }

    /// The same, longest first, for a layout to take the first that fits.
    func captions(now: Date) -> [String] {
        let ago = Format.ago(observedAt, now: now)
        if manuallyEntered == true { return ["entered \(ago)", "entered"] }
        if resetPassed(now: now) { return ["reset due · as of \(ago)", "reset due · \(ago)", "reset due"] }
        if isStale(now: now) || (resetsAt == nil && observedAt != nil) { return ["as of \(ago)", ago] }
        return [Format.resets(resetsAt, now: now)] + (Format.remaining(until: resetsAt, now: now).map { [$0] } ?? [])
    }

    /// The short form for table cells: "2h 15m" to the reset, "reset due", or nothing.
    func untilReset(now: Date) -> String {
        if resetPassed(now: now) { return "reset due" }
        if manuallyEntered == true { return "entered" }
        if resetsAt == nil, observedAt != nil { return Format.ago(observedAt, now: now) }
        return Format.remaining(until: resetsAt, now: now) ?? ""
    }
}

extension Plan {
    /// Whether the plan's windows come in model groups, as Antigravity's do.
    var hasGroups: Bool { windows.contains { $0.groupShort != nil } }

    /// The window with the least left among those that haven't reset since their reading, so a window
    /// that is over doesn't stand for the plan.
    func firstToRunOut(now: Date) -> LimitWindow? {
        windows.filter { !$0.resetPassed(now: now) }.min { $0.leftPct < $1.leftPct } ?? tightest
    }
}

extension String {
    /// "App not running" from "app not running".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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

/// The width of a line of text in the system font, for sizing columns and choosing between long and
/// short forms. `digits` measures the even-width digits that `monospacedDigit()` draws.
func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, digits: Bool = false) -> CGFloat {
    let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
}

/// The width of an SF Symbol as `Image(systemName:)` draws it in a font of `size` points.
func symbolWidth(_ name: String, size: CGFloat) -> CGFloat {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular, scale: .medium)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return ceil(size * 1.3) }
    return ceil(image.size.width)
}

/// The width PercentLeft takes without icons: "100%", or "100% left".
func percentWidth(_ text: String = "100%", size: CGFloat, left: Bool) -> CGFloat {
    textWidth(text, size: size, weight: .semibold, digits: true) + (left ? textWidth(" left", size: size * 0.8) : 0)
}

/// A table cell's percent slot: "100%" with a little to spare.
func percentSlot(size: CGFloat) -> CGFloat {
    percentWidth(size: size, left: false) + 2
}

/// Room for the longest time to a reset among `windows` ("15h 58m", "reset due"), so every cell of a
/// table gets the same slot and the bars line up.
func untilSlot(_ windows: [LimitWindow], now: Date, size: CGFloat = 9.5) -> CGFloat {
    let widest = windows.map { textWidth($0.untilReset(now: now), size: size, digits: true) }.max() ?? 0
    return min(50, max(30, widest + 1))
}

/// Which plans' limit readings are more than six hours old, for the medium widget's last line; nil
/// when none are.
func staleLimitsText(_ plans: [Plan], now: Date, width: CGFloat) -> String? {
    let stale = plans.compactMap { plan -> (name: String, ago: String)? in
        guard let at = plan.oldestStaleReading(now: now) else { return nil }
        return (plan.short, Format.ago(at, now: now))
    }
    guard let first = stale.first else { return nil }
    if stale.count == 1 { return "\(first.name) limits as of \(first.ago)" }
    let long = stale.map { "\($0.name) as of \($0.ago)" }.joined(separator: " · ")
    if textWidth(long, size: 9.5, weight: .medium) <= width - 16 { return long }
    return "Old limit readings: " + stale.map { $0.name }.joined(separator: ", ")
}

/// Label, percent left, bar and the line under it: when it resets, or how old the reading is. `inline`
/// puts the time to the reset after the label instead, which saves a line in the medium widget, and
/// `caption: false` leaves the line out.
struct WindowRow: View {
    var window: LimitWindow
    var now: Date
    var percentSize: CGFloat = 13
    var inline = false
    var caption = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let until = window.untilReset(now: now)
        let old = window.isOld(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if inline && !until.isEmpty {
                    Text("· \(until)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(old ? palette.stale : palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 2)
                PercentLeft(window: window, now: now, size: percentSize, left: true, icons: !inline)
            }
            MeterBar(left: window.leftPct, level: window.status, dim: old)
            if caption && !inline {
                CaptionText(window: window, now: now)
            }
        }
    }
}

/// The line under a bar in the longest form that fits, at the same size as its neighbours: "reset due ·
/// as of 3 d ago", then "reset due · 3 d ago", then "reset due"; "resets in 2d 1h", then "2d 1h".
struct CaptionText: View {
    var window: LimitWindow
    var now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        ViewThatFits(in: .horizontal) {
            ForEach(window.captions(now: now), id: \.self) { text in
                Text(text).lineLimit(1)
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(window.isOld(now: now) ? palette.stale : palette.muted)
    }
}

/// The plan's swatch and name. `full` uses the whole title ("Claude Max 20x") when it fits and the
/// short name ("Antigravity") when it doesn't. `warningIcon` adds a triangle when the plan's reader
/// reports a problem; layouts that spell the problem out under the plan leave it off.
struct PlanTitle: View {
    var plan: Plan
    var full = false
    var size: CGFloat = 12
    var warningIcon = true
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
            if warningIcon && plan.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(palette.text(.warning))
                    .help(plan.warning ?? "")
            }
        }
    }

    private func name(_ text: String, _ palette: Palette) -> some View {
        // No scale factor: beside a spacer, SwiftUI would shrink the name even with room to spare.
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(palette.primary)
            .lineLimit(1)
    }

    /// The width this title takes, for sizing a table's label column and choosing a title size.
    static func width(_ plan: Plan, full: Bool = false, size: CGFloat, limit: CGFloat = .infinity,
                      warningIcon: Bool = true) -> CGFloat {
        let icon = warningIcon && plan.warning != nil
            ? 5 + symbolWidth("exclamationmark.triangle.fill", size: size * 0.75) : 0
        let extras = size * 0.66 + 5 + icon
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
            if entry.server == SharedStore.localURL {
                Link(destination: AppLink.refresh.url) { label(note) }
                    .help("Open AI Usage and refresh local history")
            } else {
                Button(intent: RefreshUsageIntent()) { label(note) }
                    .buttonStyle(.plain)
                    .help(entry.error ?? "Refresh the dashboard")
            }
        }
    }

    private func label(_ note: String) -> some View {
        Label(note, systemImage: entry.error == nil ? "arrow.clockwise" : "wifi.exclamationmark")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Palette(scheme: scheme).stale)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Reader problems the dashboard reports across plans: the full errors when they fit in `lines` lines
/// of `width`, else each plan's in a few words ("Claude: CLI not found"), else which plans have one.
struct WarningLines: View {
    var plans: [Plan]
    var width: CGFloat
    var lines = 2
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let text = Self.text(plans, width: width, lines: lines) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(text)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Palette(scheme: scheme).text(.warning))
            .lineLimit(lines)
        }
    }

    static func text(_ plans: [Plan], width: CGFloat, lines: Int) -> String? {
        let warned = plans.filter { $0.warning != nil }
        guard !warned.isEmpty else { return nil }
        // Wrapped lines don't fill to the edge, so a second line counts for less.
        let room = (width - 16) * (lines > 1 ? CGFloat(lines) * 0.85 : 1)
        let full = warned.compactMap { $0.warning }.joined(separator: " · ")
        if textWidth(full, size: 9.5) <= room { return full }
        let short = warned.map { "\($0.short): \($0.warningPhrase ?? "")" }.joined(separator: " · ")
        if textWidth(short, size: 9.5) <= room { return short }
        return "Problems reading limits: " + warned.map { $0.short }.joined(separator: ", ")
    }
}

/// One plan's reader problem. With `oneLine` it takes a line of that width, in a few words when the
/// whole error doesn't fit; without, it wraps the whole error onto as many lines as `maxLines` allows
/// (nil: all it needs).
struct WarningText: View {
    var plan: Plan
    var oneLine: CGFloat? = nil
    var maxLines: Int? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let warning = plan.warning {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                if let width = oneLine {
                    Text(textWidth(warning, size: 9.5, weight: .medium) <= width - 16
                         ? warning : (plan.warningPhrase ?? warning).capitalizedFirst)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text(warning)
                        .lineLimit(maxLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Palette(scheme: scheme).text(.warning))
        }
    }
}

/// How old limit readings are ("Limits as of 7 h ago"), in layouts without a line under each window.
struct AgeLine: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "clock")
            Text(text)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Palette(scheme: scheme).stale)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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
            Text(entry.server == SharedStore.localURL ? "Connect a source" : "Can't reach AI Usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(entry.server == SharedStore.localURL ? "This Mac" : hostAndPort(entry.server))
                .font(.system(size: 10).monospaced())
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(entry.server == SharedStore.localURL ? "Open AI Usage to connect your account or usage history." : "Click to check the dashboard address in AI Usage.")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if entry.server != SharedStore.localURL { Button(intent: RefreshUsageIntent()) {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small) }
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
    /// Space between rows; nil for the usual.
    var rowSpacing: CGFloat? = nil
    /// The row of column names ("5-hour", "Weekly"); a tight layout can do without it.
    var heading = true
    @Environment(\.colorScheme) private var scheme

    private var titleSize: CGFloat { roomy ? 12 : 11 }
    private var corner: String {
        guard !roomy else { return "" }
        let windows = plans.flatMap(\.windows)
        if windows.contains(where: { $0.resetsAt == nil }) {
            return windows.allSatisfy { $0.resetsAt == nil } ? "% left · last read" : "% left"
        }
        return "% left · resets in"
    }

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
        return min(limit, (widths + [heading ? textWidth(corner, size: 9) : 0]).max() ?? 0) + 2
    }

    var body: some View {
        let palette = Palette(scheme: scheme)
        let columns = limitColumns(plans)
        let labelWidth = self.labelWidth
        let untilWidth = untilSlot(plans.flatMap(\.windows), now: now)
        Grid(alignment: .leading, horizontalSpacing: roomy ? 12 : 8, verticalSpacing: rowSpacing ?? (roomy ? 8 : 7)) {
            if heading {
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
            }
            ForEach(limitRows(plans)) { row in
                GridRow(alignment: .firstTextBaseline) {
                    label(row, palette: palette)
                        .frame(width: labelWidth, alignment: .leading)
                    cells(row, columns: columns, untilWidth: untilWidth, palette: palette)
                }
            }
        }
    }

    /// The row's cells, one per column, or a note across them when the plan has no reading.
    @ViewBuilder
    private func cells(_ row: LimitRow, columns: [String], untilWidth: CGFloat, palette: Palette) -> some View {
        if row.kind == .plan && row.windows.isEmpty {
            Text("No reading yet")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .gridCellColumns(max(1, columns.count))
        } else {
            ForEach(columns, id: \.self) { column in
                cell(row.windows.first { $0.label == column }, untilWidth: untilWidth)
            }
        }
    }

    @ViewBuilder
    private func cell(_ window: LimitWindow?, untilWidth: CGFloat) -> some View {
        if let window {
            if roomy {
                StackedCell(window: window, now: now)
            } else {
                InlineCell(window: window, now: now, percentWidth: percentSlot(size: 11), untilWidth: untilWidth)
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

/// A table cell on one line: percent left, a bar, and the time to the reset. The percent and the time
/// get fixed slots, the same in every cell of a table (`percentSlot(size:)` and `untilSlot`), so the
/// bars line up and nothing spills into the next column.
struct InlineCell: View {
    var window: LimitWindow
    var now: Date
    var size: CGFloat = 11
    var percentWidth: CGFloat
    var untilWidth: CGFloat = 42
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        let old = window.isOld(now: now)
        HStack(spacing: 4) {
            PercentLeft.text(window, now: now, size: size, left: false, palette: palette)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: percentWidth, alignment: .trailing)
            MeterBar(left: window.leftPct, level: window.status, height: 4, dim: old)
                .frame(minWidth: 14)
            Text(window.untilReset(now: now))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(old ? palette.stale : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: untilWidth, alignment: .leading)
        }
    }
}

/// A large table cell: percent left, a bar, then when it resets or how old the reading is.
struct StackedCell: View {
    var window: LimitWindow
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            PercentLeft(window: window, now: now, size: 12, left: true)
            MeterBar(left: window.leftPct, level: window.status, dim: window.isOld(now: now))
            CaptionText(window: window, now: now)
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

/// Each plan's tightest window: what runs out first. Under each bar, the reader's problem, or how old
/// the reading is, or when the window resets.
struct AllPlansSmall: View {
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    @Environment(\.widgetContentSize) private var measured
    private var width: CGFloat { measured?.width ?? PreviewSize.content(.systemSmall).width }

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(captions: true)
            layout(captions: false)
        }
    }

    private func layout(captions: Bool) -> some View {
        let palette = Palette(scheme: scheme)
        let note = entry.freshnessNote != nil
        let fit = titleFit(warningIcon: !captions)
        let long = longCaptions()
        return VStack(alignment: .leading, spacing: note ? 4 : 6) {
            ForEach(entry.plans) { plan in
                row(plan, captions: captions, titleSize: fit.size, left: fit.left.contains(plan.id), long: long,
                    palette: palette)
            }
            Spacer(minLength: 0)
            if note {
                FreshnessNote(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func row(_ plan: Plan, captions: Bool, titleSize: CGFloat, left: Bool, long: Bool,
                     palette: Palette) -> some View {
        if let window = plan.firstToRunOut(now: entry.date) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    PlanTitle(plan: plan, size: titleSize, warningIcon: !captions)
                    Spacer(minLength: Self.gap)
                    PercentLeft(window: window, now: entry.date, size: 12, left: left, icons: false)
                }
                MeterBar(left: window.leftPct, level: window.status, dim: window.isOld(now: entry.date))
                if captions {
                    caption(plan, window, long: long, palette: palette)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                PlanTitle(plan: plan, size: titleSize)
                Spacer(minLength: Self.gap)
                Text(entry.server == SharedStore.localURL && plan.requests > 0 ? "\(plan.requests.formatted()) req" : "no reading").font(.system(size: 10)).foregroundStyle(palette.muted)
            }
        }
    }

    @ViewBuilder
    private func caption(_ plan: Plan, _ window: LimitWindow, long: Bool, palette: Palette) -> some View {
        if let phrase = plan.warningPhrase {
            iconLine("exclamationmark.triangle.fill", phrase.capitalizedFirst, color: palette.text(.warning))
        } else if window.isOld(now: entry.date) {
            iconLine("clock", "\(window.name) · \(oldNote(window))", color: palette.stale)
        } else {
            Text(plainCaption(window, long: long))
                .font(.system(size: 9.5))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
    }

    private func iconLine(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    /// "reset due", or how old the reading is: "7 h ago".
    private func oldNote(_ window: LimitWindow) -> String {
        window.resetPassed(now: entry.date) ? "reset due" : Format.ago(window.observedAt, now: entry.date)
    }

    private func plainCaption(_ window: LimitWindow, long: Bool) -> String {
        if window.manuallyEntered == true { return "\(window.name) · entered" }
        guard let left = Format.remaining(until: window.resetsAt, now: entry.date) else {
            return window.resetsAt == nil && window.observedAt != nil ?
                "\(window.name) · \(Format.ago(window.observedAt, now: entry.date))" : window.name
        }
        return long ? "\(window.name) · resets in \(left)" : "\(window.name) · \(left)"
    }

    /// "Weekly · resets in 2d 1h" when every plan's line fits that way, else "Weekly · 2d 1h" on all.
    private func longCaptions() -> Bool {
        entry.plans.allSatisfy { plan in
            guard let window = plan.firstToRunOut(now: entry.date), plan.warning == nil, !window.isOld(now: entry.date) else {
                return true
            }
            return textWidth(plainCaption(window, long: true), size: 9.5) <= width
        }
    }

    /// The least room between a plan's name and its percent.
    private static let gap: CGFloat = 6

    /// One title size for every row, and the rows with room for " left" after their percents.
    private struct TitleFit {
        var size: CGFloat
        var left: Set<Plan.ID>
    }

    /// Every title at 12 points with " left" after each percent when all of them fit, else at 11. When
    /// even 11 is too wide (a long name beside "100%", or a problem's triangle beside "Antigravity"),
    /// the largest size at which every row fits without " left" (12, 11 or 10 points), with " left" on
    /// the rows that still have room. Each row is measured with the percent it shows.
    private func titleFit(warningIcon: Bool) -> TitleFit {
        func fits(_ plan: Plan, size: CGFloat, left: Bool) -> Bool {
            guard let window = plan.firstToRunOut(now: entry.date) else {
                // A plan with no reading shows its problem's triangle: it has no caption to say what's wrong.
                return PlanTitle.width(plan, size: size) + Self.gap + textWidth("no reading", size: 10) <= width
            }
            let percent = percentWidth(Format.percent(window.leftPct), size: 12, left: left)
            return PlanTitle.width(plan, size: size, warningIcon: warningIcon) + Self.gap + percent <= width
        }
        let every = Set(entry.plans.map(\.id))
        for size: CGFloat in [12, 11] where entry.plans.allSatisfy({ fits($0, size: size, left: true) }) {
            return TitleFit(size: size, left: every)
        }
        for size: CGFloat in [12, 11, 10] where entry.plans.allSatisfy({ fits($0, size: size, left: false) }) {
            return TitleFit(size: size, left: Set(entry.plans.filter { fits($0, size: size, left: true) }.map(\.id)))
        }
        return TitleFit(size: 10, left: [])
    }
}

/// One plan in the small size: Antigravity's windows a line each under their model group, the other
/// plans' a bar each with the reset time under it. Then the reader's problem, how old the readings are
/// and the offline note; when they don't all fit, the reset times go first, then the error is
/// shortened, then the lines go in the order age, problem, note.
struct SinglePlanSmall: View {
    var plan: Plan
    var entry: UsageEntry
    @Environment(\.colorScheme) private var scheme

    private enum Bottom { case note, warning, age }

    @Environment(\.widgetContentSize) private var measured
    private var width: CGFloat { measured?.width ?? PreviewSize.content(.systemSmall).width }

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(captions: true, fullWarning: true, lines: 3)
            layout(captions: true, fullWarning: false, lines: 3)
            layout(captions: false, fullWarning: true, lines: 3)
            layout(captions: false, fullWarning: false, lines: 3)
            layout(captions: false, fullWarning: false, lines: 2)
            layout(captions: false, fullWarning: false, lines: 1)
        }
    }

    private func layout(captions: Bool, fullWarning: Bool, lines: Int) -> some View {
        let palette = Palette(scheme: scheme)
        // Rows without a line under them leave the readings' age to a line at the bottom.
        let age = plan.hasGroups || !captions ? plan.oldestStaleReading(now: entry.date) : nil
        let wanted: [Bottom?] = [entry.freshnessNote != nil ? Bottom.note : nil,
                                 plan.warning != nil ? Bottom.warning : nil,
                                 age != nil ? Bottom.age : nil]
        let kept = Array(wanted.compactMap { $0 }.prefix(lines))
        return VStack(alignment: .leading, spacing: 0) {
            header(palette)
            windows(captions: captions, palette: palette)
                .padding(.top, plan.hasGroups ? 4 : 5)
            Spacer(minLength: 3)
            VStack(alignment: .leading, spacing: 2) {
                if kept.contains(.warning) {
                    WarningText(plan: plan, oneLine: fullWarning ? nil : width)
                }
                if kept.contains(.age), let age {
                    AgeLine(text: "Limits as of \(Format.ago(age, now: entry.date))")
                }
                if kept.contains(.note) {
                    FreshnessNote(entry: entry)
                }
            }
        }
    }

    private func header(_ palette: Palette) -> some View {
        // "% left" over the percents, when it fits beside the name and a problem's triangle (the
        // spacing around the spacer takes 12).
        let label = plan.hasGroups && PlanTitle.width(plan, size: 12) + 12 + textWidth("% left", size: 9) <= width
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            PlanTitle(plan: plan, full: true, size: 12)
            if label {
                Spacer(minLength: 4)
                Text("% left").font(.system(size: 9)).foregroundStyle(palette.muted).fixedSize()
            }
        }
    }

    @ViewBuilder
    private func windows(captions: Bool, palette: Palette) -> some View {
        if plan.windows.isEmpty {
            Text(entry.missingLimits(for: plan)).font(.system(size: 11)).foregroundStyle(palette.muted)
        } else if plan.hasGroups {
            let labelWidth = (plan.windows.map { textWidth($0.shortLabel, size: 9.5) }.max() ?? 0) + 2
            let percentWidth = percentSlot(size: 10.5)
            let untilWidth = untilSlot(plan.windows, now: entry.date)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(grouped(plan.windows)) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.group ?? "Other")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group.windows) { window in
                                HStack(spacing: 4) {
                                    Text(window.shortLabel)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(palette.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                        .frame(width: labelWidth, alignment: .leading)
                                    InlineCell(window: window, now: entry.date, size: 10.5, percentWidth: percentWidth,
                                               untilWidth: untilWidth)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.windows.prefix(2)) { window in
                    WindowRow(window: window, now: entry.date, percentSize: 15, caption: captions)
                }
            }
        }
    }
}

/// One plan in a medium, large or extra-large widget: its windows two to a row (under each model
/// group's name for Antigravity), then its API-equivalent value, the reader's problem and the
/// offline note, as many of them as the size has room for.
struct SinglePlanWide: View {
    var plan: Plan
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetContentSize) private var measured

    var body: some View {
        let palette = Palette(scheme: scheme)
        let medium = family == .systemMedium
        let note = entry.freshnessNote != nil
        let width = measured?.width ?? PreviewSize.content(family).width
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
                Text(entry.missingLimits(for: plan)).font(.system(size: 11)).foregroundStyle(palette.muted)
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
            if medium && plan.hasGroups {
                // One line fits under the model groups: the offline note, else the reader's problem,
                // else how old the readings are (the rows have no line of their own for it).
                if note {
                    FreshnessNote(entry: entry)
                } else if plan.warning != nil {
                    WarningText(plan: plan, oneLine: width)
                } else if let age = plan.oldestStaleReading(now: entry.date) {
                    AgeLine(text: "Limits as of \(Format.ago(age, now: entry.date))")
                }
            } else {
                // The medium size drops the value when a warning and the freshness note both need a line.
                if entry.summary?.hasHistory != false, !medium || !(note && plan.warning != nil) {
                    value(palette)
                }
                if plan.warning != nil, !(medium && note) {
                    WarningText(plan: plan, oneLine: medium ? width : nil, maxLines: 2)
                }
                if note {
                    FreshnessNote(entry: entry)
                }
            }
        }
    }

    private func value(_ palette: Palette) -> some View {
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
}

/// The plans as a table, a line per limit, and one line under it: the offline note, else the readers'
/// problems, else which readings are old.
struct AllPlansMedium: View {
    var entry: UsageEntry
    @Environment(\.widgetContentSize) private var measured

    var body: some View {
        // Five rows (Antigravity's model groups) and the line under them only just fit a Mac's medium
        // widget: then the rows close up, then the column names go, and the line under them last.
        ViewThatFits(in: .vertical) {
            layout(rowSpacing: nil, heading: true, line: true)
            layout(rowSpacing: 4, heading: true, line: true)
            layout(rowSpacing: 4, heading: false, line: true)
            layout(rowSpacing: 4, heading: false, line: false)
        }
    }

    private func layout(rowSpacing: CGFloat?, heading: Bool, line: Bool) -> some View {
        let width = measured?.width ?? PreviewSize.content(.systemMedium).width
        return VStack(alignment: .leading, spacing: 0) {
            LimitsTable(plans: entry.plans, now: entry.date, width: width, rowSpacing: rowSpacing, heading: heading)
            Spacer(minLength: line ? 6 : 0)
            if !line {
                EmptyView()
            } else if entry.freshnessNote != nil {
                FreshnessNote(entry: entry)
            } else if entry.plans.contains(where: { $0.warning != nil }) {
                WarningLines(plans: entry.plans, width: width, lines: 1)
            } else if let text = staleLimitsText(entry.plans, now: entry.date, width: width) {
                AgeLine(text: text)
            }
        }
    }
}

/// Large and extra large: the table with reset times, reader problems, then the period's totals.
struct AllPlansLarge: View {
    var entry: UsageEntry
    var family: WidgetFamily
    @Environment(\.widgetContentSize) private var measured

    var body: some View {
        // A Mac's large widget has about 308 points of height inside its margins, which the table with
        // reset times, two lines of reader problems and the totals can overrun. Then the problems take
        // one line, the extra large's totals lose their hints, then the totals go (the totals widget has
        // them), then the reset times.
        ViewThatFits(in: .vertical) {
            if family == .systemExtraLarge {
                layout(warningLines: 1, totals: .full, captions: true)
            } else {
                layout(warningLines: 2, totals: .compact, captions: true)
            }
            layout(warningLines: 1, totals: .compact, captions: true)
            layout(warningLines: 1, totals: nil, captions: true)
            layout(warningLines: 1, totals: nil, captions: false)
        }
    }

    private enum Totals { case full, compact }

    private func layout(warningLines: Int, totals: Totals?, captions: Bool) -> some View {
        let wide = family == .systemExtraLarge
        let width = measured?.width ?? PreviewSize.content(family).width
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                WidgetHeader(entry: entry, title: "AI plan limits")
                LimitsTable(plans: entry.plans, now: entry.date, width: width,
                            roomy: captions, fullTitles: wide)
                WarningLines(plans: entry.plans, width: width, lines: warningLines)
            }
            Spacer(minLength: 8)
            if let totals, let summary = entry.summary, summary.hasHistory != false {
                TotalsSection(summary: summary, compact: totals == .compact)
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
    var result = [
        Stat(label: "API-equivalent value", short: "API value", value: Format.usd(t.cost),
             hint: t.unpriced > 0 ? "\(Format.grouped(t.unpriced)) requests unpriced" : "at API prices"),
        Stat(label: "Model requests", short: "Requests", value: Format.grouped(t.requests),
             hint: "\(Format.tokens(t.output)) output tokens"),
        Stat(label: "Tokens processed", short: "Tokens", value: Format.tokens(t.tokens), hint: "\(t.cacheShare)% from cache"),
        Stat(label: "Background jobs", short: "Background", value: Format.usd(t.backgroundCost),
             hint: t.topBackgroundJob.map { "top: \($0.job) (\(Format.usd($0.cost)))" } ?? "none in this period"),
    ]
    if summary.hasHistory != nil {
        result[3] = Stat(label: "Output tokens", short: "Output", value: Format.tokens(t.output), hint: "generated tokens")
    }
    return result
}

/// A total's name: the full one where it fits on a line, else the short one ("Requests").
struct StatLabel: View {
    var stat: Stat
    var short = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !short {
                Text(stat.label).lineLimit(1)
            }
            Text(stat.short).lineLimit(1)
        }
    }
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
                    StatLabel(stat: stat, short: compact)
                        .font(.system(size: 9)).foregroundStyle(palette.muted)
                    Text(stat.value)
                        .font(.system(size: compact ? 14 : 17, weight: .bold)).monospacedDigit()
                        .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.7)
                    if !compact {
                        Text(stat.hint).font(.system(size: 9)).foregroundStyle(palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
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
        if entry.summary?.hasHistory == false {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "folder")
                if entry.server == SharedStore.localURL || entry.server == SharedStore.demoURL {
                    Text("Connect usage history").font(.headline)
                    Text("Choose a tool’s folder in AI Usage to see requests and tokens.").font(.caption)
                } else {
                    Text("Quota only").font(.headline)
                    Text("Choose This Mac in AI Usage to see recorded requests and tokens.").font(.caption)
                }
            }
        } else if let summary = entry.summary {
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
                    if entry.freshnessNote != nil {
                        FreshnessNote(entry: entry).padding(.top, 3)
                    }
                }
            } else {
                // The hints under the numbers go first when a Mac's medium widget is too short for them.
                ViewThatFits(in: .vertical) {
                    grid(summary, all, hints: true, palette: palette)
                    grid(summary, all, hints: false, palette: palette)
                }
            }
        } else {
            UnavailableView(entry: entry)
        }
    }

    private func grid(_ summary: UsageSummary, _ all: [Stat], hints: Bool, palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(entry: entry, title: summary.rangeLabel)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      alignment: .leading, spacing: 8) {
                ForEach(all) { stat in
                    VStack(alignment: .leading, spacing: 1) {
                        StatLabel(stat: stat).font(.system(size: 9.5)).foregroundStyle(palette.muted)
                        Text(stat.value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                            .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.6)
                        if hints {
                            Text(stat.hint).font(.system(size: 9)).foregroundStyle(palette.muted)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Measured size

private struct WidgetContentSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// The space inside the widget's margins, as measured where it is drawn. The layouts measure their
    /// text against this width, because macOS widgets come in other sizes than the ones in
    /// PreviewSize (a large widget was about 25 points narrower on a MacBook Air).
    var widgetContentSize: CGSize? {
        get { self[WidgetContentSizeKey.self] }
        set { self[WidgetContentSizeKey.self] = newValue }
    }
}

/// Hands the measured size to the layouts and centers them, as WidgetKit does.
struct MeasuredWidget<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            content
                .environment(\.widgetContentSize, proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Previews outside WidgetKit (the app's window and image renders)

/// The sizes macOS gave the widgets on a MacBook Air (Nov 2026, from chronod's log), smaller than the
/// iPhone sizes: a large widget is 344 points square, not 364 by 382. Other Macs can differ, which is
/// why placed widgets measure their space (MeasuredWidget); these keep the renders honest.
enum PreviewSize {
    static func points(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: return CGSize(width: 164, height: 164)
        case .systemMedium: return CGSize(width: 344, height: 164)
        case .systemLarge: return CGSize(width: 344, height: 344)
        case .systemExtraLarge: return CGSize(width: 704, height: 344)
        default: return CGSize(width: 164, height: 164)
        }
    }

    /// The desktop widget's margin on that Mac, measured from a screenshot (about 17.8 points).
    static let margin: CGFloat = 18
    static let cornerRadius: CGFloat = 28

    /// The area inside the margins.
    static func content(_ family: WidgetFamily) -> CGSize {
        let size = points(family)
        return CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
    }
}

/// A widget-shaped card with the widget's default margins, for previews in the app and renders.
struct WidgetCard<Content: View>: View {
    var family: WidgetFamily
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = PreviewSize.points(family)
        let corner = RoundedRectangle(cornerRadius: PreviewSize.cornerRadius, style: .continuous)
        MeasuredWidget { content }
            .padding(PreviewSize.margin)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Palette(scheme: scheme).background)
            .clipShape(corner)
            .overlay(corner.strokeBorder(Color.primary.opacity(0.08)))
    }
}
