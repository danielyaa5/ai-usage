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
        let model_scoped: [ModelScoped]?
    }
    private struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?

        func reading(minutes: Int, group: String? = nil, groupShort: String? = nil, now: Date) -> LimitWindow? {
            guard let used = utilization, used.isFinite, (0...100).contains(used) else { return nil }
            let reset = resets_at.flatMap { value in
                let formatter = ISO8601DateFormatter()
                if value.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
                return formatter.date(from: value)
            }
            if let reset, reset <= now { return nil }
            let label: String
            switch minutes {
            case 300: label = "5-hour"
            case 10080: label = "Weekly"
            case 1440: label = "Daily"
            default: label = "\(minutes) min"
            }
            return LimitWindow(label: label, group: group, groupShort: groupShort, leftPct: 100 - used,
                               resetsAt: reset, observedAt: now)
        }
    }
    private struct ModelScoped: Decodable {
        let display_name: String?
        let utilization: Double?
        let resets_at: String?

        func reading(now: Date) -> LimitWindow? {
            guard let name = display_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            guard let used = utilization, used.isFinite, (0...100).contains(used) else { return nil }
            let reset = resets_at.flatMap { value in
                let formatter = ISO8601DateFormatter()
                if value.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
                return formatter.date(from: value)
            }
            if let reset, reset <= now { return nil }
            return LimitWindow(label: "Weekly", group: "Claude Models", groupShort: name,
                               leftPct: 100 - used, resetsAt: reset, observedAt: now)
        }
    }
    public static func windows(_ data: Data, now: Date) throws -> [LimitWindow] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw Failure.invalid }
        guard payload.rate_limits_available else { throw Failure.unavailable }
        guard let rows = payload.rate_limits else { throw Failure.invalid }
        let modelWindows = (rows.model_scoped ?? []).compactMap { $0.reading(now: now) }
        let hasGroups = !modelWindows.isEmpty
        let group = hasGroups ? "Claude Models" : nil
        let groupShort = hasGroups ? "All models" : nil
        let general = [
            rows.five_hour?.reading(minutes: 300, group: group, groupShort: groupShort, now: now),
            rows.seven_day?.reading(minutes: 10080, group: group, groupShort: groupShort, now: now)
        ].compactMap { $0 }
        return general + modelWindows
    }
}
