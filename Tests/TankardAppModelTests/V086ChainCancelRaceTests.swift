import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.8.6 release run 44448357607: a failed uninstall step's next version
/// ran anyway ([.failed, .failed]). A chain's later steps are enqueued after
/// its first, so a first step that fails at once (a fast fake, or an instant
/// precondition refusal in the app) could cancel them before they were in
/// the queue, and that cancel was dropped. Deterministic: B is cancelled
/// before it is enqueued, and must still be skipped.
struct V086ChainCancelRaceTests {
    func cmd(_ name: String) -> QueuedCommand {
        QueuedCommand(executable: "/usr/local/bin/brew", arguments: ["uninstall", name], environment: [:], display: "brew uninstall \(name)")
    }

    @Test(.timeLimit(.minutes(1))) func aCancelBeforeEnqueueStillSkipsTheStep() async throws {
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { _, _ in 1 }
        let queue = CommandQueue(runner: runner)
        let events = CommandQueueTests.Events()
        let b = UUID()
        queue.enqueue(cmd("a")) { event in
            if case .finished(let code) = event, code != 0 { queue.cancel([b]) }
            events.add("a", event)
        }
        await events.arrival { if case .finished = $0 { true } else { false } }
        queue.enqueue(cmd("b"), id: b) { events.add("b", $0) }
        await events.arrival { if case .cancelled = $0 { true } else if case .finished = $0 { true } else { false } }
        while events.terminal("b") == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(log.calls.map { $0.last ?? "" } == ["a"])
        guard case .cancelled = events.terminal("b") else {
            Issue.record("b should be cancelled, got \(String(describing: events.terminal("b")))")
            return
        }
    }

    /// The real chain: a step that fails at once (a precondition refusal,
    /// no process) skips its chain's later steps every time.
    @Test(.timeLimit(.minutes(1)), arguments: 0..<50) func anInstantFailureSkipsItsChain(_ run: Int) async throws {
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { _, _ in 1 }
        let queue = CommandQueue(runner: runner)
        let events = CommandQueueTests.Events()
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            let rest = Array(ids.dropFirst(i + 1))
            queue.enqueue(cmd("step\(i)"), id: id) { event in
                if !rest.isEmpty, case .finished(let code) = event, code != 0 { queue.cancel(rest) }
                events.add("step\(i)", event)
            }
        }
        // Three terminal events (one per step); the matcher sees only the
        // event, so count arrivals outside the Events lock.
        while events.count(where: { if case .output = $0 { false } else if case .started = $0 { false } else { true } }) < 3 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(log.calls.count == 1)
        guard case .cancelled = events.terminal("step1"), case .cancelled = events.terminal("step2") else {
            Issue.record("later steps ran: \(events.all.map(\.0))")
            return
        }
    }
}
