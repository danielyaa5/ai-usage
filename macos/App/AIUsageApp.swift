import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit
import AIUsageKit

/// A small menu bar app that keeps the widgets' reading current: it reads the dashboard every few
/// minutes, shares the reply with the widget extension and redraws the widgets when something they
/// show has changed. Widget extensions only run when macOS asks them for a timeline, so the polling
/// lives here.
@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarIcon") private var showIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { showIcon && !CommandLineMode.isActive }, set: { showIcon = $0 })) {
            MenuPanel(model: delegate.model)
        } label: {
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel("AI Usage")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLineMode.isActive { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLineMode.isActive {
            Task { @MainActor in exit(await CommandLineMode.run(model: self.model)) }
            return
        }
        RefreshUsageIntent.inApp = { [weak self] in self?.model.refresh() }
        model.start()
        if !UserDefaults.standard.bool(forKey: "setupShown") && SharedStore.loadConfig().source == .local {
            UserDefaults.standard.set(true, forKey: "setupShown")
            SettingsWindow.show(model: model)
        }
    }

    /// aiusage://dashboard from a widget click opens the dashboard; aiusage://settings opens settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "aiusage" {
            if url.host == "refresh" {
                model.refresh()
                SettingsWindow.show(model: model, tab: "Widgets")
            } else if url.host == "settings" {
                SettingsWindow.show(model: model)
            } else {
                model.openDashboard()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows settings, which matters when the menu bar icon
    /// is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show(model: model)
        return false
    }
}

/// Login launch is an explicit user preference.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Settings in an AppKit window: the app has no Dock icon and no SwiftUI window scenes, and a widget
/// click or a second launch must be able to open it.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let controller = SettingsWindow()
    private var window: NSWindow?

    static func show(model: AppModel, tab: String = "Sources") {
        controller.present(model: model, tab: tab)
    }

    private func present(model: AppModel, tab: String) {
        model.settingsTab = tab
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "AI Usage"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}
