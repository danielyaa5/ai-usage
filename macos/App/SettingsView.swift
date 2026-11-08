import SwiftUI
import WidgetKit
import AIUsageKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var local: LocalSources
    private var tab: String { model.settingsTab }
    @State private var address = ""
    @State private var previousCommand = ""
    @State private var statusOptions = false
    @State private var openAtLogin = LoginItem.isEnabled
    @AppStorage("showMenuBarIcon") private var showIcon = true

    init(model: AppModel) {
        self.model = model
        self.local = model.local
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Usage").font(.title.bold())
                    Text(tab == "Sources" ? "Choose where your readings come from." : "Plan limits and recent usage on your desktop.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("View", selection: $model.settingsTab) {
                    Text("Sources").tag("Sources")
                    Text("Widgets").tag("Widgets")
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }.padding(20)
            Divider()
            Form {
                if tab == "Sources" {
                    Picker("Source", selection: Binding(get: { model.source }, set: model.setSource)) {
                        Text("This Mac").tag(SharedStore.Source.local)
                        Text("Dashboard").tag(SharedStore.Source.dashboard)
                        Text("Demo").tag(SharedStore.Source.demo)
                    }.pickerStyle(.segmented)
                    switch model.source {
                    case .local: localSetup
                    case .dashboard: dashboardSetup
                    case .demo:
                        Section("Sample data") {
                            Text("The app and widgets now show fictional readings. Switch to This Mac to see your own usage.")
                            Button("Preview widgets") { model.settingsTab = "Widgets" }
                        }
                    }
                } else {
                    widgetPreview
                    Section("Preferences") {
                        Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { enabled in
                            do { try LoginItem.set(enabled); openAtLogin = LoginItem.isEnabled }
                            catch { local.notice = "Could not change Open at login. Check Login Items in System Settings." }
                        }))
                        Toggle("Show icon in menu bar", isOn: $showIcon)
                    }
                }
                if let notice = local.notice {
                    Section {
                        Text(notice).textSelection(.enabled)
                        Button("Dismiss") { local.notice = nil }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if model.refreshing { ProgressView().controlSize(.small); Text("Reading usage…") }
                else if let date = model.lastAttempt { Text("Last checked \(date.formatted(date:.omitted,time:.shortened))") }
                Spacer()
                Button("Refresh now") { model.refresh() }.disabled(model.refreshing)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,10)
        }
        .frame(width: 580, height: 600)
        .onAppear { address = SharedStore.loadConfig().server?.absoluteString ?? "" }
    }

    @ViewBuilder private var localSetup: some View {
        Section {
            ForEach(HistoryProvider.allCases, id:\.self) { provider in
                HStack {
                    VStack(alignment:.leading, spacing:3) {
                        Text(provider == .antigravity ? "Google Antigravity" : provider.title).fontWeight(.medium)
                        Text(local.messages[provider] ?? (local.selected.contains(provider) ? "Connected" : provider.folder + " folder"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(local.selected.contains(provider) ? "Choose again…" : "Connect…") { local.pick(provider) }
                        .help("Choose the \(provider.folder) folder in your home folder.")
                        .accessibilityIdentifier("history-" + provider.rawValue)
                    if local.selected.contains(provider) {
                        Button { local.forget(provider) } label: { Image(systemName:"xmark.circle") }
                            .help("Disconnect " + provider.title).accessibilityLabel("Disconnect " + provider.title)
                    }
                }
            }
        } header: { Text("Usage on this Mac") }
        footer: { Text("Choose a tool’s folder in your home folder to count its saved requests and tokens. The picker shows hidden folders. Access is read-only, and history stays on this Mac.") }

        Section {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("ChatGPT limits").fontWeight(.medium)
                    Text(local.chatConnected ? "Connected to OpenAI" : "Sign in to see the limits on your plan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if local.accountBusy {
                    ProgressView().controlSize(.small)
                    if !local.chatConnected { Button("Cancel") { local.cancelLogin() } }
                } else {
                    Button(local.chatConnected ? "Sign out" : "Sign in with ChatGPT…") { local.toggleAccount() }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code limits").fontWeight(.medium)
                    Text(local.statusLineEnabled ? "Status-line receiver enabled" : "Use the limits Claude Code provides after a reply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(local.statusLineEnabled ? (statusOptions ? "Hide" : "Manage…") : "Set up…") {
                    if !local.statusLineEnabled { local.toggleStatusLine(true) }
                    statusOptions.toggle()
                }.accessibilityIdentifier("claude-limits-setup")
            }
            if statusOptions && local.statusLineEnabled {
                Text("Merge the copied statusLine setting into your Claude Code settings.json. If you already use a status line, paste its command below first. Then send a message in Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Existing status-line command (optional)", text: $previousCommand)
                HStack {
                    Button("Copy statusLine setting") { local.copyStatusLine(previousCommand: previousCommand) }
                        .disabled(!local.statusLineReady)
                    Spacer()
                    Button("Turn off receiver") {
                        local.toggleStatusLine(false)
                        statusOptions = false
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Google Antigravity quota").fontWeight(.medium)
                    Text(local.googleQuotaStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(local.googleQuotaConnected ? "Disconnect" : "Connect Google quota") {
                    if local.googleQuotaConnected { local.disconnectGoogleQuota() }
                    else { local.connectGoogleQuota() }
                }
                    .accessibilityIdentifier("google-quota-setup")
            }
        } header: { Text("Account limits") }
        footer: { Text("Codex history can also contain a recent limit reading.") }
        Button("View my widgets") { model.settingsTab = "Widgets" }
    }

    @ViewBuilder private var dashboardSetup: some View {
        Section("Your dashboard") {
            TextField("Address", text:$address, prompt:Text("my-mac.local:8796")).onSubmit(saveAddress)
            Button("Save and read") { saveAddress() }
            Button("Use Google quota on this Mac") {
                if !local.googleQuotaConnected { local.notice = local.connectGoogleQuota() }
                if local.googleQuotaConnected { model.setSource(.local) }
            }
            if let issue = model.limits?.error { Text(issue).foregroundStyle(.secondary) }
        }
        Text("Use this option if you already run an AI Usage dashboard. This Mac works independently.")
            .font(.callout).foregroundStyle(.secondary)
    }
    private func saveAddress() { local.notice = model.setServer(address) }

    @ViewBuilder private var widgetPreview: some View {
        Section(model.source == .demo ? "Demo · sample data" : "Current widget readings") {
            WidgetCard(family:.systemMedium) { LimitsWidgetView(entry:model.entry(),family:.systemMedium) }
            WidgetCard(family:.systemMedium) { UsageWidgetView(entry:model.entry(),family:.systemMedium) }
        }
        Section("Add to your desktop") {
            Text("Control-click the desktop, choose Edit Widgets and search for AI Usage. AI usage totals combines your connected tools. To see one plan’s seven-day totals, add a medium or larger AI plan limits widget, Control-click it and choose the plan.")
        }
    }
}
