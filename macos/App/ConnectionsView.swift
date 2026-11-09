import SwiftUI
import AIUsageKit

extension HistoryProvider {
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex / ChatGPT"
        case .antigravity: "Google Antigravity"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sun.max.fill"
        case .codex: "bubble.left.and.bubble.right.fill"
        case .antigravity: "sparkles"
        }
    }
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.80, green: 0.36, blue: 0.22)
        case .codex: Color(red: 0.12, green: 0.55, blue: 0.46)
        case .antigravity: .indigo
        }
    }
}

struct ReadingState: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(color, lineWidth: 2).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

extension LocalSources {
    func connectionLabel(_ provider: HistoryProvider) -> String {
        let history = selected.contains(provider)
        if provider == .claude, let desktop = claudeDesktop {
            if enteredDesktopUsage != nil { return "Entered quota" }
            switch desktop {
            case .checking: return "Checking Claude Desktop"
            case .unavailable(.access), .unavailable(.unsupported): return "Needs attention"
            case .unavailable: return "Waiting for Desktop"
            case .reading: return history ? "History and saved quota" : "Saved desktop quota"
            }
        }
        if provider == .claude && claudeSetupError != nil || provider == .codex && chatQuotaIssue != nil { return "Needs attention" }
        if lastQuotaReading(provider) != nil { return history ? "History and quota" : "Quota connected" }
        switch provider {
        case .claude where statusLineEnabled: return "Waiting for Terminal"
        case .codex where chatConnected: return "Signed in"
        case .antigravity where googleQuotaConnected: return "Waiting for quota"
        default: return history ? "History selected" : "Not connected"
        }
    }
    func connectionColor(_ provider: HistoryProvider) -> Color {
        if provider == .claude, let desktop = claudeDesktop {
            if enteredDesktopUsage != nil { return .secondary }
            return desktop.windows.first.map { $0.isStale() ? .orange : .green } ?? .orange
        }
        if provider == .claude && claudeSetupError != nil || provider == .codex && chatQuotaIssue != nil { return .orange }
        if lastQuotaReading(provider) != nil { return .green }
        if provider == .claude && statusLineEnabled || provider == .codex && chatConnected ||
            provider == .antigravity && googleQuotaConnected { return .orange }
        return selected.contains(provider) ? .accentColor : .secondary
    }
}

struct ProviderHeader: View {
    let provider: HistoryProvider
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbol).foregroundStyle(provider.tint).font(.system(size: 28)).accessibilityHidden(true)
            Text(title).font(.system(size: 27, weight: .bold)).accessibilityAddTraits(.isHeader)
        }
    }
}

