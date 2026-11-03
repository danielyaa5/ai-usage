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
                Button("Open dashboard") { model.openDashboard() }
                Button {
                    model.refresh()
                } label: {
                    if model.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Read the dashboard now")
                .disabled(model.refreshing)
                Spacer()
                Button("Settings…") { SettingsWindow.show(model: model) }
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
