import AppKit
import SwiftUI

struct GoogleQuotaGuide: View {
    static let dashboardAddress = "localhost:8796"
    @Environment(\.dismiss) private var dismiss
    @State private var commandCopied = false
    @State private var showCommand = false
    let connect: () -> Void

    private static let command: String? = Bundle.main.url(forResource: "GoogleQuotaSetup", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Google Antigravity quota").font(.title2.bold()).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quota
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            Divider()
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect to localhost:8796", action: connect)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 490, height: 490)
    }

    @ViewBuilder private var quota: some View {
        step("1. Open Antigravity on this Mac", "Sign in to the Antigravity desktop app and leave it running. It supplies the remaining percentage and reset time for each model group Google reports.")
        VStack(alignment: .leading, spacing: 6) {
            Text("2. Start the quota reader").font(.headline)
            Text("If you already run an AI Usage dashboard on localhost:8796, skip to step 3. Otherwise, copy the command below, paste it into Terminal on this Mac and press Return. Leave Terminal open while you want quota updates. Control-C stops the reader.")
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
