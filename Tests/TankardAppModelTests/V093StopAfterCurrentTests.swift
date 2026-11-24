import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.3 (hardening of 33a2c80 / 6dba7c5): Stop After Current skips only
// what the queue hasn't started; Stop Now still stops the running step.
// The race tests hold the main actor (no await) until the queue runs a
// step whose `.started` hasn't been applied yet, as the quit question's
// modal alert does.

extension CommandQueueTests {
    /// The queue-level rule, with no main actor involved: an id the queue
    /// is running is left alone; ids it hasn't started are skipped. Fails
    /// if `cancelIfWaiting` behaves like `cancel`.
    @Test(.timeLimit(.minutes(1))) func cancelIfWaitingSkipsWaitingIdsButNeverTheRunningOne() async throws {
        let log = CallLog()
        let gate = Latch()
        let runner = FakeStreamRunner(log: log) { args, _ in
            if args.last == "first" {
                await gate.wait()
                // A stopped command ends here.
                try Task.checkCancellation()
            }
            return 0
        }
        let queue = CommandQueue(runner: runner)
        let events = Events()
        let first = queue.enqueue(cmd("first")) { events.add("first", $0) }
        let second = queue.enqueue(cmd("second")) { events.add("second", $0) }
        queue.enqueue(cmd("third")) { events.add("third", $0) }
        try await waitFor { queue.runningID == first }
        queue.cancelIfWaiting([first, second])
        #expect(queue.runningID == first, "the running command is still running")
        gate.release()
        try await waitFor { events.terminal("third") != nil }
        #expect(events.terminal("first") == .finished(exitCode: 0))
        #expect(events.terminal("second") == .cancelled)
        #expect(!events.all.contains { $0.0 == "second" && $0.1 == .started })
        #expect(events.terminal("third") == .finished(exitCode: 0))
        #expect(log.calls.map { $0.last! } == ["first", "third"])
    }

    /// A command whose skip check is running hasn't started: it's still
    /// waiting, so cancelIfWaiting skips it (its brew never runs). Every
    /// wait is bounded (a latch or an event arrival ignores `.timeLimit`):
    /// if the skip check never runs, or the command ends some other way,
    /// the test fails instead of hanging.
    @Test(.timeLimit(.minutes(1))) func cancelIfWaitingSkipsACommandStillInItsSkipCheck() async throws {
        let log = CallLog()
        let checking = OSAllocatedUnfairLock(initialState: false)
        let answer = Latch()
        // A failed wait below must not leave the skip check suspended.
        defer { answer.release() }
        let runner = FakeStreamRunner(log: log) { _, _ in 0 }
        let queue = CommandQueue(runner: runner)
        let events = Events()
        let id = queue.enqueue(cmd("checked"), skipCheck: {
            checking.withLock { $0 = true }
            await answer.wait()
            return nil
        }) { events.add("checked", $0) }
        try await waitFor(timeout: .seconds(10)) { checking.withLock { $0 } }
        #expect(queue.runningID == nil)
        queue.cancelIfWaiting([id])
        answer.release()
        // Any terminal event, then which one.
        try await waitFor(timeout: .seconds(10)) { events.terminal("checked") != nil }
        #expect(events.terminal("checked") == .cancelled)
        #expect(!events.all.contains { $0.1 == .started })
        #expect(log.calls.isEmpty)
    }
}

extension AppStoreTests {
    /// Holds the main actor until the queue runs `id` (no await, so the
    /// session can't apply that step's `.started`).
    func holdUntilRunning(_ queue: CommandQueue, _ id: UUID) {
        let held = ContinuousClock.now + .seconds(30)
        while queue.runningID != id, ContinuousClock.now < held { usleep(1_000) }
    }

    /// The race on the run's last package: the sheet shows it waiting, the
    /// queue runs it. Stop After Current lets it finish; nothing is
    /// stopped, so nothing is shown as stopped.
    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentLetsTheLastStepFinishWhenTheQueueAlreadyStartedIt() async throws {
        let first = Latch(), last = Latch()
        let upgrades = OSAllocatedUnfairLock(initialState: 0)
        let r = try rig { args, _ in
            guard args.first == "upgrade" else { return 0 }
            let n = upgrades.withLock { $0 += 1; return $0 }
            if n == 1 { await first.wait() }
            if n == 2 {
                await last.wait()
                try Task.checkCancellation()
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let pkgs = Array(r.store.upgradable.filter(\.isManualUpgradeTarget).prefix(2))
        try #require(pkgs.count == 2)
        r.store.startUpgrade(pkgs)
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current?.id == session.items[0].id })

        first.release()
        holdUntilRunning(r.store.queue, session.items[1].id)
        // The race window; missed, the test stops rather than passing without it.
        try #require(r.store.queue.runningID == session.items[1].id)
        try #require(session.items[1].state == .waiting)
        session.stopAfterCurrent()

        last.release()
        #expect(await waitUntil { session.isFinished })
        #expect(session.items.map(\.state) == [.done, .done])
        #expect(upgrades.withLock { $0 } == 2)
        #expect(!session.log.lines.contains("tankard: Stopped."))
        #expect(session.statusLine == "2 upgraded")
    }

