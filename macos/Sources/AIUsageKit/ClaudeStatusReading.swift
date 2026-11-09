import Foundation

/// The only fields of Claude Code's status-line input that can reach the local receiver.
public enum ClaudeStatusReading {
    private struct Input: Codable {
        var rate_limits: Limits
    }
    private struct Limits: Codable {
        var five_hour: Window?
        var seven_day: Window?

        enum CodingKeys: String, CodingKey { case five_hour, seven_day }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            five_hour = try? fields.decode(Window.self, forKey: .five_hour)
            seven_day = try? fields.decode(Window.self, forKey: .seven_day)
        }
    }
    private struct Window: Codable {
        var used_percentage: Double
        var resets_at: Double?

        var valid: Bool { used_percentage.isFinite && (0...100).contains(used_percentage) }
    }

    public static func payload(from data: Data) -> Data? {
        guard var input = try? JSONDecoder().decode(Input.self, from: data) else { return nil }
        if input.rate_limits.five_hour?.valid != true { input.rate_limits.five_hour = nil }
        if input.rate_limits.seven_day?.valid != true { input.rate_limits.seven_day = nil }
        guard input.rate_limits.five_hour != nil || input.rate_limits.seven_day != nil else { return nil }
        return try? JSONEncoder().encode(input)
    }

    public static let flag = "--report-claude-limits"

    public static func setupRequest(executable: URL) -> String {
        let path = "'" + executable.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let reporter = path + " " + flag
        return "/statusline Connect AI Usage to my Claude Code user status line. If I have no custom command, use \(reporter). If I already have one, pipe \(reporter) --pass-through into my existing command so it receives the same input and keeps its display. Keep my other status-line settings and include this reporter only once."
    }
}
