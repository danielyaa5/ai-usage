import AppKit
import SwiftUI
import AIUsageKit

/// The menu bar panel: the large plan limits widget, then the app's actions.
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 12) {
            LimitsWidgetView(entry: model.entry(), family: .systemLarge)
                .frame(width: 332, height: 350, alignment: .topLeading)
            Divider()
            HStack(spacing: 8) {
                Button(model.source == .dashboard ? "Open dashboard" : "View usage") { model.openDashboard() }
                Button {
                    model.refresh()
                } label: {
                    if model.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh usage now")
                .disabled(model.refreshing)
                Spacer()
                Button("Settings…") { SettingsWindow.show(model: model) }
                Button {
                    SettingsWindow.showSupport(model: model)
                } label: { Image(systemName: "questionmark.circle") }
                .help("Contact support").accessibilityLabel("Contact support")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            if let error = model.limits?.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.stale)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 364)
        .background(palette.background)
    }
}
