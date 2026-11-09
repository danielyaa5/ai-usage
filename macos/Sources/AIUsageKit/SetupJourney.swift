import Foundation

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
