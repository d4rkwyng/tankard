import Foundation
import Testing
@testable import TankardCore

/// The real posix_spawn runner, against /bin/sh and friends.
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test func literalArgvAndCleanEnvironment() async throws {
        // An argument full of shell syntax arrives untouched; nothing leaks
        // from the test process's own environment.
        let r = try await runner.run("/usr/bin/env", [], environment: ["ONLY": "this"])
        #expect(r.exitCode == 0)
        #expect(r.stdoutString == "ONLY=this\n")
        let e = try await runner.run("/bin/echo", ["$HOME; rm -rf / `x` \"q\""], environment: [:])
        #expect(e.stdoutString == "$HOME; rm -rf / `x` \"q\"\n")
    }

    @Test func exitCodeAndStderr() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], environment: [:])
        #expect(r.exitCode == 3)
        #expect(r.stdoutString == "out\n")
        #expect(r.stderrString == "err\n")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        // Well past the 64 KB pipe buffer on both streams at once.
        let r = try await runner.run("/bin/sh", ["-c", "head -c 500000 /dev/zero; head -c 300000 /dev/zero >&2"], environment: [:])
        #expect(r.stdout.count == 500_000)
        #expect(r.stderr.count == 300_000)
    }

    @Test func missingExecutable() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await runner.run("/nonexistent/brew", [], environment: [:])
        }
    }

    @Test func cancellationKillsTheProcessGroup() async throws {
        // The shell starts a grandchild sleep; cancelling must take both down.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid").path
        let runner = ProcessRunner(killGrace: 0.5)
        let task = Task {
            try await runner.run("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile)'; wait"], environment: [:])
        }
        var childPID: pid_t?
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = p
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let child = try #require(childPID)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: ProcessRunnerError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(child, 0) != 0, "grandchild sleep survived cancellation")
    }
}
