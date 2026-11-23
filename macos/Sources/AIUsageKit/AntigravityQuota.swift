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

    /// Check a language server's argv (program path first) against its private hub registration.
    /// Builds before 2.34 pass the CSRF token on the command line, and then it must match. From
    /// 2.34 the server makes its own token and publishes it only in the owner-only hub file, so a
    /// missing token flag is accepted. The reader still requires that file's owner, mode and
    /// timing, Google's signature on the process, and the TLS certificate built into it.
    /// A port of 0 asks the OS to pick one, which the hub file then publishes; an explicit
    /// port must match the registration.
    public static func launchArgumentsMatch<C: Collection>(_ arguments: [C], csrfToken: String,
                                                           httpsPort: UInt16, httpPort: UInt16) -> Bool
    where C.Element == UInt8 {
        let fields = ["--csrf_token", "--https_server_port", "--http_server_port"]
        func accepts<V: Sequence>(_ field: String, _ value: V) -> Bool where V.Element == UInt8 {
            if field == "--csrf_token" { return value.elementsEqual(csrfToken.utf8) }
            guard let port = UInt16(String(decoding: Array(value), as: UTF8.self)) else { return false }
            return port == 0 || port == (field == "--https_server_port" ? httpsPort : httpPort)
        }
        var pending: String?
        for arg in arguments {
            if let field = pending {
                guard accepts(field, arg) else { return false }
                pending = nil
                continue
            }
            guard arg.starts(with: [45, 45]) else { continue }
            let sep = arg.firstIndex(of: 61) ?? arg.endIndex
            let name = String(decoding: arg[..<sep], as: UTF8.self)
            guard fields.contains(name) else { continue }
            if sep == arg.endIndex { pending = name; continue }
            guard accepts(name, arg[arg.index(after: sep)...]) else { return false }
        }
        return pending == nil
    }
}
