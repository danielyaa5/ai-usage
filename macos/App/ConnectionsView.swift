import SwiftUI
import AIUsageKit

extension HistoryProvider {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
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
        if provider == .claude && claudeSetupError != nil || provider == .codex && chatQuotaIssue != nil { return "Needs attention" }
        if lastQuotaReading(provider) != nil { return history ? "History and quota" : "Quota connected" }
        switch provider {
        case .claude where statusLineEnabled: return claudeSetupError == nil ? "Waiting for quota" : "Needs attention"
        case .codex where chatConnected: return "Signed in"
        case .antigravity where googleQuotaConnected: return "Waiting for quota"
        default: return history ? "History selected" : "Not connected"
        }
    }
    func connectionColor(_ provider: HistoryProvider) -> Color {
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
                "Choose your \(provider.folder) folder to count recorded requests and tokens."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(local.selected.contains(provider) ? "Choose another folder…" : "Connect history…") { local.pick(provider) }
                .accessibilityIdentifier("history-" + provider.rawValue)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaConnection: View {
    let provider: HistoryProvider
    @ObservedObject var local: LocalSources

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
        if let date = local.lastQuotaReading(.claude), local.statusLineReady, local.claudeSetupError == nil {
            ReadingState(text: "Connected · Last reading \(Self.time(date))", color: .green)
            Text("Claude Code sends updated limits after a reply.").foregroundStyle(.secondary)
            HStack {
                Button(local.claudeRequestCopied ? "Copied · Copy again" : "Copy setup request again") { local.copyClaudeSetupRequest() }
                    .accessibilityIdentifier("claude-copy-setup")
                Button("Disconnect") { local.toggleStatusLine(false) }
            }
        } else {
            Text("See when your five-hour and weekly limits reset.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                instruction(1, "Copy the setup request and paste it into Claude Code.")
                instruction(2, "Approve the change if asked, then send a message.")
            }
            HStack {
                Button(local.claudeRequestCopied ? "Copy setup request again" : "Copy setup request") { local.copyClaudeSetupRequest() }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("claude-copy-setup")
                if local.statusLineEnabled {
                    Button("Disconnect") { local.toggleStatusLine(false) }.buttonStyle(.link)
                }
            }
            if let issue = local.claudeSetupError {
                ReadingState(text: issue, color: .orange)
            } else {
                ReadingState(text: local.claudeRequestCopied ? "Copied · Waiting for Claude’s first reading" :
                    (local.statusLineEnabled ? "Waiting for Claude’s first reading" : "No reading yet"), color: .orange)
            }
        }
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
}