    /// The same race with Stop Now: the step the queue started is stopped
    /// even though the sheet still shows it waiting, and the rest are
    /// skipped. (Stop Now must not become "after current".)
    @Test(.timeLimit(.minutes(1))) func stopNowStopsAStepTheQueueStartedBeforeTheSheetShowedIt() async throws {
        let first = Latch()
        let upgrades = OSAllocatedUnfairLock(initialState: 0)
        let r = try rig { args, _ in
            guard args.first == "upgrade" else { return 0 }
            let n = upgrades.withLock { $0 += 1; return $0 }
            if n == 1 { await first.wait() }
            if n == 2 { try await sleepUntilCancelled() }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let pkgs = Array(r.store.upgradable.filter(\.isManualUpgradeTarget).prefix(3))
        try #require(pkgs.count == 3)
        r.store.startUpgrade(pkgs)
        let session = try #require(r.store.upgrade)
        #expect(await waitUntil { session.current?.id == session.items[0].id })

        first.release()
        holdUntilRunning(r.store.queue, session.items[1].id)
        try #require(r.store.queue.runningID == session.items[1].id)
        try #require(session.items[1].state == .waiting)
        let start = ContinuousClock.now
        session.stopNow()

        #expect(await waitUntil { session.isFinished })
        #expect(ContinuousClock.now - start < .seconds(20), "the running step was stopped, not waited for")
        #expect(session.items.map(\.state) == [.done, .cancelled, .cancelled])
        #expect(upgrades.withLock { $0 } == 2)
        #expect(session.title == "Upgrade stopped")
    }

    /// Stop After Current before the run's first command starts (the queue
    /// is busy with something else): nothing of the run starts, not the
    /// download and not an upgrade.
    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentBeforeAnyStepStartsRunsNothing() async throws {
        let blocker = Latch()
        let r = try rig { args, _ in
            if args.first == "blocker" { await blocker.wait() }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        let busy = r.store.queue.enqueue(QueuedCommand(executable: "/usr/local/bin/brew", arguments: ["blocker"],
                                                       environment: [:], display: "brew blocker")) { _ in }
        try #require(await waitUntil { r.store.queue.runningID == busy })
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        #expect(session.notStarted)
        session.stopAfterCurrent()
        blocker.release()
        #expect(await waitUntil { session.isFinished })
        #expect(r.log.count("fetch") == 0)
        #expect(r.log.count("upgrade") == 0)
        #expect(session.items.allSatisfy { $0.state == .cancelled })
        #expect(session.fetchStates.values.allSatisfy { $0 == .cancelled })
        #expect(session.title == "Upgrade stopped")
    }

    /// The race on a download step: the queue runs `brew fetch` while the
    /// sheet still shows it waiting. Stop After Current lets the download
    /// finish and skips the upgrades.
    @Test(.timeLimit(.minutes(1))) func stopAfterCurrentLetsADownloadTheQueueAlreadyStartedFinish() async throws {
        let fetch = Latch()
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let r = try rig { args, _ in
            if args.first == "fetch" {
                fetches.withLock { $0 += 1 }
                await fetch.wait()
                try Task.checkCancellation()
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let session = try #require(r.store.upgrade)
        let fetchIDs = Set(session.fetchStates.keys)
        try #require(!fetchIDs.isEmpty)
        // No await since the run was enqueued: the session hasn't applied
        // the download's `.started`.
        let held = ContinuousClock.now + .seconds(30)
        while !(r.store.queue.runningID.map(fetchIDs.contains) ?? false), ContinuousClock.now < held { usleep(1_000) }
        try #require(r.store.queue.runningID.map(fetchIDs.contains) == true)
        try #require(session.fetchStates.values.allSatisfy { $0 == .waiting })
        session.stopAfterCurrent()

        fetch.release()
        #expect(await waitUntil { session.isFinished })
        #expect(fetches.withLock { $0 } == fetchIDs.count)
        #expect(session.fetchStates.values.allSatisfy { $0 == .done })
        #expect(r.log.count("upgrade") == 0)
        #expect(session.items.allSatisfy { $0.state == .cancelled })
        #expect(session.title == "Upgrade stopped")
    }
}
