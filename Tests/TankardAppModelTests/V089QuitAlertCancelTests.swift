import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.9 (confirm run on 15, MED): with the quit event's "Quit anyway?"
// alert open, cancelling hiddenbar's password dialog wasn't recorded (a
// plain ✓), and the sheet froze at "5 of 17" until the alert closed.

/// Serialized: the nested loops would run inside each other, and the held
/// main actor would starve the loop test's count.
@MainActor
@Suite(.serialized)
struct V089QuitAlertTests {
    static let helper = AdminPasswordTests.helper

    /// The main actor is held for the whole step (as the alert's modal loop
    /// held it): the step's events wait, the dialog is cancelled and brew
    /// exits meanwhile. The Cancel still belongs to that step.
    @Test func cancelWhileTheMainActorIsHeldIsStillRecorded() async throws {
        let cancels = OSAllocatedUnfairLock(initialState: 3) // earlier runs' cancels
        let brewExited = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("==> Upgrading google-chrome\n==> Removing launchctl service com.google.keystone.agent\n".utf8))
            cancels.withLock { $0 += 1 } // the helper's mark, counted as brew exits
            out(Data("🍺  google-chrome was successfully upgraded!\n".utf8))
            brewExited.withLock { $0 = true }
            return 0
        }
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = Self.helper
        deps.streamRunner = runner
        deps.askpassFocus = AskpassFocus(find: { nil }, yield: { _ in }, cancelCount: { cancels.withLock { $0 } })
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let session = try #require(store.upgrade)
        // Hold the main actor (no await) until brew has exited and the
        // queue has had time to send `.finished`.
        let deadline = Date().addingTimeInterval(10)
        while !brewExited.withLock({ $0 }), Date() < deadline { usleep(2_000) }
        usleep(200_000)
        #expect(session.items.first?.state == .waiting, "the events were applied while the main actor was held")
        await #expect(waitUntil { session.isFinished })
        let item = try #require(session.items.first)
        #expect(item.state == .done)
        #expect(session.sudoSkipped[item.id] == ["com.google.keystone.agent"])
    }

    // The quit question's alert: a modal loop entered from a run-loop block
    // leaves the main actor free; entered from a main-actor task, it doesn't.

    /// Spins the main run loop for `seconds` (a modal loop's stand-in) and
    /// counts the main-actor jobs that ran meanwhile.
    static func nestedLoopCountsMainActorJobs(seconds: Double) -> Int {
        let ran = OSAllocatedUnfairLock(initialState: 0)
        let producer = Task.detached {
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(10))
                await MainActor.run { ran.withLock { $0 += 1 } }
            }
        }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        producer.cancel()
        return ran.withLock { $0 }
    }

    @Test func aModalLoopFromARunLoopBlockLeavesTheMainActorFree() async throws {
        // Only meaningful when the main run loop is running (it is under
        // `swift test`); the block is the one the quit event now uses.
        let result = OSAllocatedUnfairLock<Int?>(initialState: nil)
        RunLoopPerform.onMain { @MainActor in
            let n = Self.nestedLoopCountsMainActorJobs(seconds: 0.6)
            result.withLock { $0 = n }
        }
        await #expect(waitUntil(timeout: .seconds(10)) { result.withLock { $0 } != nil })
        let n = try #require(result.withLock { $0 })
        #expect(n >= 5, "main-actor jobs during the nested loop: \(n)")
    }

    /// The root cause, kept as a check: the same loop inside a main-actor
    /// Task (a main-queue job) lets no other main-actor job run.
    @Test func aModalLoopInsideAMainActorTaskHoldsTheMainActor() async throws {
        let n = await Task { @MainActor in Self.nestedLoopCountsMainActorJobs(seconds: 0.6) }.value
        #expect(n == 0, "main-actor jobs during the nested loop: \(n)")
    }
}