struct HistoryConnection: View {
    let provider: HistoryProvider
    @ObservedObject var local: LocalSources
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage on this Mac").font(.headline)
                Spacer()
                if local.selected.contains(provider) {
                    Button("Disconnect history") { local.forget(provider) }
                        .buttonStyle(.link).font(.caption)
                        .accessibilityLabel("Disconnect " + provider.title + " history")
                }
            }
            Text(local.messages[provider] ?? (local.selected.contains(provider) ? "Folder selected" :
                (provider == .claude ? "Choose your .claude folder to count requests and tokens from Claude Code sessions on this Mac." :
                 "Choose your \(provider.folder) folder to count recorded requests and tokens.")))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(local.selected.contains(provider) ? "Choose another folder…" : "Connect history…") { local.pick(provider) }
                .accessibilityIdentifier("history-" + provider.rawValue)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaConnection: View {
    let provider: HistoryProvider
    @ObservedObject var local: LocalSources
    @State private var showsTerminal = false
    @State private var entersUsage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Remaining quota").font(.headline)
            switch provider {
            case .claude: claude
            case .codex: chatGPT
            case .antigravity: google
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var claude: some View {
        if let desktop = local.claudeDesktop {
            if !local.desktopWindows.isEmpty {
                ForEach(local.desktopWindows) { window in
                    HStack {
                        Text(window.label)
                        Spacer()
                        Text(Format.percent(window.leftPct) + " left").fontWeight(.semibold).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                if let manual = local.enteredDesktopUsage {
                    ReadingState(text: "Entered \(Self.time(manual.recordedAt))", color: .secondary)
                } else if let window = local.desktopWindows.first, let date = window.observedAt {
                    ReadingState(text: "Last saved by Claude Desktop \(Self.time(date))", color: window.isStale() ? .orange : .green)
                }
            } else if case .checking = desktop {
                ReadingState(text: "Checking Claude Desktop…", color: .secondary)
            }
            if case .unavailable(let problem) = desktop {
                ReadingState(text: problem.rawValue, color: .orange)
                if problem == .access {
                    Button("Choose Claude folder again…") { local.connectClaudeDesktop() }
                }
            }
            Text("The widget updates when Claude Desktop saves a reading. Claude’s Usage page shows current limits and reset times.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Check for a new reading") { local.changed?() }.accessibilityIdentifier("claude-desktop-refresh")
                Button("Disconnect Desktop") { local.disconnectClaudeDesktop() }.buttonStyle(.link)
            }
            if desktop != .checking && (desktop.windows.first?.isStale() != false || local.enteredDesktopUsage != nil) {
                Button("Enter current percentages…") { entersUsage = true }.buttonStyle(.link)
                    .sheet(isPresented: $entersUsage) { ClaudeUsageEntryForm(local: local) }
            }
        } else {
            Text("Show the five-hour and weekly percentages Claude Desktop saves on this Mac. Click Connect, then Allow in the folder picker.")
                .foregroundStyle(.secondary)
            Button("Connect Claude Desktop…") { local.connectClaudeDesktop() }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("claude-desktop-connect")
            if let date = local.lastQuotaReading(.claude), local.statusLineReady {
                ReadingState(text: "Terminal connected · Last reading \(Self.time(date))", color: .green)
            }
            DisclosureGroup("I use Claude Code in Terminal", isExpanded: $showsTerminal) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Use this option in the interactive Claude Code terminal. The desktop Code tab can use the connection above.")
                    instruction(1, "Paste the copied request into a terminal session running Claude Code.")
                    instruction(2, "Approve the change if asked, then send a message in that terminal.")
                    Button(local.claudeRequestCopied ? "Copy terminal request again" : "Copy terminal setup request") { local.copyClaudeSetupRequest() }
                        .accessibilityIdentifier("claude-copy-setup")
                    if let issue = local.claudeSetupError { ReadingState(text: issue, color: .orange) }
                    else if local.statusLineEnabled, local.lastQuotaReading(.claude) == nil {
                        ReadingState(text: local.claudeRequestCopied ? "Copied · Waiting for a terminal reading" :
                                     "Waiting for a terminal reading", color: .orange)
                    }
                    if local.statusLineEnabled { Button("Disconnect Terminal") { local.toggleStatusLine(false) }.buttonStyle(.link) }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 5)
            }
        }
        Link("Open Claude usage ↗", destination: Self.claudeUsageURL)
    }

    @ViewBuilder private var chatGPT: some View {
        if !local.chatConnected, let date = local.lastQuotaReading(.codex) {
            ReadingState(text: "Last reading from Codex \(Self.time(date))", color: .green)
            Text("Sign in for updates between Codex sessions.").foregroundStyle(.secondary)
        } else {
            Text("Sign in to ChatGPT to see your plan’s remaining limits.").foregroundStyle(.secondary)
        }
        if let issue = local.chatQuotaIssue { ReadingState(text: issue, color: .orange) }
        if local.accountBusy {
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                if !local.chatConnected { Button("Cancel") { local.cancelLogin() } }
            }
        } else {
            if local.chatConnected {
                ReadingState(text: local.lastQuotaReading(.codex).map { "Last reading \(Self.time($0))" } ?? "Signed in · Waiting for a reading",
                             color: local.lastQuotaReading(.codex) == nil ? .orange : .green)
                Button("Sign out") { local.toggleAccount() }
            } else {
                Button("Sign in with ChatGPT…") { local.toggleAccount() }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var google: some View {
        Text(local.googleQuotaStatus).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if local.googleQuotaConnected {
            if let date = local.lastQuotaReading(.antigravity) { ReadingState(text: "Last reading \(Self.time(date))", color: .green) }
            Button("Disconnect quota") { local.disconnectGoogleQuota() }.accessibilityIdentifier("google-quota-setup")
        } else {
            Button("Connect Google quota") { local.connectGoogleQuota() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("google-quota-setup")
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(number)").font(.caption.bold())
                .frame(width: 20, height: 20).background(Circle().fill(Color.secondary.opacity(0.12)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
    static let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!
}

private struct ClaudeUsageEntryForm: View {
    @ObservedObject var local: LocalSources
    @Environment(\.dismiss) private var dismiss
    @State private var fiveHour = ""
    @State private var weekly = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record Claude usage").font(.title2.bold())
            Text("Enter the percentages shown as used on Claude’s Usage page. Leave a missing limit blank.")
            Link("Open Claude usage ↗", destination: QuotaConnection.claudeUsageURL)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("Current session"); field("Five-hour percent used", $fiveHour) }
                GridRow { Text("Weekly · All models"); field("Weekly percent used", $weekly) }
            }
            Text("The widget labels these numbers as entered until Claude Desktop saves a newer reading.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save reading") {
                    guard let entry else { return }
                    local.recordDesktopUsage(entry)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(entry == nil)
            }
        }
        .padding(22).frame(width: 400).fixedSize(horizontal: false, vertical: true)
    }

    private var entry: ClaudeDesktopUsage.Entry? {
        .init(fiveHourText: fiveHour, weeklyText: weekly, at: Date())
    }
    private func field(_ name: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField(name, text: value, prompt: Text("0–100")).labelsHidden().accessibilityLabel(name).frame(width: 72)
            Text("% used").foregroundStyle(.secondary)
        }
    }
}
