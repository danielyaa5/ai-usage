import AppKit
import SwiftUI

struct GoogleSetupGuide: View {
    enum Topic: String, Identifiable {
        case usage = "Local usage"
        case quota = "Remaining quota"
        var id: Self { self }
    }

    static let dashboardAddress = "localhost:8796"
    @State private var topic: Topic
    @State private var commandCopied = false
    @State private var showCommand = false
    let localSource: Bool
    let finish: (Topic?) -> Void

    init(topic: Topic, localSource: Bool, finish: @escaping (Topic?) -> Void) {
        _topic = State(initialValue: topic)
        self.localSource = localSource
        self.finish = finish
    }

    private static let command: String? = Bundle.main.url(forResource: "GoogleQuotaSetup", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Google Antigravity setup").font(.title2.bold())
                Picker("What would you like to see?", selection: $topic) {
                    Text(Topic.usage.rawValue).tag(Topic.usage)
                    Text(Topic.quota.rawValue).tag(Topic.quota)
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if topic == .usage { usage } else { quota }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            Divider()
            HStack {
                Button("Done") { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                if topic == .usage {
                    Button(localSource ? "Choose .gemini folder…" : "Show local sources") { finish(.usage) }
                } else {
                    Button("Connect to localhost:8796") { finish(.quota) }
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 490, height: 490)
    }

    @ViewBuilder private var usage: some View {
        step("1. Save a conversation on this Mac", "Use a model in the Antigravity app or its CLI and let it save the reply. AI Usage counts the recorded requests, tokens and estimated API value.")
        step("2. Connect your history folder", "In Sources → This Mac, click Connect beside Google Antigravity. Select the .gemini folder in your home folder. To jump there in the picker, press Shift–Command–G, enter ~/.gemini and press Return. Click Connect to grant read-only access.")
        step("3. Add your widget", "Control-click the desktop and choose Edit Widgets. AI usage totals adds up all connected tools. For Antigravity alone, add a medium or larger AI plan limits widget, Control-click it, choose Edit Widget and set Plan to Google AI (Antigravity).")
        Text("If you see zero requests, complete a request in Antigravity, let it save and click Refresh now. History works without a dashboard. For the percentage left on your plan, choose Remaining quota above.")
            .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var quota: some View {
        step("1. Open Antigravity on this Mac", "Sign in to the Antigravity desktop app and leave it running. It supplies the remaining percentage and reset time for each model group Google reports.")
        VStack(alignment: .leading, spacing: 6) {
            Text("2. Start a dashboard on this Mac").font(.headline)
            Text("Already running AI Usage on localhost:8796? Go straight to step 3. Otherwise, open Terminal, paste the setup command and press Return. It downloads a verified copy of the quota reader and runs it on this Mac only. Leave Terminal open while you want updates. Control-C stops it.")
            Text("The command needs Python 3.9 or newer. Run the same command again after quitting Terminal or restarting your Mac.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(commandCopied ? "Copied" : "Copy Terminal command") {
                    if let command = Self.command {
                        NSPasteboard.general.clearContents()
                        commandCopied = NSPasteboard.general.setString(command, forType: .string)
                    }
                }.disabled(Self.command == nil)
                Link("Get Python for Mac", destination: URL(string: "https://www.python.org/downloads/macos/")!)
            }
            DisclosureGroup("Read the command", isExpanded: $showCommand) {
                Text(Self.command ?? "The setup command is missing from this copy of AI Usage.")
                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        step("3. Connect and check the widget", "Click Connect to localhost:8796 below, or enter localhost:8796 in Sources → Dashboard and click Save and read. Add AI plan limits and set its Plan to Google AI (Antigravity). Allow up to five minutes for a reading, then click Refresh now.")
        Text("This Terminal reader supplies quota only. Switch to This Mac for recorded usage. If you use the full dashboard, it can supply both.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail)
        }
    }
}
