import Foundation

/// Keeps personal details and secrets out of everything the test records: it drops log lines that
/// mention credentials, cuts query strings off URLs (OAuth codes and state live there), leaves out
/// the HTTP bodies Codex quotes in its errors, and masks email addresses, account and user IDs,
/// addresses other than loopback, and long token-like strings. JSON replies lose their identifying keys.
enum Redact {
    private static let droppedWords = [
        "authorization", "bearer", "cookie", "access_token", "refresh_token", "id_token", "api_key",
        "apikey", "password", "secret", "code_verifier", "client_secret", "x-api-key",
    ]

    private static let identifyingKeys: Set<String> = [
        "email", "accountid", "account_id", "userid", "user_id", "chatgptaccountid", "chatgpt_account_id",
        "chatgptuserid", "chatgpt_user_id", "organizationid", "organization_id", "orgid", "workspaceid",
        "workspace_id", "phone",
    ]

    private static let patterns: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            (#"(https?://[^\s?#"'<>]+)[?#][^\s"'<>]*"#, "$1?…"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+){0,2}"#, "<jwt>"),
            (#"[A-Za-z0-9_\-]{40,}"#, "<long>"),
            (#"(?i)"(email|account_?id|user_?id|chatgpt_?account_?id|chatgpt_?user_?id|organization_?id|org_?id|workspace_?id|phone)"\s*:\s*"[^"]*""#,
             #""$1":"<removed>""#),
            (#"(?i)\b[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#, "<id>"),
            (#"\b(user|org|proj|acct|account)-[A-Za-z0-9]{8,}\b"#, "<id>"),
            (#"\b(?!127\.)(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\b"#, "<ip>"),
            (#"\b(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "<ip>"),
        ]
        return rules.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// A log line made safe to keep, or nil when it should be dropped.
    static func line(_ text: String, limit: Int = 400) -> String? {
        let lower = text.lowercased()
        if droppedWords.contains(where: { lower.contains($0) }) { return nil }
        return String(scrub(text).prefix(limit))
    }

    /// An error from Codex made safe to keep, and short: Codex's errors can quote a whole HTTP reply.
    static func error(_ error: Error, limit: Int = 300) -> String {
        String(scrub("\(error)").prefix(limit))
    }

    static func scrub(_ text: String) -> String {
        var result = text
        if let body = result.range(of: "body=") {
            result = String(result[..<body.lowerBound]) + "body left out"
        }
        for (expression, template) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// A JSON value without identifying keys, with strings scrubbed.
    static func json(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var kept: [String: Any] = [:]
            for (key, inner) in dictionary {
                if identifyingKeys.contains(key.lowercased()) {
                    kept[key] = "<removed>"
                } else {
                    kept[key] = json(inner)
                }
            }
            return kept
        case let array as [Any]:
            return array.map { json($0) }
        case let string as String:
            return scrub(string)
        default:
            return value
        }
    }

    /// Compact JSON text of a redacted value, cut to `limit` characters.
    static func jsonText(_ value: Any, limit: Int = 2000) -> String {
        let cleaned = json(value)
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) else {
            return String(String(describing: cleaned).prefix(limit))
        }
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }
}
