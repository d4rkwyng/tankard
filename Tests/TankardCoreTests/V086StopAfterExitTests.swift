import Foundation
import Testing
@testable import TankardCore

// 0.8.6 (HK-47 review, item 1): once brew has exited and been reaped, its pid
// is free and can be reused. Stop Now's later timers (SIGTERM after
// interruptGrace, SIGKILL after killGrace more) used to fire anyway: the
// SIGTERM guard only asked whether *some* group -pid existed, and the SIGKILL
// was unconditional. Now nothing is sent once the child has exited.
struct V086StopAfterExitTests {
    /// The shell handles SIGINT by exiting at once, leaving a background
    /// process that ignores INT and TERM behind in its process group. The
    /// stream ends (the shell is reaped); the later signals must not follow:
    /// before the fix the leftover was SIGKILLed after both graces, through a
    /// group id that belonged to an already reaped process.
    @Test func noSignalAfterTheChildWasReaped() async throws {
        let script = "trap 'exit 0' INT; (trap '' INT TERM; exec sleep 6) </dev/null >/dev/null 2>&1 & echo BG $!; while :; do sleep 0.05; done"
        let runner = StreamingProcessRunner(killGrace: 0.3, interruptGrace: 0.3)
        let sink = TextSink()
        let task = Task {
            try await runner.stream("/bin/sh", ["-c", script], environment: [:]) { sink.add($0) }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !sink.text.contains("\n"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let line = sink.text.split(separator: "\n").first ?? ""
        #expect(line.hasPrefix("BG "))
        let bg = pid_t(line.dropFirst("BG ".count)) ?? 0
        #expect(bg > 0)
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        // Both graces and a margin.
        try await Task.sleep(for: .milliseconds(1200))
        let alive = bg > 0 && kill(bg, 0) == 0
        if bg > 0 { kill(bg, SIGKILL) }
        #expect(alive, "a signal reached brew's old process group after brew had been reaped")
    }

    /// With the signal sender injected: a child that exits on SIGINT
    /// before the interrupt grace gets the SIGINT and nothing after it.
    @Test func onlyTheInterruptWhenTheChildExitsBeforeTheGrace() async throws {
        let sent = SentSignals()
        let runner = StreamingProcessRunner(killGrace: 0.3, interruptGrace: 0.3) { pid, sig in
            sent.add(pid, sig)
            _ = kill(pid, sig)
        }
        let sink = TextSink()
        let task = Task {
            try await runner.stream("/bin/sh", ["-c", "trap 'exit 130' INT; echo READY $$; while :; do sleep 0.05; done"],
                                    environment: [:]) { sink.add($0) }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !sink.text.contains("\n"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = pid_t((sink.text.split(separator: "\n").first ?? "").dropFirst("READY ".count)) ?? 0
        #expect(pid > 0)
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(1200))
        #expect(sent.all.map { $0.sig } == [SIGINT])
        #expect(sent.all.first?.pid == -pid)
    }
}

final class SentSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(pid: pid_t, sig: Int32)] = []
    func add(_ pid: pid_t, _ sig: Int32) { lock.withLock { sent.append((pid, sig)) } }
    var all: [(pid: pid_t, sig: Int32)] { lock.withLock { sent } }
}
