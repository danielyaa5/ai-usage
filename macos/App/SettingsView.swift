import SwiftUI
import WidgetKit
import AIUsageKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var address = ""
    @State private var problem: String?
    @State private var saved = false
    @State private var openAtLogin = LoginItem.isEnabled
    @AppStorage("showMenuBarIcon") private var showIcon = true

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("my-mac.local:8796"))
                    .onSubmit(save)
                HStack(spacing: 8) {
                    Button("Save and read", action: save)
                        .keyboardShortcut(.defaultAction)
                    status
                }
            } header: {
                Text("AI Usage dashboard")
            } footer: {
                Text("The dashboard's address as you open it in a browser, such as my-mac.local:8796 or "
                     + "localhost:8796 on the Mac that runs it. A path works too: my-server.local:8088/ai-usage/.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                        } catch {
                            problem = "Couldn't change the login item: \(error.localizedDescription)"
                            openAtLogin = LoginItem.isEnabled
                        }
                    }
                Toggle("Show in menu bar", isOn: $showIcon)
            } footer: {
                Text("The app reads the dashboard every 5 minutes for the widgets. With the menu bar icon "
                     + "hidden, open AI Usage again to get back here.")
                    .foregroundStyle(.secondary)
            }

            Section {
                WidgetCard(family: .systemMedium) {
                    LimitsWidgetView(entry: model.entry(), family: .systemMedium)
                }
                .frame(maxWidth: .infinity)
            } header: {
                Text("Widgets")
            } footer: {
                Text("To add them, Control-click the desktop, choose Edit Widgets, and search for AI Usage. "
                     + "Edit a widget to pick one plan or the period it totals.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { address = SharedStore.loadConfig().server?.absoluteString ?? "" }
    }

    @ViewBuilder private var status: some View {
        if let problem {
            Text(problem).foregroundStyle(.red).font(.callout).lineLimit(3)
        } else if model.refreshing {
            ProgressView().controlSize(.small)
        } else if saved, let reading = model.limits {
            if let error = reading.error {
                Text(error).foregroundStyle(.red).font(.callout).lineLimit(3)
            } else if let summary = reading.summary {
                Label("Read \(summary.host): \(summary.plans.count) plans", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    private func save() {
        problem = model.setServer(address)
        saved = problem == nil
        if saved { address = model.server.absoluteString }
    }
}
