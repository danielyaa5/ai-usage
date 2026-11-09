import Foundation

/// Only whole-plan windows from Claude Code's structured usage reply are shared with widgets.
public enum ClaudeQuotaReply {
    public enum Failure: Error { case invalid, unavailable }

    private struct Payload: Decodable {
        let rate_limits_available: Bool
        let rate_limits: Windows?
    }
    private struct Windows: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }
    private struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?

        func reading(minutes: Int, now: Date) -> LimitWindow? {
            let reset = resets_at.flatMap { value in
                let formatter = ISO8601DateFormatter()
                if value.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
                return formatter.date(from: value)
            }
            if let reset, reset <= now { return nil }
            return LocalLimits.window(utilization, minutes: minutes, reset: reset?.timeIntervalSince1970, at: now)
        }
    }
    public static func windows(_ data: Data, now: Date) throws -> [LimitWindow] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw Failure.invalid }
        guard payload.rate_limits_available else { throw Failure.unavailable }
        guard let rows = payload.rate_limits else { throw Failure.invalid }
        return [rows.five_hour?.reading(minutes: 300, now: now), rows.seven_day?.reading(minutes: 10080, now: now)].compactMap { $0 }
    }
}
