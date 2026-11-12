import Darwin
import Foundation

/// Bounded, runloop-free subprocess liveness checks, pipe cleanup, and SIGTERM -> SIGKILL reaping.
///
/// `Foundation.Process.waitUntilExit()` spins an internal `CFRunLoop` mode that can block forever
/// in `mach_msg2_trap` when called from Swift Concurrency cooperative threads. `SubprocessReaper`
/// queries the kernel process table directly via `proc_pidinfo` and uses GCD timers so teardown
/// never depends on a thread's `CFRunLoop` or stalls on `Task` cancellation.
public enum SubprocessReaper {
    public enum Outcome: Equatable, Sendable {
        case notStarted
        case alreadyExited
        case exitedAfterTerm
        case killed
        case stillRunning
    }

    public struct Identity: Equatable, Sendable {
        public let pid: pid_t
        public let startSec: UInt64
        public let startUsec: UInt64

        public init?(pid: pid_t) {
            guard pid > 0, let info = Self.bsdInfo(pid: pid) else { return nil }
            self.pid = pid
            self.startSec = info.pbi_start_tvsec
            self.startUsec = info.pbi_start_tvusec
        }

        fileprivate static func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else { return nil }
            return info
        }
    }

    private static let zombieStatus: UInt32 = 5 // SZOMB in <sys/proc.h>

    /// Returns true while `pid` is a live, non-zombie child process matching `identity` (when supplied).
    public static func isAlive(pid: pid_t, identity: Identity? = nil) -> Bool {
        guard pid > 0 else { return false }
        guard let info = Identity.bsdInfo(pid: pid) else {
            return errno == EPERM
        }
        if info.pbi_status == zombieStatus {
            return false
        }
        if let identity {
            return info.pbi_start_tvsec == identity.startSec
                && info.pbi_start_tvusec == identity.startUsec
        }
        return info.pbi_ppid == UInt32(getpid())
    }

    public static func isProcessRunning(_ process: Process, identity: Identity? = nil) -> Bool {
        let pid = process.processIdentifier
        guard pid > 0 else { return false }
        return process.isRunning && isAlive(pid: pid, identity: identity)
    }

    /// Closes only the parent-owned ends of pipes handed to `Process` and clears readability handlers.
    public static func closeParentPipes(stdin: Pipe? = nil, stdout: Pipe? = nil, stderr: Pipe? = nil) {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.fileHandleForWriting.close()
        try? stdout?.fileHandleForReading.close()
        try? stderr?.fileHandleForReading.close()
    }

    /// Sleeps on a GCD queue without spinning a `CFRunLoop` or short-circuiting when `Task.isCancelled` is true.
    public static func uncancelledSleep(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(milliseconds)
            ) {
                continuation.resume()
            }
        }
    }

    private static func matchesTarget(_ info: proc_bsdinfo, identity: Identity?) -> Bool {
        if let identity {
            return info.pbi_start_tvsec == identity.startSec
                && info.pbi_start_tvusec == identity.startUsec
        }
        return info.pbi_ppid == UInt32(getpid())
    }

    private static func reapLingeringZombie(pid: pid_t, identity: Identity?) async {
        guard let info = Identity.bsdInfo(pid: pid),
              info.pbi_status == zombieStatus,
              matchesTarget(info, identity: identity) else { return }
        // Give Foundation's EVFILT_PROC handler first chance to reap cleanly.
        await uncancelledSleep(milliseconds: 20)
        guard let latest = Identity.bsdInfo(pid: pid),
              latest.pbi_status == zombieStatus,
              matchesTarget(latest, identity: identity) else { return }
        var status: Int32 = 0
        _ = Darwin.waitpid(pid, &status, WNOHANG)
    }

    /// Closes parent pipe handles, sends `SIGTERM`, polls kernel liveness, escalates to `SIGKILL`
    /// after `termGraceMs`, and returns promptly without calling `Process.waitUntilExit()`.
    @discardableResult
    public static func terminate(
        process: Process,
        identity: Identity? = nil,
        stdin: Pipe? = nil,
        stdout: Pipe? = nil,
        stderr: Pipe? = nil,
        termGraceMs: Int = 150,
        killGraceMs: Int = 250,
        pollIntervalMs: Int = 15
    ) async -> Outcome {
        closeParentPipes(stdin: stdin, stdout: stdout, stderr: stderr)
        let pid = process.processIdentifier
        guard pid > 0 else { return .notStarted }
        let resolvedIdentity = identity ?? Identity(pid: pid)
        let step = max(5, pollIntervalMs)

        if !isAlive(pid: pid, identity: resolvedIdentity) {
            await reapLingeringZombie(pid: pid, identity: resolvedIdentity)
            return .alreadyExited
        }

        _ = Darwin.kill(pid, SIGTERM)
        var elapsed = 0
        while elapsed < termGraceMs {
            if !isAlive(pid: pid, identity: resolvedIdentity) {
                await reapLingeringZombie(pid: pid, identity: resolvedIdentity)
                return .exitedAfterTerm
            }
            await uncancelledSleep(milliseconds: step)
            elapsed += step
        }
        if !isAlive(pid: pid, identity: resolvedIdentity) {
            await reapLingeringZombie(pid: pid, identity: resolvedIdentity)
            return .exitedAfterTerm
        }

        _ = Darwin.kill(pid, SIGKILL)
        elapsed = 0
        while elapsed < killGraceMs {
            if !isAlive(pid: pid, identity: resolvedIdentity) {
                await reapLingeringZombie(pid: pid, identity: resolvedIdentity)
                return .killed
            }
            await uncancelledSleep(milliseconds: step)
            elapsed += step
        }
        if !isAlive(pid: pid, identity: resolvedIdentity) {
            await reapLingeringZombie(pid: pid, identity: resolvedIdentity)
            return .killed
        }
        return .stillRunning
    }

    /// Synchronous teardown for `defer` blocks: closes parent pipe handles immediately and runs
    /// bounded `SIGTERM -> SIGKILL` reaping in a detached task so the caller never blocks.
    public static func reapInBackground(
        process: Process,
        identity: Identity? = nil,
        stdin: Pipe? = nil,
        stdout: Pipe? = nil,
        stderr: Pipe? = nil,
        termGraceMs: Int = 150,
        killGraceMs: Int = 250
    ) {
        closeParentPipes(stdin: stdin, stdout: stdout, stderr: stderr)
        let pid = process.processIdentifier
        let resolvedIdentity = identity ?? Identity(pid: pid)
        guard pid > 0, isAlive(pid: pid, identity: resolvedIdentity) else { return }
        Task.detached(priority: .utility) {
            _ = await terminate(
                process: process,
                identity: resolvedIdentity,
                termGraceMs: termGraceMs,
                killGraceMs: killGraceMs
            )
        }
    }
}

