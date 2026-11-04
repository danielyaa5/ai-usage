import SwiftUI
import WidgetKit

/// The test widget: on each timeline it reads the app's test listener on 127.0.0.1 and the network
/// address the app shares, with only NSAllowsLocalNetworking in its Info.plist, then reports what
/// happened to the app and shows it.
@main
struct StoreTestWidgetBundle: WidgetBundle {
    var body: some Widget {
        StoreTestWidget()
    }
}

struct StoreTestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StoreTest", provider: Provider()) { entry in
            EntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("Store Test")
        .description("Checks plain HTTP to this Mac and your network for the AI Usage store test.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var lines: [String]
    var note: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), lines: ["127.0.0.1: …", "Network: …"], note: "Store Test")
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            completion(await WidgetChecks.run(source: "snapshot", family: "\(context.family)"))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = await WidgetChecks.run(source: "timeline", family: "\(context.family)")
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

enum WidgetChecks {
    static let log = StoreTestShared.logger("widget")

    static func run(source: String, family: String) async -> Entry {
        guard let config = StoreTestShared.read(StoreTestShared.Config.self, "config.json") else {
            let report = StoreTestShared.WidgetReport(at: Date(), source: source, family: family, outcomes: [], configFound: false)
            try? StoreTestShared.write(report, "widget-report.json")
            log.notice("WIDGET no config.json (app group \(StoreTestShared.appGroup == nil ? "missing" : "present", privacy: .public))")
            return Entry(date: Date(), lines: ["Open the test app first."], note: "No settings")
        }
        var outcomes: [URLCheckOutcome] = []
        if let ping = URL(string: "http://127.0.0.1:\(config.port)/ping") {
            outcomes.append(await URLCheck.run(name: "loopback-ip", url: ping, timeout: 5))
        }
        if let text = config.lanURL, let lan = URL(string: text) {
            outcomes.append(await URLCheck.run(name: "lan", url: lan, timeout: 8))
        }
        let report = StoreTestShared.WidgetReport(at: Date(), source: source, family: family, outcomes: outcomes, configFound: true)
        try? StoreTestShared.write(report, "widget-report.json")
        for outcome in outcomes {
            log.notice("WIDGET \(outcome.name, privacy: .public): \(outcome.summary, privacy: .public)")
        }
        await send(report, config: config)
        let lines = outcomes.map { outcome in
            "\(outcome.ok ? "✓" : "✗") \(outcome.name == "lan" ? "Network" : "127.0.0.1"): \(outcome.ok ? "OK" : outcome.summary)"
        }
        return Entry(date: Date(), lines: lines, note: "Checked \(Date().formatted(date: .omitted, time: .shortened))")
    }

    /// Tells the app, if it is running.
    private static func send(_ report: StoreTestShared.WidgetReport, config: StoreTestShared.Config) async {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)/widget-result"),
              let body = try? StoreTestShared.encoder.encode(report) else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.token, forHTTPHeaderField: "X-AI-Usage-Token")
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        _ = try? await session.data(for: request)
    }
}

struct EntryView: View {
    var entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Store Test")
                .font(.headline)
            ForEach(entry.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Text(entry.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
