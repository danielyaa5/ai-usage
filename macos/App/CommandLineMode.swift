import AppKit
import SwiftUI
import WidgetKit
import AIUsageKit

/// Runs without the menu bar icon, does one job and quits:
///
///     "AI Usage.app/Contents/MacOS/AI Usage" --set-server my-mac.local:8796
///     "AI Usage.app/Contents/MacOS/AI Usage" --refresh-once
///     "AI Usage.app/Contents/MacOS/AI Usage" --render-previews ~/Desktop/widgets [--sample]
///
/// --refresh-once reads every period through the shared container and redraws the widgets, printing
/// what it read. --render-previews draws each widget layout in light and dark mode to PNG files, from
/// the dashboard or, with --sample, from made-up numbers.
enum CommandLineMode {
    static let flags = ["--set-server", "--refresh-once", "--render-previews", "--help"]
    static let arguments = Array(CommandLine.arguments.dropFirst())
    static let isActive = arguments.contains { flags.contains($0) }

    @MainActor
    static func run(model: AppModel) async -> Int32 {
        if arguments.contains("--help") {
            print("""
            AI Usage widgets
              --set-server ADDRESS          save the dashboard address, such as my-mac.local:8796
              --refresh-once                read every period now and redraw the widgets
              --render-previews FOLDER      draw the widget layouts to PNG files
                  --sample                  with made-up numbers instead of the dashboard's
            """)
            return 0
        }
        if let address = value(after: "--set-server") {
            if let problem = model.setServer(address) {
                print(problem)
                return 1
            }
            print("Saved \(model.server.absoluteString)")
        }
        if arguments.contains("--refresh-once") {
            var failed = false
            for range in UsageRanges.all {
                let reading = await Reading.load(range: range, record: true)
                if let summary = reading.summary, reading.error == nil {
                    let windows = summary.plans.map { "\($0.short) \($0.windows.count)" }.joined(separator: ", ")
                    print("\(range): \(summary.host), generated \(summary.generatedAt), windows: \(windows)")
                } else {
                    failed = true
                    print("\(range): \(reading.error ?? "no reading")")
                }
            }
            print("Shared container: \(SharedStore.folder?.path ?? "unavailable")")
            WidgetCenter.shared.reloadAllTimelines()
            return failed ? 1 : 0
        }
        if let folder = value(after: "--render-previews") {
            do {
                let written = try await PreviewRenderer.render(
                    to: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath),
                    sample: arguments.contains("--sample"))
                print("Wrote \(written) images to \(folder)")
                return 0
            } catch {
                print("Couldn't render: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Draws the production widget views at the system widget sizes, for checking layouts without
/// placing widgets, and for screenshots (with --sample).
@MainActor
enum PreviewRenderer {
    static func render(to folder: URL, sample: Bool) async throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        var entries: [String: UsageEntry] = [:]
        for range in UsageRanges.all {
            if sample {
                var summary = UsageSummary.sample(now: now)
                summary.range = range
                summary.rangeLabel = ["today": "Today", "7d": "Last 7 days", "30d": "Last 30 days"][range] ?? range
                entries[range] = UsageEntry(date: now, summary: summary, fetchedAt: now, error: nil,
                                            server: UsageClient.defaultServer, vendor: nil, isSample: true)
            } else {
                entries[range] = UsageEntry(date: now, reading: await Reading.load(range: range))
            }
        }
        let limits = entries[UsageRanges.limits]!
        var count = 0
        func save<V: View>(_ name: String, _ family: WidgetFamily, _ view: V) throws {
            for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let card = WidgetCard(family: family) { view }.environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: card)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: folder.appendingPathComponent("\(name)-\(schemeName).png"))
                count += 1
            }
        }
        let sizes: [(String, WidgetFamily)] = [("small", .systemSmall), ("medium", .systemMedium),
                                               ("large", .systemLarge), ("extra-large", .systemExtraLarge)]
        for (size, family) in sizes {
            try save("limits-all-\(size)", family, LimitsWidgetView(entry: limits, family: family))
        }
        for vendor in ["anthropic", "openai", "google"] {
            var entry = limits
            entry.vendor = vendor
            for (size, family) in sizes.prefix(3) {
                try save("limits-\(vendor)-\(size)", family, LimitsWidgetView(entry: entry, family: family))
            }
        }
        for range in UsageRanges.all {
            for (size, family) in sizes.prefix(2) {
                try save("totals-\(range)-\(size)", family, UsageWidgetView(entry: entries[range]!, family: family))
            }
        }
        // The states that need room: offline (with its note), and with --sample, old readings and
        // reader problems.
        var offline = limits
        offline.error = "Can't reach AI Usage at my-mac.local:8796: timed out"
        offline.fetchedAt = now.addingTimeInterval(-2 * 3600)
        for (size, family) in sizes {
            try save("limits-all-\(size)-offline", family, LimitsWidgetView(entry: offline, family: family))
        }
        var googleOffline = offline
        googleOffline.vendor = "google"
        for (size, family) in sizes.prefix(3) {
            try save("limits-google-\(size)-offline", family, LimitsWidgetView(entry: googleOffline, family: family))
        }
        var totalsOffline = entries[UsageRanges.limits]!
        totalsOffline.error = offline.error
        totalsOffline.fetchedAt = offline.fetchedAt
        for (size, family) in sizes.prefix(2) {
            try save("totals-7d-\(size)-offline", family, UsageWidgetView(entry: totalsOffline, family: family))
        }
        if sample, var summary = limits.summary {
            summary.plans = summary.plans.map { troubled($0, now: now) }
            var problems = limits
            problems.summary = summary
            for (size, family) in sizes {
                try save("limits-all-\(size)-problems", family, LimitsWidgetView(entry: problems, family: family))
            }
            for vendor in ["anthropic", "google"] {
                var entry = problems
                entry.vendor = vendor
                for (size, family) in sizes.prefix(3) {
                    try save("limits-\(vendor)-\(size)-problems", family, LimitsWidgetView(entry: entry, family: family))
                }
            }
        }
        let empty = UsageEntry(date: now, summary: nil, fetchedAt: nil, error: "timed out",
                               server: UsageClient.normalize("my-mac.local:8796")!, vendor: nil)
        try save("limits-all-small-unavailable", .systemSmall, LimitsWidgetView(entry: empty, family: .systemSmall))
        return count
    }

    /// The sample with what real readings run into: a Claude reading three days old and past its
    /// reset, reader errors, ChatGPT nearly out, and Antigravity readings seven hours old.
    static func troubled(_ plan: Plan, now: Date) -> Plan {
        var plan = plan
        switch plan.vendor {
        case "anthropic":
            plan.warning = "Probe: Claude CLI not found"
            if !plan.windows.isEmpty {
                plan.windows[0].observedAt = now.addingTimeInterval(-3 * 86400)
                plan.windows[0].resetsAt = now.addingTimeInterval(-3 * 86400 + 2 * 3600)
            }
        case "openai":
            plan.windows = [
                LimitWindow(label: "5-hour", leftPct: 24, resetsAt: now.addingTimeInterval(3 * 3600),
                            observedAt: now.addingTimeInterval(-120)),
                LimitWindow(label: "Weekly", leftPct: 8, resetsAt: now.addingTimeInterval(15 * 3600 + 58 * 60),
                            observedAt: now.addingTimeInterval(-120)),
            ]
        case "google":
            plan.warning = "Antigravity quota: no language server found"
            for index in plan.windows.indices {
                plan.windows[index].observedAt = now.addingTimeInterval(-7 * 3600)
            }
        default:
            break
        }
        return plan
    }
}
