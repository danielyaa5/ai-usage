import AppKit
import AIUsageKit
import SwiftUI

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

/// The same clickable button shows either the app mark or the enabled meters.
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

    private static func nsColor(_ rgb: MenuBarMeter.RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    @MainActor static func image(meters: [MenuBarMeter], dark: Bool) -> NSImage {
        if meters.isEmpty {
            let mark = NSImage(named: dark ? "MenuMarkDark" : "MenuMarkLight")
            return mark ?? NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "AI Usage")!
        }
        let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let meterWidth: CGFloat = 40
        let spacing: CGFloat = 4
        let width = meterWidth * CGFloat(meters.count) + spacing * CGFloat(meters.count - 1)
        let result = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            var x: CGFloat = 0
            for meter in meters {
                let palette = meter.colors(dark: dark)
                let ink = Self.nsColor(palette.ink)
                let trackColor = Self.nsColor(palette.track)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink
                ]
                let label = meter.shortName as NSString
                let labelX = x + (meterWidth - label.size(withAttributes: attrs).width) / 2
                label.draw(at: CGPoint(x: labelX, y: 5), withAttributes: attrs)
                if let remaining = meter.remainingPct {
                    trackColor.setFill()
                    let track = NSRect(x: x, y: 2, width: meterWidth, height: 3)
                    NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                    let clamped = min(100, max(0, remaining))
                    if clamped > 0 {
                        ink.setFill()
                        let fill = NSRect(x: x, y: 2, width: max(1, meterWidth * CGFloat(clamped) / 100), height: 3)
                        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
                    }
                } else {
                    ink.setFill()
                    let dashCount = 7
                    let dashWidth: CGFloat = 2
                    let step = (meterWidth - dashWidth) / CGFloat(dashCount - 1)
                    for index in 0..<dashCount {
                        NSRect(x: x + CGFloat(index) * step, y: 2.5, width: dashWidth, height: 1.5).fill()
                    }
                }
                x += meterWidth + spacing
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
            Text("Choose the meters to show in place of the AI icon. Claude uses All models, Codex / ChatGPT uses its lowest current limit, and Google uses Gemini’s weekly limit. A dashed line means there’s no current reading.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(HistoryProvider.allCases, id: \.self) { provider in
                HStack {
                    Toggle(provider.displayName, isOn: Binding(
                        get: { model.meterProviders.contains(provider) },
                        set: { model.setMeter(provider, enabled: $0) }))
                        .accessibilityIdentifier("menu-meter-" + provider.rawValue)
                    Spacer()
                    let meter = model.limits?.menuBarMeter(for: provider, at: Date())
                        ?? MenuBarMeter(provider: provider, remainingPct: nil)
                    Text(meter.detail)
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
            Text(model.meterProviders.isEmpty ? "Click the AI icon to see your limits and reset times." : "Click the meters to see your limits and reset times.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
