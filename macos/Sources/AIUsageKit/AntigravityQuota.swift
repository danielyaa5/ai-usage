import Foundation

/// Decode only the quota fields. Account details and model descriptions never enter a widget summary.
public enum AntigravityQuota {
    private struct Reply: Decodable {
        var response: Groups?
        var groups: [Group]?
    }
    private struct Groups: Decodable { var groups: [Group]? }
    private struct Group: Decodable {
        var displayName: String?
        var buckets: [Bucket]?
    }
    private struct Bucket: Decodable {
        var bucketId: String?
        var window: String?
        var remainingFraction: Double?
        var resetTime: String?
    }

    public static func windows(in data: Data, at date: Date) throws -> [LimitWindow] {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let seconds = ISO8601DateFormatter()
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [LimitWindow] = []
        var seen = Set<String>()
        for group in reply.response?.groups ?? reply.groups ?? [] {
            let name = group.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupName = name.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            let short = groupName?.replacingOccurrences(of: #"\s+models$"#, with: "",
                                                       options: [.caseInsensitive, .regularExpression])
            var windows: [LimitWindow] = []
            for bucket in group.buckets ?? [] {
                guard let id = bucket.bucketId, !id.isEmpty, let left = bucket.remainingFraction,
                      left.isFinite, (0...1).contains(left) else { continue }
                let label: String
                switch bucket.window {
                case "5h": label = "5-hour"
                case "weekly": label = "Weekly"
                case let other? where !other.isEmpty: label = String(other.prefix(40))
                default: continue
                }
                let reset = bucket.resetTime.flatMap { fractions.date(from: $0) ?? seconds.date(from: $0) }
                let window = LimitWindow(label: label, group: groupName, groupShort: short,
                                         leftPct: left * 100, resetsAt: reset, observedAt: date)
                if seen.insert(window.id).inserted { windows.append(window) }
            }
            result += windows.filter { $0.label == "5-hour" } + windows.filter { $0.label != "5-hour" }
        }
        return result
    }
}
