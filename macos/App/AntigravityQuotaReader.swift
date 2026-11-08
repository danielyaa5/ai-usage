import AIUsageKit
import Darwin
import Foundation
import Security

private struct GoogleExecutable: Equatable, Sendable {
    let path: URL
    let codeHash: Data
    // Cache only a public certificate, keyed by the signature of this build of Antigravity.
    private static let certificates = NSCache<NSData, NSData>()

    func contains(_ leaf: SecCertificate) -> Bool {
        let der = SecCertificateCopyData(leaf) as Data
        if let cached = Self.certificates.object(forKey: codeHash as NSData), cached as Data == der { return true }
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = Data(("-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----").utf8)
        guard let image = try? Data(contentsOf: path, options: .alwaysMapped), image.range(of: pem) != nil else { return false }
        Self.certificates.setObject(der as NSData, forKey: codeHash as NSData)
        return true
    }
}

enum AntigravityQuotaError: String, Error {
    case notRunning = "Open Antigravity on this Mac and sign in. AI Usage will check again."
    case connection = "Couldn’t verify Antigravity’s connection. Reopen or update Antigravity, then refresh."
    case unavailable = "Antigravity didn’t return quota. Check that you’re signed in, then refresh."
    case permission = "Couldn’t read the Antigravity folder. Disconnect quota and connect it again."
}

/// Antigravity publishes one private hub_<httpPort>.json per local daemon. The app only uses
/// the TLS port of a live, Google-signed server whose process token matches its registration.
private struct AntigravityHub: Decodable, Equatable, Sendable {
    let pid: Int32
    let httpPort: UInt16
    let httpsPort: UInt16
    let csrfToken: String

    static func read(name: String, directory: URL) -> Self? {
        guard name.hasPrefix("hub_"), name.hasSuffix(".json"),
              let port = UInt16(name.dropFirst(4).dropLast(5)), name == "hub_\(port).json" else { return nil }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        defer { close(dir) }
        var st = stat()
        guard fstat(dir, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { return nil }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 4096,
              let data = try? file.read(upToCount: 4097), data.count <= 4096,
              let hub = try? JSONDecoder().decode(Self.self, from: data),
              hub.pid > 0, hub.httpPort == port, hub.httpPort != 0, hub.httpsPort != 0,
              hub.httpsPort != hub.httpPort, (16...256).contains(hub.csrfToken.utf8.count),
              hub.csrfToken.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(hub.pid, PROC_PIDTBSDINFO, 0, &process, size) == size, process.pbi_uid == getuid(),
              st.st_mtimespec.tv_sec >= Int(process.pbi_start_tvsec) else { return nil }
        return hub
    }

    /// Read only this signed process's arguments, never the environment following argv.
    func matchesArguments() -> Bool {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4, length <= 2_097_152 else { return false }
        var bytes = [UInt8](repeating: 0, count: length)
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0, length > 4 else { return false }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 8192, let nul = bytes[4..<length].firstIndex(of: 0) else { return false }
        var index = nul
        while index < length && bytes[index] == 0 { index += 1 }
        // A zero port asks the OS to allocate one; the private hub file publishes that
        // resulting port. If Google supplied an explicit port, it must match as well.
        var pending: String?
        var tokenMatches = false
        let fields = ["--csrf_token", "--https_server_port", "--http_server_port"]
        for _ in 0..<argc {
            guard index < length, let end = bytes[index..<length].firstIndex(of: 0) else { return false }
            let arg = bytes[index..<end]
            index = end + 1
            let field: String
            let value: ArraySlice<UInt8>
            if let wanted = pending {
                field = wanted; value = arg; pending = nil
            } else {
                guard arg.starts(with: [45, 45]) else { continue }
                let sep = arg.firstIndex(of: 61) ?? end
                let name = String(decoding: arg[..<sep], as: UTF8.self)
                guard fields.contains(name) else { continue }
                if sep == end { pending = name; continue }
                field = name; value = arg[(sep + 1)..<end]
            }
            if field == "--csrf_token" {
                guard value.elementsEqual(csrfToken.utf8) else { return false }
                tokenMatches = true
            } else {
                guard let port = UInt16(String(decoding: value, as: UTF8.self)),
                      port == 0 || port == (field == "--https_server_port" ? httpsPort : httpPort) else { return false }
            }
        }
        return tokenMatches && pending == nil
    }

    func signedExecutable() -> GoogleExecutable? {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let flags = SecCSFlags(rawValue: 0)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var path: CFURL?
        var signingInfo: CFDictionary?
        let rule = #"anchor apple generic and identifier "language_server" and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        guard SecRequirementCreateWithString(rule as CFString, flags, &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attrs, flags, &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, flags, requirement) == errSecSuccess,
              SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, flags, &path) == errSecSuccess, let path,
              SecCodeCopySigningInformation(staticCode, flags, &signingInfo) == errSecSuccess,
              let hash = (signingInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        return GoogleExecutable(path: path as URL, codeHash: hash)
    }
}

private final class AntigravityPeer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let directory: URL
    let hub: AntigravityHub
    private let executable: GoogleExecutable

