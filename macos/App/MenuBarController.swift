import AppKit
import Combine
import SwiftUI
import AIUsageKit

extension AppModel {
    func menuBarMeters(at now: Date) -> [MenuBarMeter] {
        HistoryProvider.allCases.filter(meterProviders.contains).map {
            MenuBarMeter(provider: $0, percent: limits?.menuBarQuota(for: $0, at: now))
        }
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    private var lastDescription: String?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model))
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
        // A limit can expire while the next network refresh is backing off.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
        update()
    }

    private func update() {
        guard model.showMenuBarIcon else {
            if let item {
                popover.performClose(nil)
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                lastDescription = nil
            }
            return
        }
        if item == nil {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            newItem.autosaveName = "AI Usage"
            newItem.button?.target = self
            newItem.button?.action = #selector(togglePanel)
            item = newItem
        }
        let meters = model.menuBarMeters(at: Date())
        let description = MenuBarSymbol(meters: meters, sample: model.source == .demo).description
        guard description != lastDescription, let button = item?.button else { return }
        lastDescription = description
        button.image = MenuBarSymbol.image(meters: meters)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}
