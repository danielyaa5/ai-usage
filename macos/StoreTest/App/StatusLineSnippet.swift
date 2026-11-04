import Foundation

/// Builds the Claude Code `statusLine.command` that hands only `rate_limits` to the app's listener on
/// 127.0.0.1 and then runs the user's own status line command with Claude Code's full input, so their
/// status line looks the same.
///
/// Claude Code runs the command with /bin/sh outside its own sandbox, writes one line of JSON to its
/// stdin, and waits for it to exit. The snippet reads that line once, sends `{"rate_limits":…}` in the
/// background with every file descriptor redirected (so the status line never waits for it), and
/// pipes the line on. It uses /usr/bin/jq when macOS has it (macOS 15 and later) and a sed expression
/// otherwise, and /usr/bin/curl with a 2-second limit, no proxy and no ~/.curlrc.
enum StatusLineSnippet {
    /// Marks a command this builder made, so building again wraps the user's command, not the snippet.
    static let marker = ": ai-usage-v1;"
    static let jqFilter = "select(.rate_limits)|{rate_limits}"
    static let sedScript = #"s/.*"rate_limits":([{]([^{}]|[{][^{}]*[}])*[}]).*/{"rate_limits":\1}/p"#
    /// The user's command runs in a /bin/sh of its own, as one single-quoted argument, the way Claude
    /// Code runs a status line command. So nothing in it (a lone comment, a heredoc closed by the end
    /// of the text, a trailing backslash) can change how the rest of the snippet parses.
    static let userSeparator = #" printf '%s\n' "$_aiu" | /bin/sh -c '"#

    /// The command for settings.json; empty when the port or token is unusable.
    static func command(port: Int, token: String, userCommand: String?) -> String {
        guard (1...65535).contains(port),
              token.range(of: #"^[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil else { return "" }
        let parts: [String] = [
            marker, " _aiu=$(/bin/cat); ",
            "( if [ -x /usr/bin/jq ]; then r=$(printf '%s\\n' \"$_aiu\" | /usr/bin/jq -c '", jqFilter, "'); ",
            "else r=$(printf '%s\\n' \"$_aiu\" | LC_ALL=C /usr/bin/sed -nE '", sedScript, "'); fi; ",
            "[ -n \"$r\" ] && printf '%s' \"$r\" | /usr/bin/curl -q -s -m 2 --noproxy '*' -o /dev/null ",
            "-H 'Content-Type: application/json' -H 'X-AI-Usage-Token: ", token, "' --data-binary @- ",
            "http://127.0.0.1:", String(port), "/claude-status ) </dev/null >/dev/null 2>&1 &",
        ]
        var command = parts.joined()
        let user = unwrap(userCommand ?? "")
        if !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += userSeparator + user.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        return command
    }

    /// The user's own command from a command this builder made; any other command unchanged.
    static func unwrap(_ command: String) -> String {
        guard command.hasPrefix(marker) else { return command }
        guard let range = command.range(of: userSeparator) else { return "" }
        var quoted = String(command[range.upperBound...])
        if quoted.hasSuffix("'") { quoted.removeLast() }
        return quoted.replacingOccurrences(of: #"'\''"#, with: "'")
    }
}
