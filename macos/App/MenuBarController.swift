import AppKit
import Combine
import SwiftUI
import AIUsageKit

extension AppModel {
    func menuBarMeters(at now: Date) -> [MenuBarMeter] {
        HistoryProvider.allCases.filter(meterProviders.contains).map {
            limits?.menuBarMeter(for: $0, at: now) ?? MenuBarMeter(provider: $0, remainingPct: nil)
        }
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    private var lastMeters: [MenuBarMeter]?
    private var lastDescription: String?
    private var lastDark: Bool?
    private var appearanceObservation: NSKeyValueObservation?

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
                appearanceObservation = nil
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                lastMeters = nil
                lastDescription = nil
                lastDark = nil
            }
            return
        }
        if item == nil {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            newItem.autosaveName = "AI Usage"
            newItem.button?.target = self
            newItem.button?.action = #selector(togglePanel)
            item = newItem
            appearanceObservation = newItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.update() }
            }
        }
        let meters = model.menuBarMeters(at: Date())
        let description = MenuBarSymbol(meters: meters, sample: model.source == .demo).description
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard meters != lastMeters || description != lastDescription || dark != lastDark else { return }
        lastMeters = meters
        lastDark = dark
        lastDescription = description
        button.image = MenuBarSymbol.image(meters: meters, dark: dark)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}
