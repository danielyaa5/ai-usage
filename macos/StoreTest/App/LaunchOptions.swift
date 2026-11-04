import Foundation

/// What the runner script passes when it opens the app:
///
///     open "AI Usage Store Test.app" --args --phase first --port 51234 --token abc… --lan-url http://…
///
/// `first` is the interactive run. `relaunch` and `update` run by themselves after a relaunch and after
/// the runner installs the next build, and check that what the first run set up still works.
struct LaunchOptions {
    enum Phase: String, Codable {
        case first, relaunch, update
    }

    var phase: Phase = .first
    var port: UInt16?
    var token: String?
    var lanURL: URL?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let phase = value(after: "--phase").flatMap(Phase.init(rawValue:)) { options.phase = phase }
        options.port = value(after: "--port").flatMap { UInt16($0) }
        if let token = value(after: "--token"), token.count >= 16,
           token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            options.token = token
        }
        if let text = value(after: "--lan-url"), let url = URL(string: text), url.scheme == "http", url.host != nil {
            options.lanURL = url
        }
        return options
    }
}
