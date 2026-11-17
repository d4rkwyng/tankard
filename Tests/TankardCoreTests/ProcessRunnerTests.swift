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

    /// 0.6.1: cancelled before the child exists (Stop right after Scan
    /// now): the child is stopped as soon as it starts, not left running.
    @Test func cancellationBeforeSpawnStillStopsTheChild() async throws {
        let runner = ProcessRunner(killGrace: 0.5)
        let start = ContinuousClock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run("/bin/sleep", ["30"], environment: [:])
        }
        await #expect(throws: ProcessRunnerError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

/// The streaming runner used for brew update / upgrade.
struct StreamingProcessRunnerTests {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var chunks = 0
        func add(_ d: Data) { lock.withLock { data.append(d); chunks += 1 } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    @Test func mergesStdoutAndStderrInOrder() async throws {
        let sink = Sink()
        let code = try await StreamingProcessRunner().stream(
            "/bin/sh", ["-c", "echo one; echo two >&2; sleep 0.05; printf 'three\\r'; exit 4"],
            environment: ["ONLY": "x"]) { sink.add($0) }
        #expect(code == 4)
        #expect(sink.text == "one\ntwo\nthree\r")
    }

    @Test func outputArrivesBeforeExit() async throws {
        // A chunk must be delivered while the process is still running.
        let sink = Sink()
        let task = Task {
            try await StreamingProcessRunner().stream("/bin/sh", ["-c", "echo early; sleep 2"], environment: [:]) { sink.add($0) }
        }
        var sawEarly = false
        for _ in 0..<100 {
            if sink.text == "early\n" { sawEarly = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawEarly)
        task.cancel()
        _ = try? await task.value
    }

    @Test func cleanEnvironment() async throws {
        let sink = Sink()
        _ = try await StreamingProcessRunner().stream("/usr/bin/env", [], environment: ["ONLY": "this"]) { sink.add($0) }
        #expect(sink.text == "ONLY=this\n")
    }
}

/// 0.8: a child must not inherit descriptors it wasn't given. Before
/// POSIX_SPAWN_CLOEXEC_DEFAULT, a pipe another thread had open while this
/// child was spawned stayed open in the child, so that other read saw
/// end-of-file only when this child exited: `brew info` running beside
/// `brew info --sizes` finished when the sizes did.
struct SpawnDescriptorTests {
    /// Opens a pipe as "another read in flight", spawns `start`'s child
    /// (`sleep 3`), closes our write end and times how long the read end
    /// takes to see end-of-file.
    func secondsToEOF(_ start: @escaping @Sendable () async throws -> Void) async throws -> Double {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let child = Task { try await start() }
        // Let the child be spawned while our write end is still open.
        try await Task.sleep(for: .milliseconds(300))
        close(fds[1])
        let readEnd = fds[0]
        let t0 = ContinuousClock.now
        let eof = await withCheckedContinuation { (c: CheckedContinuation<Duration, Never>) in
            DispatchQueue.global().async {
                var b = [UInt8](repeating: 0, count: 64)
                while read(readEnd, &b, b.count) > 0 {}
                c.resume(returning: ContinuousClock.now - t0)
            }
        }
        close(readEnd)
        _ = try? await child.value
        return Double(eof.components.seconds) + Double(eof.components.attoseconds) / 1e18
    }

    @Test func processRunnerChildInheritsNoOtherPipes() async throws {
        let s = try await secondsToEOF { _ = try await ProcessRunner().run("/bin/sleep", ["3"], environment: [:]) }
        #expect(s < 1.5)
    }

    @Test func streamingRunnerChildInheritsNoOtherPipes() async throws {
        let s = try await secondsToEOF { _ = try await StreamingProcessRunner().stream("/bin/sleep", ["3"], environment: [:]) { _ in } }
        #expect(s < 1.5)
    }

    @Test func concurrentReadsFinishIndependently() async throws {
        // A slow and a fast command at once: the fast one returns first.
        let runner = ProcessRunner()
        let t0 = ContinuousClock.now
        async let slow = runner.run("/bin/sleep", ["3"], environment: [:])
        var fast: [Duration] = []
        for _ in 0..<5 {
            _ = try await runner.run("/bin/echo", ["hi"], environment: [:])
            fast.append(ContinuousClock.now - t0)
        }
        _ = try await slow
        #expect(fast.allSatisfy { $0 < .milliseconds(2500) })
    }
}