/// Runs an async operation with a hard wall-clock deadline that returns promptly on timeout even if
/// the underlying work ignores cooperative cancellation.
public enum BoundedTask {
    public struct TimeoutError: Error, Equatable, Sendable {
        public let seconds: Double

        public init(seconds: Double) {
            self.seconds = seconds
        }
    }

    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var earlyResult: Result<T, Error>?
        private var continuation: CheckedContinuation<Result<T, Error>, Never>?

        @discardableResult
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return false
            }
            settled = true
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: result)
                return true
            }
            earlyResult = result
            lock.unlock()
            return true
        }

        func wait() async -> Result<T, Error> {
            await withCheckedContinuation { c in
                lock.lock()
                if let result = earlyResult {
                    earlyResult = nil
                    lock.unlock()
                    c.resume(returning: result)
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }
    }

    public static func withTimeout<T: Sendable>(
        seconds: Double,
        onTimeout: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        let work = Task {
            do {
                let value = try await operation()
                _ = gate.finish(.success(value))
            } catch {
                _ = gate.finish(.failure(error))
            }
        }
        let timerItem = DispatchWorkItem {
            if gate.finish(.failure(TimeoutError(seconds: seconds))) {
                work.cancel()
                onTimeout?()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0.001, seconds),
            execute: timerItem
        )

        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            if gate.finish(.failure(CancellationError())) {
                timerItem.cancel()
                work.cancel()
            }
        }
        timerItem.cancel()
        if case .failure = result {
            work.cancel()
        }
        return try result.get()
    }
}
