import Foundation
import Foundation

/// The bundled Codex app-server: where it is, the folder it keeps its own sign-in in, and the
/// locked-down settings it runs with.
enum CodexHelper {
    static let name = "codex-app-server"

    static var executable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: name)
    }

    /// The model list from the same Codex release, so Codex never downloads one.
    static var modelCatalog: URL? {
        Bundle.main.url(forResource: "codex-models", withExtension: "json")
    }

    /// CODEX_HOME: a folder in the app's container, never ~/.codex.
    static var home: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? "AIUsage", isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// The stdio transport is the default; `--strict-config` makes a setting Codex doesn't know an
    /// error instead of something it quietly ignores.
    static let arguments = ["--strict-config"]

    /// config.toml for codex-cli 0.166.0: the ChatGPT sign-in is kept in CODEX_HOME/auth.json (not the
    /// keychain), and plugins, update checks, analytics, feedback, telemetry, history, bundled skills
    /// and the model download are off. (Remote control is off through the environment; its
    /// [features] key does nothing in this release.)
    static func configText(modelCatalog: URL?) -> String {
        var lines = [
            "# Written by AI Usage, which runs Codex only to sign in and read usage limits.",
            "cli_auth_credentials_store = \"file\"",
            "forced_login_method = \"chatgpt\"",
            "check_for_update_on_startup = false",
            // Codex looks for project settings (.codex/config.toml) in every folder from its working
            // folder up to the nearest .git. With no markers it looks only in its working folder (in
            // the container), never in your home folder, where the sandbox would refuse the read and
            // Codex would stop.
            "project_root_markers = []",
        ]
        if let modelCatalog {
            lines.append("model_catalog_json = \(tomlString(modelCatalog.path))")
        }
        lines += [
            "",
            "[analytics]",
            "enabled = false",
            "",
            "[feedback]",
            "enabled = false",
            "",
            "[history]",
            "persistence = \"none\"",
            "",
            "[otel]",
            "exporter = \"none\"",
            "trace_exporter = \"none\"",
            "metrics_exporter = \"none\"",
            "log_user_prompt = false",
            "",
            "[skills.bundled]",
            "enabled = false",
            "",
            "[features]",
            "plugins = false",
            "remote_plugin = false",
            "plugin_discovery_prefetch = false",
            "apps = false",
            "system_proxy_fallback = false",
            "respect_system_proxy = false",
            "shell_snapshot = false",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Makes CODEX_HOME (owner only) and writes config.toml into it.
    static func prepareHome() throws -> URL {
        let home = Self.home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try configText(modelCatalog: modelCatalog)
            .write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return home
    }

    /// Codex gets a small environment of its own: the container's home, its CODEX_HOME, and, when
    /// `proxyPort` is set, every proxy variable pointing at the app's logging proxy.
    static func environment(home: URL, proxyPort: UInt16?) -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "CODEX_HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            // Connections and responses (reqwest), warnings from everything else. No request headers.
            "RUST_LOG": proxyPort == nil ? "off" : "warn,reqwest=debug",
            "NO_COLOR": "1",
            // Codex's own switch for remote control (an internal variable its daemon sets).
            "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED": "1",
        ]
        if let proxyPort {
            let proxy = "http://127.0.0.1:\(proxyPort)"
            for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"] {
                environment[key] = proxy
            }
            environment["NO_PROXY"] = "127.0.0.1,localhost,::1"
            environment["no_proxy"] = "127.0.0.1,localhost,::1"
        }
        return environment
    }

}
