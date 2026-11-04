import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TestModel
    @ObservedObject var results: Results

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let problem = model.listenerProblem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
                if model.options.phase == .first {
                    networkStep
                    foldersStep
                    chatGPTStep
                    statusLineStep
                    finish
                } else {
                    automatic
                }
                activity
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Usage Store Test")
                    .font(.title2.weight(.semibold))
                Text("Build \(model.version), \(model.phaseName). Four checks for a Mac App Store version of AI Usage. It never reads your prompts or passwords, and keeps only counts and the results below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Copy results") { model.copyResults() }
        }
    }

    // MARK: - Steps

    private var networkStep: some View {
        Step(number: 1, title: "Your network") {
            Text("This app has only the NSAllowsLocalNetworking exception to App Transport Security. It read its own address when it opened:")
            Checks(results: results, ids: ["net.loopback-ip", "net.localhost", "net.ats-control"])
            Question("Did macOS ask about finding devices on your local network when this app opened?",
                     id: "net.prompt-at-launch", test: 2, model: model, results: results)
            HStack {
                Button(model.lanRunning ? "Reading…" : "Read the dashboard on your network") {
                    Task { await model.runLANCheck() }
                }
                .disabled(model.lanRunning || model.options.lanURL == nil)
                if model.lanRunning {
                    ProgressView().controlSize(.small)
                }
            }
            Text(model.options.lanURL == nil ? "No network address was given, so this part is skipped." : "If macOS asks to let the app find devices on your local network, click Allow.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Checks(results: results, ids: ["net.lan"])
            if results.check("net.lan") != nil {
                Question("Did macOS ask about your local network after you clicked the button?",
                         id: "net.prompt-lan", test: 2, model: model, results: results)
            }
            Text("Then add the test widget: Control-click the desktop, choose Edit Widgets, search for \"Store Test\" and add the small one. It reads the same addresses and reports here.")
                .fixedSize(horizontal: false, vertical: true)
            Checks(results: results, ids: ["widget.config", "widget.loopback-ip", "widget.lan"])
            Button("Ask the widget to read again") { model.askWidgetAgain() }
        }
    }

    private var foldersStep: some View {
        Step(number: 2, title: "Your Claude Code and Codex folders") {
            Text("Each button opens an Open panel at your home folder. Select the folder it names and click Allow. The test counts what's inside and reads 64 bytes of one log; it keeps no contents.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose .claude…") { model.choose(.claude) }
                Button("Choose .codex…") { model.choose(.codex) }
            }
            Checks(results: results, ids: ["folders.claude", "folders.codex"])
            if results.check("folders.claude") != nil || results.check("folders.codex") != nil {
                Question("Did the panel list .claude and .codex without you turning on hidden files (⌘⇧.)?",
                         id: "folders.hidden-visible", test: 3, model: model, results: results)
            }
        }
    }

    private var chatGPTStep: some View {
        Step(number: 3, title: "ChatGPT limits through the bundled Codex") {
            Text("This starts OpenAI's Codex app-server inside the app's sandbox, signs you in with ChatGPT in a browser window, reads your limits, then watches for a minute which servers Codex contacts. It uses its own sign-in, separate from your Codex CLI.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.codexRunning ? "Working…" : "Sign in with ChatGPT…") {
                    Task { await model.runCodexTest() }
                }
                .disabled(model.codexRunning)
                if model.codexRunning {
                    ProgressView().controlSize(.small)
                }
                if model.signInWaiting {
                    Button("Stop") { model.stopSignIn() }
                }
            }
            Text(model.codexStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = model.browserFallbackURL {
                Button("No sign-in window? Copy the sign-in link for a private browser window") {
                    model.copySignInLink(url)
                }
                .buttonStyle(.link)
            }
            Checks(results: results, prefix: "codex.")
        }
    }

    private var statusLineStep: some View {
        Step(number: 4, title: "Claude limits from the status line") {
            Text("Terminal walks you through this one after you click Continue in Terminal below: it switches your Claude Code status line to a snippet for a minute and puts yours back.")
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = model.snippet {
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Self-test readings: \(model.sampleReadings). Readings from Claude Code: \(model.claudeReadings.count).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Checks(results: results, prefix: "statusline.")
        }
    }

    private var finish: some View {
        HStack {
            Button(model.handoff ? "Continued in Terminal" : "Continue in Terminal") {
                model.continueInTerminal()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.handoff)
            Text(model.handoff ? "Go back to Terminal." : "Click this when steps 1 to 3 are done (or as far as they go).")
                .foregroundStyle(.secondary)
        }
    }

    private var automatic: some View {
        Step(number: nil, title: "Checking again after the \(model.phaseName)") {
            Text("Nothing to do here: the app checks its address, the folder bookmarks and the Codex sign-in by itself, then Terminal carries on.")
            Checks(results: results, prefix: "")
        }
    }

    private var activity: some View {
        DisclosureGroup("Activity") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(results.events.suffix(200).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct Step<Content: View>: View {
    var number: Int?
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(number.map { "\($0). \(title)" } ?? title)
                .font(.headline)
        }
    }
}

/// The results for some checks, by id or by id prefix.
private struct Checks: View {
    @ObservedObject var results: Results
    var ids: [String] = []
    var prefix: String?

    var body: some View {
        let rows = prefix.map { prefix in results.checks.filter { $0.id.hasPrefix(prefix) } }
            ?? ids.compactMap { results.check($0) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(row.status))
                        .foregroundStyle(color(row.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.callout.weight(.medium))
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func symbol(_ status: CheckStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .running: return "clock"
        case .pending: return "circle"
        case .info: return "info.circle"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ status: CheckStatus) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .running, .pending: return .secondary
        case .info, .skipped: return .blue
        }
    }
}

/// A yes/no question whose answer goes in the results.
private struct Question: View {
    var text: String
    var id: String
    var test: Int
    @ObservedObject var model: TestModel
    @ObservedObject var results: Results

    init(_ text: String, id: String, test: Int, model: TestModel, results: Results) {
        self.text = text
        self.id = id
        self.test = test
        self.model = model
        self.results = results
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let answer = results.check(model.id(id))?.detail {
                Text(answer).foregroundStyle(.secondary)
            } else {
                Button("No") { model.answer(id, test: test, text, "No") }
                Button("Yes") { model.answer(id, test: test, text, "Yes") }
            }
        }
    }
}
