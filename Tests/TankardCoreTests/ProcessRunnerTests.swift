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

// 0.8.3: Stop Now interrupts brew like Ctrl-C first (SIGINT, which brew
// rolls back from), and only then SIGTERM, then SIGKILL.
struct StreamingStopSignalTests {
    /// Output collected from a background thread.
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    struct Stopped {
        /// From the cancel (Stop Now) to the stream's end.
        var elapsed: Duration
        /// What the child's traps wrote, in order.
        var marker: String
        /// The shell's pid (its `READY <pid>` line).
        var pid: pid_t
        var threwCancelled: Bool
    }

    /// Runs `traps`, then a loop, under /bin/sh; cancels once the shell says
    /// READY, which it prints after its traps are set (cancelling after a
    /// fixed 300 ms raced the shell's startup on a loaded CI runner: SIGINT
    /// arrived before the trap and killed it silently). `echo` is a builtin
    /// writing straight to the file or pipe: nothing is buffered.
    func run(_ traps: String, interruptGrace: Double, killGrace: Double = 0.5) async throws -> Stopped {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = dir.appendingPathComponent("m").path
        let script = traps.replacingOccurrences(of: "$M", with: "'\(m)'") + "; echo READY $$; while :; do sleep 0.05; done"
        let runner = StreamingProcessRunner(killGrace: killGrace, interruptGrace: interruptGrace)
        let out = Output()
        let task = Task {
            try await runner.stream("/bin/sh", ["-c", script], environment: [:]) { out.add($0) }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !out.text.contains("\n"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = out.text.split(separator: "\n").first ?? ""
        #expect(ready.hasPrefix("READY "), "the shell never got its traps set")
        let pid = pid_t(ready.dropFirst("READY ".count)) ?? 0
        let cancelled = ContinuousClock.now
        task.cancel()
        var threw = false
        do { _ = try await task.value } catch ProcessRunnerError.cancelled { threw = true }
        let elapsed = ContinuousClock.now - cancelled
        return Stopped(elapsed: elapsed, marker: (try? String(contentsOfFile: m, encoding: .utf8)) ?? "",
                       pid: pid, threwCancelled: threw)
    }

    /// Nothing of the shell's group is left (the leader was reaped by the
    /// runner; `sleep` children went with the group's signal).
    /// (Polled: an orphaned child's zombie is reaped by launchd, not at once.)
    func gone(_ pid: pid_t) async -> Bool {
        guard pid > 0 else { return false }
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(-pid, 0) == 0 || kill(pid, 0) == 0 {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func sigintFirst() async throws {
        let r = try await run("trap 'echo INT >> $M; exit 130' INT; trap 'echo TERM >> $M; exit 143' TERM",
                              interruptGrace: 20)
        #expect(r.marker == "INT\n")
        #expect(r.threwCancelled)
        #expect(r.elapsed < .seconds(10), "a process that handles SIGINT isn't made to wait for the grace period")
        #expect(await gone(r.pid))
    }

    @Test func sigtermWhenSigintIsIgnored() async throws {
        let r = try await run("trap '' INT; trap 'echo TERM >> $M; exit 143' TERM", interruptGrace: 0.4)
        #expect(r.marker == "TERM\n")
        #expect(r.threwCancelled)
        #expect(r.elapsed >= .milliseconds(400), "SIGTERM only after the interrupt grace")
        #expect(await gone(r.pid))
    }

    /// The whole escalation, in order: a child that survives SIGINT and
    /// SIGTERM (it notes each and keeps going) is ended by SIGKILL, and
    /// only after both graces.
    @Test func sigintThenSigtermThenSigkill() async throws {
        let r = try await run("trap 'echo INT >> $M' INT; trap 'echo TERM >> $M' TERM", interruptGrace: 0.4, killGrace: 0.5)
        #expect(r.marker == "INT\nTERM\n")
        #expect(r.threwCancelled)
        #expect(r.elapsed >= .milliseconds(900), "SIGKILL only after both graces")
        #expect(await gone(r.pid))
    }

    /// A child that ignores both SIGINT and SIGTERM: SIGKILL still ends it.
    @Test func sigkillWhenSigintAndSigtermAreIgnored() async throws {
        let r = try await run("trap '' INT TERM", interruptGrace: 0.4, killGrace: 0.5)
        #expect(r.marker == "")
        #expect(r.threwCancelled)
        #expect(r.elapsed >= .milliseconds(900), "SIGKILL only after both graces")
        #expect(await gone(r.pid))
    }

    /// Stop Now before posix_spawn returned: the child is still stopped
    /// (the cancel used to find no pid and do nothing; the child ran on).
    @Test func cancelBeforeTheChildStartedStillStopsIt() async throws {
        let runner = StreamingProcessRunner(killGrace: 0.5, interruptGrace: 0.5)
        let started = ContinuousClock.now
        let task = Task {
            // Already cancelled when stream is called: its cancel handler
            // runs at once, before there is any pid.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.stream("/bin/sh", ["-c", "sleep 60"], environment: [:]) { _ in }
        }
        var threw = false
        do { _ = try await task.value } catch ProcessRunnerError.cancelled { threw = true }
        #expect(threw)
        #expect(ContinuousClock.now - started < .seconds(20))
    }
}
