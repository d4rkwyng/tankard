import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

struct CommandQueueTests {
    func cmd(_ name: String) -> QueuedCommand {
        QueuedCommand(executable: "/usr/local/bin/brew", arguments: ["upgrade", name], environment: [:], display: "brew upgrade \(name)")
    }

    /// Collects events per command.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, CommandEvent)] = []
        private var waiters: [(match: @Sendable (CommandEvent) -> Bool, done: CheckedContinuation<Void, Never>)] = []
        func add(_ name: String, _ e: CommandEvent) {
            let ready = lock.withLock {
                _events.append((name, e))
                let ready = waiters.filter { $0.match(e) }
                waiters.removeAll { $0.match(e) }
                return ready
            }
            for w in ready { w.done.resume() }
        }
        /// Returns once an event matching `match` has arrived (at once if
        /// one has): a signal, no clock. Pair with a `.timeLimit` trait.
        func arrival(of match: @escaping @Sendable (CommandEvent) -> Bool) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let seen = lock.withLock {
                    if _events.contains(where: { match($0.1) }) { return true }
                    waiters.append((match, c))
                    return false
                }
                if seen { c.resume() }
            }
        }
        var all: [(String, CommandEvent)] { lock.withLock { _events } }
        func terminal(_ name: String) -> CommandEvent? {
            all.last { $0.0 == name && { if case .output = $0.1 { false } else if case .started = $0.1 { false } else { true } }($0) }?.1
        }
        func count(where p: (CommandEvent) -> Bool) -> Int { all.filter { p($0.1) }.count }
    }

    @Test func strictFIFOOneAtATime() async throws {
        let log = CallLog()
        let active = OSAllocatedUnfairLock(initialState: (now: 0, max: 0))
        let runner = FakeStreamRunner(log: log) { args, output in
            active.withLock { $0.now += 1; $0.max = max($0.max, $0.now) }
            // Uneven durations: a racy queue would let short ones overtake.
            let n = Int(args.last!.dropFirst(3))!
            try await Task.sleep(for: .milliseconds((n * 7) % 5 + 1))
            output(Data("did \(args.last!)\n".utf8))
            active.withLock { $0.now -= 1 }
            return 0
        }
        let queue = CommandQueue(runner: runner)
        let events = Events()
        let names = (0..<20).map { "pkg\($0)" }
        for name in names {
            queue.enqueue(cmd(name)) { events.add(name, $0) }
        }
        try await waitFor { events.count { if case .finished = $0 { true } else { false } } == 20 }
        #expect(log.calls.map { $0.last! } == names)
        #expect(active.withLock { $0.max } == 1)
        // Per command: started, then output, then finished, and command N
        // finished before N+1 started.
        let order = events.all.compactMap { (n, e) -> String? in
            switch e {
            case .started: return "s:\(n)"
            case .finished: return "f:\(n)"
            default: return nil
            }
        }
        #expect(order == names.flatMap { ["s:\($0)", "f:\($0)"] })
    }

    @Test func enqueueOrderIsCallOrderAcrossThreads() async throws {
        // Many threads enqueue at once; whatever order the calls landed in,
        // that is exactly the order they run in.
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { _, _ in 0 }
        let queue = CommandQueue(runner: runner)
        let accepted = OSAllocatedUnfairLock(initialState: [String]())
        let done = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            accepted.withLock { list in
                // Record and enqueue atomically so "call order" is observable.
                list.append("p\(i)")
                queue.enqueue(cmd("p\(i)")) { e in if case .finished = e { done.withLock { $0 += 1 } } }
            }
        }
        try await waitFor { done.withLock { $0 } == 50 }
        #expect(log.calls.map { $0.last! } == accepted.withLock { $0 })
    }

    @Test func cancelPendingSkipsIt() async throws {
        let log = CallLog()
        let gate = Latch()
        let runner = FakeStreamRunner(log: log) { args, _ in
            if args.last == "first" { await gate.wait() }
            return 0
        }
        let queue = CommandQueue(runner: runner)
        let events = Events()
        queue.enqueue(cmd("first")) { events.add("first", $0) }
        let second = queue.enqueue(cmd("second")) { events.add("second", $0) }
        queue.enqueue(cmd("third")) { events.add("third", $0) }
        try await waitFor { queue.runningID != nil }
        queue.cancel(second)
        gate.release()
        try await waitFor { events.terminal("third") != nil }
        #expect(log.calls.map { $0.last! } == ["first", "third"])
        #expect(events.terminal("first") == .finished(exitCode: 0))
        #expect(events.terminal("second") == .cancelled)
        #expect(!events.all.contains { $0.0 == "second" && $0.1 == .started })
    }

    @Test func cancelRunningStopsItAndTheQueueMovesOn() async throws {
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { args, _ in
            if args.last == "slow" { try await sleepUntilCancelled() }
            return 0
        }
        let queue = CommandQueue(runner: runner)
        let events = Events()
        let slow = queue.enqueue(cmd("slow")) { events.add("slow", $0) }
        queue.enqueue(cmd("next")) { events.add("next", $0) }
        try await waitFor { queue.runningID == slow }
        let start = ContinuousClock.now
        queue.cancel(slow)
        try await waitFor { events.terminal("next") != nil }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(events.terminal("slow") == .cancelled)
        #expect(events.terminal("next") == .finished(exitCode: 0))
    }

    @Test func cancellationKillsARealProcessGroup() async throws {
        // End to end with the real posix_spawn runner: the queue's cancel
        // must take down the shell's grandchild too.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid").path
        let queue = CommandQueue(runner: StreamingProcessRunner(killGrace: 0.5))
        let events = Events()
        let id = queue.enqueue(QueuedCommand(executable: "/bin/sh",
                                             arguments: ["-c", "sleep 30 & echo $! > '\(pidFile)'; echo started; wait"],
                                             environment: [:], display: "sh")) { events.add("sh", $0) }
        let readPID: @Sendable () -> pid_t? = {
            (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        try await waitFor { readPID() != nil }
        let child = readPID()
        queue.cancel(id)
        try await waitFor { events.terminal("sh") != nil }
        #expect(events.terminal("sh") == .cancelled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(try #require(child), 0) != 0, "grandchild survived")
    }

    @Test func spawnFailureIsReported() async throws {
        let queue = CommandQueue(runner: StreamingProcessRunner())
        let events = Events()
        queue.enqueue(QueuedCommand(executable: "/nonexistent/brew", arguments: [], environment: [:], display: "x")) { events.add("x", $0) }
        try await waitFor { events.terminal("x") != nil }
        guard case .failed = events.terminal("x") else {
            Issue.record("expected .failed, got \(String(describing: events.terminal("x")))")
            return
        }
    }

    @Test func runAwaitsTheResult() async throws {
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { _, output in
            output(Data("hello\n".utf8))
            return 3
        }
        let queue = CommandQueue(runner: runner)
        let text = OSAllocatedUnfairLock(initialState: "")
        let code = try await queue.run(cmd("x")) { d in text.withLock { $0 += String(decoding: d, as: UTF8.self) } }
        #expect(code == 3)
        #expect(text.withLock { $0 } == "hello\n")
    }
}

/// Polls from any context.
func waitFor(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
