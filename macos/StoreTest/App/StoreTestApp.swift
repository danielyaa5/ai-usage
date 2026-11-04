import AppKit
import SwiftUI

/// A throwaway app that checks, on a real Mac, the four things a Mac App Store version of AI Usage
/// depends on. See README.md in this folder; scripts/run.sh opens it and collects the results.
@main
struct StoreTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("AI Usage Store Test", id: "main") {
            ContentView(model: delegate.model, results: delegate.model.results)
                .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 860)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TestModel(options: LaunchOptions.parse(CommandLine.arguments))

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
