import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.2 (bug hunt): Stop After Current cancelled every item the main actor
// still showed as waiting. The queue starts the next package as soon as
// the previous one's handler returns, and its `.started` reaches the main
// actor later (sooner or later: the quit question's modal alert holds the
// main actor, heavy log output delays it). Cancelling that "waiting" id
// stopped the package brew was already upgrading, like Stop Now without
// its confirmation.

extension AppStoreTests {
    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentNeverStopsAStepTheQueueAlreadyStarted() async throws {
        let first = Latch(), second = Latch()
        let upgrades = OSAllocatedUnfairLock(initialState: 0)
        let r = try rig { args, _ in
            guard args.first == "upgrade" else { return 0 }
            let n = upgrades.withLock { $0 += 1; return $0 }
            if n == 1 { await first.wait() }
            if n == 2 {
                await second.wait()
                // A stopped step ends here (the queue also reports a
                // cancelled task as cancelled, whatever it returns).
                try Task.checkCancellation()
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let pkgs = Array(r.store.upgradable.filter(\.isManualUpgradeTarget).prefix(3))
        #expect(pkgs.count == 3)
        r.store.startUpgrade(pkgs)
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current?.id == session.items[0].id })

        // The first step ends and the queue starts the second, while the
        // main actor is held (no await until the stop): it hasn't seen
        // the second step's `.started` yet.
        first.release()
        let held = ContinuousClock.now + .seconds(30)
        while r.store.queue.runningID != session.items[1].id, ContinuousClock.now < held {
            usleep(1_000)
        }
        // The race window: the queue runs the step the sheet still shows as
        // waiting. Missed (`.started` already applied), the test stops here
        // rather than passing without the race.
        try #require(r.store.queue.runningID == session.items[1].id)
        try #require(session.items[1].state == .waiting)
        session.stopAfterCurrent()

        second.release()
        #expect(await waitUntil { session.isFinished })
        // The step brew had started finishes; only the one still waiting is skipped.
        #expect(session.items.map(\.state) == [.done, .done, .cancelled])
        #expect(upgrades.withLock { $0 } == 2)
    }
}
