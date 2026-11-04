import AppKit

/// Test 3: picking ~/.claude and ~/.codex in a sandboxed Open panel, and read-only, app-scoped
/// security-scoped bookmarks to them that should still work after a relaunch and an update.
///
/// Like the dashboard, it only ever reads: it counts the entries of `projects` (Claude Code) or
/// `sessions` (Codex) and reads the first 64 bytes of one session log to prove file reads work. It
/// never keeps or reports file contents, and never opens Codex's auth.json.
enum FolderKind: String, CaseIterable, Codable {
    case claude
    case codex

    var folderName: String { self == .claude ? ".claude" : ".codex" }
    var logsFolder: String { self == .claude ? "projects" : "sessions" }
    var defaultsKey: String { "bookmark.\(rawValue)" }
}

struct FolderReading {
    var ok: Bool
    var summary: String
    var facts: [String: String]
}

enum FolderAccess {
    /// The user's real home folder. In the sandbox, FileManager's home is the app's container.
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Shows the Open panel at the home folder with hidden files shown. Call on the main thread.
    static func choose(_ kind: FolderKind) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select the \(kind.folderName) folder in your home folder and click Allow. The test only reads it."
        panel.prompt = "Allow"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = realHome
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Saves a read-only, app-scoped bookmark for a folder the user just picked.
    static func saveBookmark(for url: URL, kind: FolderKind) throws -> Int {
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: kind.defaultsKey)
        return data.count
    }

    static func hasBookmark(_ kind: FolderKind) -> Bool {
        UserDefaults.standard.data(forKey: kind.defaultsKey) != nil
    }

    /// Resolves the saved bookmark, starts using it, reads the folder, and stops again.
    static func readSaved(_ kind: FolderKind) -> FolderReading {
        guard let data = UserDefaults.standard.data(forKey: kind.defaultsKey) else {
            return FolderReading(ok: false, summary: "No bookmark saved (pick the folder in the first run).", facts: [:])
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return FolderReading(ok: false, summary: "The bookmark didn't resolve: \(error.localizedDescription)",
                                 facts: ["error": "\((error as NSError).domain) \((error as NSError).code)"])
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        var reading = inspect(url, kind: kind)
        reading.facts["bookmarkStale"] = stale ? "yes" : "no"
        reading.facts["startAccessing"] = started ? "yes" : "no"
        reading.facts["resolvedName"] = url.lastPathComponent
        if stale, started, (try? saveBookmark(for: url, kind: kind)) != nil {
            reading.facts["bookmarkRenewed"] = "yes"
        }
        if !started {
            reading.ok = false
            reading.summary = "startAccessingSecurityScopedResource() returned false. " + reading.summary
        }
        return reading
    }

    /// Counts the entries of the logs folder and reads 64 bytes of one session log.
    static func inspect(_ root: URL, kind: FolderKind) -> FolderReading {
        let manager = FileManager.default
        let logs = root.appendingPathComponent(kind.logsFolder, isDirectory: true)
        var facts: [String: String] = ["folder": root.lastPathComponent]
        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            let ns = error as NSError
            facts["error"] = "\(ns.domain) \(ns.code)"
            return FolderReading(ok: false, summary: "Couldn't list \(kind.folderName)/\(kind.logsFolder): \(ns.localizedDescription)",
                                 facts: facts)
        }
        facts["entries"] = "\(entries.count)"
        var sample: URL?
        var looked = 0
        if let walker = manager.enumerator(at: logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let file as URL in walker {
                looked += 1
                if file.pathExtension == "jsonl" {
                    sample = file
                    break
                }
                if looked > 20_000 { break }
            }
        }
        guard let sample else {
            return FolderReading(ok: true, summary: "Listed \(entries.count) entries in \(kind.logsFolder); found no session log to read.",
                                 facts: facts)
        }
        do {
            let handle = try FileHandle(forReadingFrom: sample)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 64) ?? Data()
            facts["sampleBytesRead"] = "\(bytes.count)"
            return FolderReading(ok: true, summary: "Listed \(entries.count) entries in \(kind.logsFolder) and read a session log.",
                                 facts: facts)
        } catch {
            let ns = error as NSError
            facts["error"] = "\(ns.domain) \(ns.code)"
            return FolderReading(ok: false, summary: "Listed \(entries.count) entries but couldn't read a session log: \(ns.localizedDescription)",
                                 facts: facts)
        }
    }
}
