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
enum AIUsageEntryPoint {
    @MainActor static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.first == ClaudeStatusReading.flag {
            ClaudeStatusReporter.run(passThrough: args.dropFirst().first == "--pass-through")
        } else {
            AIUsageApp.main()
        }
    }
}

struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView(model: delegate.model) }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show(model: delegate.model) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var menuBar: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLineMode.isActive { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLineMode.isActive {
            Task { @MainActor in exit(await CommandLineMode.run(model: self.model)) }
            return
        }
        RefreshUsageIntent.inApp = { [weak self] in self?.model.refresh() }
        menuBar = MenuBarController(model: model)
        model.start()
        // Finder and Spotlight send an open-application event. Login items, services and widget
        // links have their own launch behavior and must not raise an extra settings window.
        guard !CommandLine.arguments.contains("--background"),
              let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return }
        let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        if reason != keyAELaunchedAsLogInItem && reason != keyAELaunchedAsServiceItem {
            SettingsWindow.show(model: model)
        }
    }

    /// aiusage://dashboard from a widget click opens the dashboard; aiusage://settings opens settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == AppLink.scheme {
            if url.host == "refresh" {
                model.refresh()
                SettingsWindow.show(model: model, page: .widgets)
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

    #if CLAUDE_QUOTA_TEST
    func applicationWillTerminate(_ notification: Notification) { ClaudeQuotaProcess.stopAll() }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Login launch is an explicit user preference.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// The settings window gives the menu bar app a Dock and Command-Tab entry while it is open.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let controller = SettingsWindow()
    private var window: NSWindow?

    static func show(model: AppModel, page: SettingsPage? = nil) {
        controller.present(model: model, page: page)
    }

    private func present(model: AppModel, page: SettingsPage?) {
        if let page {
            model.showsSetup = false
            model.settingsPage = page
        } else if window == nil {
            model.prepareSetupIfNeeded()
            model.showsSetup = true
            model.settingsPage = .connections
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AI Usage"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(SettingsView.initialSize)
            created.contentMinSize = NSSize(width: 690, height: 470)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