    init(directory: URL, hub: AntigravityHub, executable: GoogleExecutable) {
        self.directory = directory
        self.hub = hub
        self.executable = executable
    }

    // The daemon bundles its localhost TLS certificate in its signed executable. Check the
    // peer against that certificate and recheck the live registration during the handshake.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", space.port == Int(hub.httpsPort), let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              AntigravityHub.read(name: "hub_\(hub.httpPort).json", directory: directory) == hub,
              hub.signedExecutable() == executable, hub.matchesArguments(), executable.contains(leaf) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // The pinned local leaf has no web-server EKU. It is trusted only here, only
        // for this registered loopback peer, and never as a general HTTPS authority.
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AntigravityQuotaReader {
    static var registrationDirectory: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
    }

    static func directory(in selected: URL) -> URL? {
        let directory: URL
        switch selected.lastPathComponent {
        case "daemon": directory = selected
        case "antigravity": directory = selected.appendingPathComponent("daemon", isDirectory: true)
        default: directory = selected.appendingPathComponent("antigravity/daemon", isDirectory: true)
        }
        guard let expected = registrationDirectory,
              directory.resolvingSymlinksInPath().standardizedFileURL.path ==
                expected.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return directory
    }

    static func read(directory: URL) async throws -> [LimitWindow] {
        try Task.checkCancellation()
        guard Self.directory(in: directory) != nil else { throw AntigravityQuotaError.permission }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { throw AntigravityQuotaError.notRunning }
        catch { throw AntigravityQuotaError.permission }
        let registrations = names.compactMap { AntigravityHub.read(name: $0, directory: directory) }
        let peers = registrations.compactMap { hub -> AntigravityPeer? in
            guard let path = hub.signedExecutable(), hub.matchesArguments() else { return nil }
            return AntigravityPeer(directory: directory, hub: hub, executable: path)
        }
        guard !peers.isEmpty else { throw AntigravityQuotaError.notRunning }
        guard peers.count == 1, let peer = peers.first,
              registrations.filter({ $0.httpsPort == peer.hub.httpsPort }).count == 1 else {
            throw AntigravityQuotaError.connection
        }
        let url = URL(string: "https://127.0.0.1:\(peer.hub.httpsPort)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")!
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                            "ExceptionsList": ["127.0.0.1"], "ExcludeSimpleHostnames": 1,
                                            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: peer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(peer.hub.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: peer)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AntigravityQuotaError.unavailable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { throw AntigravityQuotaError.unavailable }
                data.append(byte)
            }
            let windows = try AntigravityQuota.windows(in: data, at: Date())
            guard !windows.isEmpty else { throw AntigravityQuotaError.unavailable }
            return windows
        } catch is CancellationError { throw CancellationError() }
        catch let problem as AntigravityQuotaError { throw problem }
        catch { throw AntigravityQuotaError.connection }
    }
}
