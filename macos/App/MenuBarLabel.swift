import AppKit
import AIUsageKit
import SwiftUI

struct MenuBarMeter: Equatable {
    let provider: HistoryProvider
    let percent: Int?

    var shortName: String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "GPT"
        case .antigravity: return "Google"
        }
    }

    var detail: String { percent.map { "\($0)% left" } ?? "No current quota" }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.meterProviders.isEmpty {
            MenuBarSymbol(meters: [], sample: false)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 60)) { tick in
                MenuBarSymbol(meters: model.menuBarMeters(at: tick.date), sample: model.source == .demo)
            }
        }
    }
}

/// The mark and every meter share one clickable menu-bar button.
struct MenuBarSymbol: View {
    let meters: [MenuBarMeter]
    let sample: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: Self.image(meters: meters, dark: colorScheme == .dark)).renderingMode(.original)
            .accessibilityLabel(Text(description)).help(description)
    }

    var description: String {
        let parts = meters.map { "\($0.provider.displayName), \($0.detail)" }
        return ([sample ? "AI Usage, sample data" : "AI Usage"] + parts).joined(separator: ". ")
    }

    @MainActor static func image(meters: [MenuBarMeter], dark: Bool) -> NSImage {
        let sage = NSColor(srgbRed: 161/255, green: 173/255, blue: 141/255, alpha: 1)
        let forest = NSColor(srgbRed: 36/255, green: 49/255, blue: 32/255, alpha: 1)
        let ink = dark ? sage : forest
        let trackColor = dark ? forest : sage
        let mark = NSImage(named: dark ? "MenuMarkDark" : "MenuMarkLight")
        let markWidth = mark?.size.width ?? 23
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: ink
        ]
        let widths = meters.map { max(18, ceil(($0.shortName as NSString).size(withAttributes: attrs).width)) }
        let width = widths.reduce(markWidth) { $0 + 4 + $1 }
        let result = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            mark?.draw(in: NSRect(x: 0, y: 0, width: markWidth, height: 18))
            var x = markWidth
            for (meter, span) in zip(meters, widths) {
                x += 4
                (meter.shortName as NSString).draw(at: CGPoint(x: x, y: 5), withAttributes: attrs)
                if let percent = meter.percent {
                    trackColor.setFill()
                    let track = NSRect(x: x, y: 2, width: span, height: 3)
                    NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                    if percent > 0 {
                        ink.setFill()
                        let fill = NSRect(x: x, y: 2, width: max(1, span * CGFloat(percent) / 100), height: 3)
                        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
                    }
                } else {
                    ink.setFill()
                    for dx in stride(from: CGFloat(0), to: span, by: 5) {
                        NSRect(x: x + dx, y: 2.5, width: min(2, span - dx), height: 1.5).fill()
                    }
                }
                x += span
            }
            return true
        }
        return result
    }

}

struct MenuBarSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("Menu Bar").font(.system(size: 27, weight: .bold)).accessibilityAddTraits(.isHeader)
        Toggle("Show AI Usage in the menu bar", isOn: $model.showMenuBarIcon)
        VStack(alignment: .leading, spacing: 12) {
            Text("Quota meters").font(.headline)
            Text("Choose which meters appear beside the gauge. Each shows the lowest remaining limit for that provider. A dashed line means there’s no current reading.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(HistoryProvider.allCases, id: \.self) { provider in
                HStack {
                    Toggle(provider.displayName, isOn: Binding(
                        get: { model.meterProviders.contains(provider) },
                        set: { model.setMeter(provider, enabled: $0) }))
                        .accessibilityIdentifier("menu-meter-" + provider.rawValue)
                    Spacer()
                    Text(MenuBarMeter(provider: provider, percent: model.limits?.menuBarQuota(for: provider, at: Date())).detail)
                        .foregroundStyle(.secondary).font(.callout)
                }
                if provider != .antigravity { Divider() }
            }
        }.disabled(!model.showMenuBarIcon)
        if model.showMenuBarIcon {
            HStack(spacing: 12) {
                Text(model.source == .demo ? "Menu bar preview · Sample data" : "Menu bar preview").font(.callout)
                MenuBarLabel(model: model)
            }
            Text("Click the gauge in your menu bar to see each limit and its reset time.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
