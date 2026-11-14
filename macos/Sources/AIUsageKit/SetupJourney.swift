import Foundation

public enum SettingsPage: String, Codable, CaseIterable, Equatable, Sendable {
    case connections, widgets, menuBar, advanced
}

public enum AppURLRoute: Equatable, Sendable {
    case refresh
    case dashboard
    case settings(SettingsPage?)

    public static func resolve(_ url: URL, expectedScheme: String) -> Self? {
        resolve(url, acceptedSchemes: [expectedScheme])
    }

    public static func resolve(_ url: URL, acceptedSchemes: Set<String>) -> Self? {
        guard let scheme = url.scheme?.lowercased(),
              acceptedSchemes.contains(where: { $0.lowercased() == scheme }) else { return nil }
        switch url.host?.lowercased() {
        case "refresh":
            return .refresh
        case "widgets":
            return .settings(.widgets)
        case "connections":
            return .settings(.connections)
        case "settings":
            let subpath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            switch subpath {
            case "": return .settings(nil)
            case "connections": return .settings(.connections)
            case "widgets": return .settings(.widgets)
            case "menubar", "menu-bar": return .settings(.menuBar)
            case "advanced": return .settings(.advanced)
            default: return .settings(nil)
            }
        default:
            return .dashboard
        }
    }
}

/// Coordinates Guided Setup persistence and default landing-page selection across launches and reopens.
public struct SetupState: Equatable {
    public static let journeyKey = "setupJourney"
    public static let shownKey = "setupShown"

    public private(set) var journey: SetupJourney?
    public var showsSetup: Bool
    public var settingsPage: SettingsPage

    public static func isSourceConfigured(
        source: SharedStore.Source,
        hasLocalSources: Bool,
        hasDashboardServer: Bool
    ) -> Bool {
        switch source {
        case .local: return hasLocalSources
        case .demo: return true
        case .dashboard: return hasDashboardServer
        }
    }

    public init(defaults: UserDefaults, isConfigured: Bool) {
        let restored = SetupJourney.restore(defaults.data(forKey: Self.journeyKey))
        if isConfigured {
            if restored != nil {
                defaults.set(true, forKey: Self.shownKey)
                defaults.removeObject(forKey: Self.journeyKey)
            }
            self.journey = nil
            self.showsSetup = false
            self.settingsPage = .widgets
        } else {
            self.journey = restored
            self.showsSetup = restored != nil
            self.settingsPage = .connections
        }
    }

    public mutating func begin(defaults: UserDefaults) {
        save(SetupJourney(), defaults: defaults)
        showsSetup = true
    }

    public mutating func prepareIfNeeded(source: SharedStore.Source, isConfigured: Bool, defaults: UserDefaults) {
        if isConfigured {
            if journey != nil { save(nil, defaults: defaults) }
            showsSetup = false
            return
        }
        guard source == .local, journey == nil, !defaults.bool(forKey: Self.shownKey) else { return }
        begin(defaults: defaults)
    }

    public mutating func edit(_ transform: (inout SetupJourney) -> Void, defaults: UserDefaults) {
        guard var progress = journey else { return }
        transform(&progress)
        save(progress, defaults: defaults)
    }

    public mutating func finish(page: SettingsPage = .connections, defaults: UserDefaults) {
        showsSetup = false
        save(nil, defaults: defaults)
        settingsPage = page
    }

    /// Auto-finishes an incomplete setup journey when closing the window if at least one source is configured.
    @discardableResult
    public mutating func handleWindowClose(isConfigured: Bool, defaults: UserDefaults) -> Bool {
        guard journey != nil, isConfigured else { return false }
        finish(page: .widgets, defaults: defaults)
        return true
    }

    public mutating func preparePresentation(
        requestedPage: SettingsPage?,
        windowAlreadyOpen: Bool,
        source: SharedStore.Source,
        isConfigured: Bool,
        defaults: UserDefaults
    ) {
        if let requestedPage {
            if isConfigured, journey != nil { save(nil, defaults: defaults) }
            showsSetup = false
            settingsPage = requestedPage
            return
        }
        if windowAlreadyOpen {
            if isConfigured, showsSetup {
                if journey != nil { save(nil, defaults: defaults) }
                showsSetup = false
                settingsPage = .widgets
            }
            return
        }
        if isConfigured {
            if journey != nil { save(nil, defaults: defaults) }
            showsSetup = false
            settingsPage = .widgets
        } else {
            prepareIfNeeded(source: source, isConfigured: false, defaults: defaults)
            showsSetup = journey != nil
            settingsPage = .connections
        }
    }

    private mutating func save(_ progress: SetupJourney?, defaults: UserDefaults) {
        defaults.set(true, forKey: Self.shownKey)
        if let progress, let data = try? JSONEncoder().encode(progress) {
            defaults.set(data, forKey: Self.journeyKey)
        } else {
            defaults.removeObject(forKey: Self.journeyKey)
        }
        journey = progress
    }
}

/// First-run progress contains only tool choices and the current step.
public struct SetupJourney: Codable, Equatable {
    public enum Step: String, Codable, CaseIterable { case tools, connections, widget }
    public private(set) var step = Step.tools
    public private(set) var tools: [HistoryProvider] = []
    public private(set) var index = 0

    public init() {}
    public var provider: HistoryProvider? { tools.indices.contains(index) ? tools[index] : nil }

    public static func restore(_ data: Data?) -> Self? {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.tools.count == Set(value.tools).count, value.index >= 0,
              value.tools.isEmpty ? (value.index == 0 && value.step == .tools) : value.provider != nil else { return nil }
        return value
    }

    public mutating func toggle(_ tool: HistoryProvider) {
        guard step == .tools else { return }
        if tools.contains(tool) { tools.removeAll { $0 == tool } }
        else { tools = HistoryProvider.allCases.filter { tools.contains($0) || $0 == tool } }
        index = 0
    }

    public mutating func advance() {
        guard !tools.isEmpty else { return }
        switch step {
        case .tools: index = 0; step = .connections
        case .connections where index + 1 < tools.count: index += 1
        case .connections: step = .widget
        case .widget: break
        }
    }

    public mutating func back() {
        switch step {
        case .tools: break
        case .connections where index > 0: index -= 1
        case .connections: step = .tools
        case .widget: step = .connections
        }
    }
}
