#if CLAUDE_QUOTA_TEST
import AIUsageKit
import AppKit

@MainActor
final class ClaudeTestQuota: ObservableObject {
    enum State: Equatable {
        case off, checking, current, signingIn, needsSignIn, unavailable, failed
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var state: State
    @Published private(set) var windows: [LimitWindow]
    private let defaults: UserDefaults
    private var privateProfile: Bool
    private var generation = 0
    private var reading: Task<Void, Never>?
    private var login: Task<Void, Never>?
    private var loginOnMissing = false
    private var lastCheck: Date?
    private var signInIssue: String?
    var changed: ((Bool) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let previouslyEnabled = defaults.bool(forKey: "claudeLiveEnabled")
        enabled = previouslyEnabled
        state = previouslyEnabled ? .checking : .off
        privateProfile = defaults.bool(forKey: "claudeLivePrivateProfile") ||
            Bundle.main.bundleIdentifier?.contains(".claudefreshtest.") == true
        windows = previouslyEnabled ? defaults.data(forKey: "claudeLiveWindows").flatMap {
            try? JSONDecoder().decode([LimitWindow].self, from: $0)
        } ?? [] : []
    }

    var status: String {
        switch state {
        case .off: return "Check the five-hour and weekly limits Claude reports, even when Claude Desktop is closed."
        case .checking: return "Checking your Claude quota…"
        case .signingIn: return "Finish signing in with Claude in your browser. Your quota will appear here."
        case .needsSignIn: return signInIssue ?? "Sign in with Claude to read your plan limits."
        case .unavailable: return "Claude didn’t provide plan limits. Check your plan or try again later."
        case .failed: return "Couldn’t update Claude quota. Check your connection and try again."
        case .current: return windows.isEmpty ? "Claude didn’t report an active five-hour or weekly window." : "Connected to Claude"
        }
    }

    var label: String {
        switch state {
        case .off: return "Not connected"
        case .checking: return "Checking Claude"
        case .signingIn, .needsSignIn: return "Sign-in needed"
        case .unavailable, .failed: return "Needs attention"
        case .current: return "Automatic quota"
        }
    }

    func connect() {
        guard !enabled else { return }
        enabled = true
        defaults.set(true, forKey: "claudeLiveEnabled")
        loginOnMissing = true
        signInIssue = nil
        state = .checking
        changed?(true)
    }

    func disconnect() {
        suspend()
        enabled = false
        defaults.removeObject(forKey: "claudeLiveEnabled")
        save([])
        state = .off
        changed?(true)
    }

    func suspend() {
        generation += 1
        reading?.cancel()
        login?.cancel()
        reading = nil
        login = nil
        ClaudeQuotaProcess.stopAll()
        lastCheck = nil
        loginOnMissing = false
        if enabled { state = .checking }
    }

    func cancelStuckRead() {
        guard reading != nil else { return }
        generation += 1
        reading?.cancel()
        reading = nil
        ClaudeQuotaProcess.stopAll()
        if enabled && login == nil { state = .failed }
    }

    func refreshNow() {
        guard login == nil, reading == nil else { return }
        lastCheck = nil
        changed?(false)
    }

    func checkIfDue() async {
        if let reading { await reading.value; return }
        guard enabled, login == nil, lastCheck.map({ Date().timeIntervalSince($0) >= 240 }) ?? true else { return }
        lastCheck = Date()
        let version = generation
        let task = Task { await self.check(version: version) }
        reading = task
        await task.value
        if version == generation { reading = nil }
    }

    private func check(version: Int) async {
        do {
            let values = try await ClaudeQuotaProcess.read(privateProfile: privateProfile)
            guard version == generation, enabled else { return }
            save(values)
            state = .current
        } catch ClaudeQuotaReply.Failure.unavailable {
            let signedIn = try? await ClaudeQuotaProcess.signedIn(privateProfile: privateProfile)
            guard version == generation, enabled else { return }
            if signedIn == false {
                save([])
                state = .needsSignIn
                if loginOnMissing { signIn() }
            } else {
                state = signedIn == true ? .unavailable : .failed
            }
        } catch {
            guard version == generation, enabled else { return }
            state = .failed
        }
        loginOnMissing = false
    }

    func signIn() {
        guard enabled, login == nil else { return }
        generation += 1
        reading?.cancel()
        reading = nil
        loginOnMissing = false
        signInIssue = nil
        privateProfile = true
        defaults.set(true, forKey: "claudeLivePrivateProfile")
        save([])
        state = .signingIn
        let version = generation
        login = Task {
            do {
                try await ClaudeQuotaProcess.login()
                guard version == generation, enabled else { return }
                login = nil
                lastCheck = nil
                state = .checking
                changed?(true)
            } catch {
                guard version == generation, enabled else { return }
                login = nil
                signInIssue = "Sign-in didn’t finish. Open Claude sign-in again to connect."
                state = .needsSignIn
                changed?(false)
            }
        }
        changed?(true)
    }

    func cancelSignIn() {
        guard login != nil else { return }
        suspend()
        signInIssue = "Sign-in canceled. You can sign in again when you’re ready."
        state = .needsSignIn
        lastCheck = Date()
        changed?(false)
    }

    private func save(_ values: [LimitWindow]) {
        if windows != values { windows = values }
        if values.isEmpty { defaults.removeObject(forKey: "claudeLiveWindows") }
        else { defaults.set(try? JSONEncoder().encode(values), forKey: "claudeLiveWindows") }
    }
}
#endif
