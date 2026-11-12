import Darwin
import Foundation
import XCTest
@testable import AIUsageKit

final class SubprocessReaperTests: XCTestCase {
    private func launchShell(_ script: String) throws -> (process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe, identity: SubprocessReaper.Identity?) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let identity = SubprocessReaper.Identity(pid: process.processIdentifier)

        // Wait until the shell prints "ready\n" so signal traps are definitely installed.
        let fd = stdout.fileHandleForReading.fileDescriptor
        XCTAssertEqual(fcntl(fd, F_SETFL, O_NONBLOCK), 0)
        let deadline = Date().addingTimeInterval(3.0)
        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 64)
        while Date() < deadline {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                collected.append(contentsOf: buf.prefix(n))
                if String(decoding: collected, as: UTF8.self).contains("ready") {
                    break
                }
            } else {
                usleep(10_000)
            }
        }
        XCTAssertTrue(String(decoding: collected, as: UTF8.self).contains("ready"), "Child shell did not become ready")
        return (process, stdin, stdout, stderr, identity)
    }

    func testStubbornChildIgnoringSigtermAndHoldingPipeIsKilledPromptly() async throws {
        // Child ignores SIGTERM and spawns a subshell that keeps inherited stdout open briefly.
        let launched = try launchShell("trap '' TERM; (sleep 0.4 >/dev/null 2>&1 &); echo ready; sleep 30")
        let pid = launched.process.processIdentifier
        defer {
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
            SubprocessReaper.closeParentPipes(stdin: launched.stdin, stdout: launched.stdout, stderr: launched.stderr)
        }

        XCTAssertTrue(SubprocessReaper.isAlive(pid: pid, identity: launched.identity))
        let start = ContinuousClock.now
        let outcome = await SubprocessReaper.terminate(
            process: launched.process,
            identity: launched.identity,
            stdin: launched.stdin,
            stdout: launched.stdout,
            stderr: launched.stderr,
            termGraceMs: 80,
            killGraceMs: 400,
            pollIntervalMs: 10
        )
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(outcome, .killed)
        XCTAssertFalse(SubprocessReaper.isAlive(pid: pid, identity: launched.identity))
        XCTAssertLessThan(elapsed, .milliseconds(1500))
    }

    func testPoliteChildExitsOnTermWithoutWaitingForKill() async throws {
        let launched = try launchShell("echo ready; sleep 30")
        let pid = launched.process.processIdentifier
        defer {
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
            SubprocessReaper.closeParentPipes(stdin: launched.stdin, stdout: launched.stdout, stderr: launched.stderr)
        }

        let start = ContinuousClock.now
        let outcome = await SubprocessReaper.terminate(
            process: launched.process,
            identity: launched.identity,
            stdin: launched.stdin,
            stdout: launched.stdout,
            stderr: launched.stderr,
            termGraceMs: 400,
            killGraceMs: 400,
            pollIntervalMs: 10
        )
        let elapsed = ContinuousClock.now - start

        XCTAssertTrue(outcome == .exitedAfterTerm || outcome == .alreadyExited)
        XCTAssertFalse(SubprocessReaper.isAlive(pid: pid, identity: launched.identity))
        XCTAssertLessThan(elapsed, .milliseconds(1000))
    }

    func testReapInBackgroundReturnsImmediatelyAndReapsStubbornChild() async throws {
        let launched = try launchShell("trap '' TERM; echo ready; sleep 30")
        let pid = launched.process.processIdentifier
        defer {
            if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
            SubprocessReaper.closeParentPipes(stdin: launched.stdin, stdout: launched.stdout, stderr: launched.stderr)
        }

        let syncStart = ContinuousClock.now
        SubprocessReaper.reapInBackground(
            process: launched.process,
            identity: launched.identity,
            stdin: launched.stdin,
            stdout: launched.stdout,
            stderr: launched.stderr,
            termGraceMs: 60,
            killGraceMs: 350
        )
        let syncElapsed = ContinuousClock.now - syncStart
        XCTAssertLessThan(syncElapsed, .milliseconds(100), "Synchronous defer reaper must never block")

        let waitDeadline = Date().addingTimeInterval(1.5)
        while Date() < waitDeadline && SubprocessReaper.isAlive(pid: pid, identity: launched.identity) {
            await SubprocessReaper.uncancelledSleep(milliseconds: 15)
        }
        XCTAssertFalse(SubprocessReaper.isAlive(pid: pid, identity: launched.identity))
    }

    func testBoundedTaskTimeoutUnblocksEvenWhenChildTaskIgnoresCancellation() async {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            var timedOutCalled = false
            var releaseContinuation: CheckedContinuation<Void, Never>?

            func markTimedOut() {
                lock.lock()
                timedOutCalled = true
                lock.unlock()
            }

            func readTimedOut() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return timedOutCalled
            }

            func park(_ c: CheckedContinuation<Void, Never>) {
                lock.lock()
                releaseContinuation = c
                lock.unlock()
            }

            func release() {
                lock.lock()
                let c = releaseContinuation
                releaseContinuation = nil
                lock.unlock()
                c?.resume()
            }
        }

        let flag = Flag()
        defer { flag.release() }

        let start = ContinuousClock.now
        do {
            _ = try await BoundedTask.withTimeout(
                seconds: 0.08,
                onTimeout: { flag.markTimedOut() }
            ) {
                // Simulate an un-cancellable continuation trap (e.g., hung IPC / subprocess read).
                await withCheckedContinuation { c in
                    flag.park(c)
                }
                return 42
            }
            XCTFail("Expected BoundedTask.TimeoutError")
        } catch let error as BoundedTask.TimeoutError {
            XCTAssertEqual(error.seconds, 0.08, accuracy: 0.001)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertTrue(flag.readTimedOut())
        XCTAssertLessThan(elapsed, .milliseconds(800))
    }
}
