import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.9.3 (hardening of 48e4e59 / 6dba7c5): one status read at a time, for
/// every mix of callers, and a caller clears only its own task. Reads are
/// counted as they begin (`refreshesStarted`, on the main actor), and each
/// "no second read" check yields once first, as V092RefreshJoinTests does,
/// so a read that was going to start has started.
@MainActor
struct V093RefreshJoinTests {
    typealias GatedInfo = V092RefreshJoinTests.GatedInfo

    /// For each `brew update`, as it starts: how many status reads were
    /// in flight (held at their gate) then.
    typealias UpdateOverlaps = OSAllocatedUnfairLock<[Int]>

    func rig() async -> (AppStore, GatedInfo, CallLog, UpdateOverlaps) {
        let log = CallLog()
        let runner = GatedInfo(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let overlaps = UpdateOverlaps(initialState: [])
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: log) { args, _ in
            if args.first == "update" { overlaps.withLock { $0.append(runner.running) } }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream,
                                                         cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        #expect(await waitUntil { !store.isRefreshing })
        runner.gating = true
        return (store, runner, log, overlaps)
    }

    /// One more read has begun and, after a yield, still only one.
    func expectOneMoreRead(_ store: AppStore, _ reads: Int, _ comment: Comment) async throws {
        try #require(await waitUntil(timeout: .seconds(10)) { store.refreshesStarted >= reads + 1 })
        await Task.yield()
        try #require(store.refreshesStarted == reads + 1, comment)
    }

    /// A Refresh (.manual), a scheduled check (.scheduled) and a background
    /// update's re-read (.afterUpdate) all wait on one automatic read: each
    /// then reads in turn, never two at once, and a Refresh asked for
    /// meanwhile joins nothing but waits too.
    @Test(.timeLimit(.minutes(1))) func mixedCallersWaitingOnOneReadReadOneAfterAnother() async throws {
        let (store, runner, log, overlaps) = await rig()
        // A failed #require must not leave reads held at closed gates.
        defer { runner.openAll() }
        let reads = store.refreshesStarted
        let done = Box(0), entered = Box(0)
        Task { await store.refresh(.automatic); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        // Each counts itself in the same main-actor job that enters refresh
        // and reaches its wait on the running read (the read can't end yet:
        // its gate is closed). All three must be waiting before it opens.
        Task { entered.value += 1; await store.refresh(.manual); done.value += 1 }
        Task { entered.value += 1; await store.refresh(.scheduled); done.value += 1 }
        Task { entered.value += 1; await store.refresh(.afterUpdate); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { entered.value == 3 },
                     "the three callers didn't all reach their wait on the read")
        await Task.yield()
        #expect(done.value == 0, "a waiting caller returned before the read ended")
        #expect(store.refreshesStarted == reads + 1)
        #expect(log.count("update") == 0, "a waiting Refresh hasn't run brew update yet")

        // Each release lets exactly one waiter read.
        for i in 0..<3 {
            let before = store.refreshesStarted
            runner.release(i)
            try await expectOneMoreRead(store, before, "two waiting callers read at the same time")
            try #require(await waitUntil(timeout: .seconds(10)) { runner.started == i + 2 })
            #expect(store.isRefreshing && store.refreshTask != nil)
            #expect(runner.running == 1)
        }
        runner.release(3)
        #expect(await waitUntil(timeout: .seconds(10)) { done.value == 4 })
        #expect(runner.started == 4)
        #expect(runner.maxInFlight == 1)
        #expect(store.refreshesStarted == reads + 4)
        // brew update ran for the Refresh and the scheduled check, never alongside a read.
        #expect(log.count("update") == 2)
        #expect(overlaps.withLock { $0 } == [0, 0], "brew update started while a status read was in flight")
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }

    /// The second half of the fix, alone: the read's own caller resumes
    /// after a waiter has started its read, and must not clear that read's
    /// task. While it runs, an automatic refresh joins it (no new read) and
    /// returns only when it ends; a scheduled check waits for it.
    ///
    /// The order is forced by a gate, not left to the main actor: the first
    /// caller runs with a task executor preference (`HeldResumption`), and
    /// when its read's task completes the runtime wakes it there (a waiter
    /// on a task resumes on the generic executor, which for a task with a
    /// preference is that executor), before it hops back to the main actor
    /// for its cleanup. The executor holds that wake-up. The follower, an
    /// ordinary task, waited on the same read; it resumes, clears the read's
    /// task and installs its own while the first caller is held. The test
    /// sees both (the follower's read at its gate, the first caller's
    /// wake-up held and its refresh not returned) and only then lets the
    /// first caller go: its cleanup runs, and in the same main-actor job it
    /// records `refreshTask`. Nothing here waits on the follower from inside
    /// the first read, so neither side waits on the other.
    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1))) func theCallerOfAFinishedReadLeavesTheNextReadsTask() async throws {
        let (store, runner, _, _) = await rig()
        let held = HeldResumption()
        defer { held.open(); runner.openAll() }
        let reads = store.refreshesStarted
        let firstDone = Box(false), followerDone = Box(false), followerEntered = Box(false)
        let followerInstalled = Box(false)
        let firstSaw = Box<(followerInstalled: Bool, task: Task<Void, Never>?)?>(nil)
        let first: @MainActor @Sendable () async -> Void = {
            await store.refresh(.automatic)
            // Same main-actor job as the first caller's cleanup (and the
            // follower's read is held at its gate, so its task can't end).
            firstSaw.value = (followerInstalled.value, store.refreshTask)
            firstDone.value = true
        }
        Task(executorPreference: held) { await first() }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        let firstTask = try #require(store.refreshTask)
        try #require(store.isRefreshing)
        // From here every wake-up of the first caller is held until opened.
        held.hold()
        // The follower counts itself in the job that enters refresh and
        // reaches its wait on the first read.
        Task {
            followerEntered.value = true
            await store.refresh(.afterUpdate)
            followerDone.value = true
        }
        try #require(await waitUntil(timeout: .seconds(10)) { followerEntered.value })
        #expect(store.refreshesStarted == reads + 1)
        runner.release(0)

        // The follower has installed its task and started its read; the
        // first caller's wake-up is held and its refresh hasn't returned.
        try await expectOneMoreRead(store, reads + 1, "the follower read twice")
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 2 })
        try #require(await waitUntil(timeout: .seconds(10)) { held.count >= 1 },
                     "the first caller's wake-up didn't reach the gate")
        try #require(!firstDone.value, "the first caller resumed past the gate")
        let followerTask = try #require(store.refreshTask, "the follower's task isn't installed")
        try #require(followerTask != firstTask)
        followerInstalled.value = true

        // Now the first caller resumes and cleans up.
        held.open()
        #expect(await waitUntil(timeout: .seconds(10)) { firstDone.value })
        let saw = try #require(firstSaw.value)
        // The witness: the follower's task was in before the first caller's cleanup.
        try #require(saw.followerInstalled, "the follower didn't install its task before the first caller resumed")
        #expect(saw.task != nil, "the first read's caller cleared the follower's task")
        #expect(saw.task != firstTask)
        #expect(saw.task == followerTask)
        #expect(runner.started == 2)
        #expect(store.isRefreshing)
        #expect(store.refreshTask != nil, "the first read's caller cleared the follower's task")
        #expect(store.refreshTask == followerTask)

        let joined = Box(false), scheduled = Box(false), entered = Box(0)
        Task { entered.value += 1; await store.refresh(.automatic); joined.value = true }
        Task { entered.value += 1; await store.refresh(.scheduled); scheduled.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { entered.value == 2 })
        await Task.yield()
        #expect(store.refreshesStarted == reads + 2, "a refresh started a read beside the follower's")
        #expect(runner.running == 1)
        #expect(!joined.value, "the automatic refresh returned before the read it joined ended")
        #expect(!scheduled.value, "the scheduled check returned before the follower's read ended")

        runner.release(1)
        #expect(await waitUntil(timeout: .seconds(10)) { joined.value && followerDone.value })
        try await expectOneMoreRead(store, reads + 2, "the scheduled check read twice")
        // Its brew update runs first: wait for its status read to reach its gate.
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 3 })
        runner.release(2)
        #expect(await waitUntil(timeout: .seconds(10)) { scheduled.value })
        #expect(runner.started == 3)
        #expect(runner.maxInFlight == 1)
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }

    /// A read that fails leaves nothing behind: the waiting caller reads
    /// next (one at a time), the error is shown and then cleared by the
    /// good read, and the store ends idle with no task.
    @Test(.timeLimit(.minutes(1))) func aFailedReadLeavesTheStoreIdleAndTheNextCallerReads() async throws {
        let (store, runner, _, _) = await rig()
        defer { runner.openAll() }
        let reads = store.refreshesStarted
        runner.inner.failInfo = true
        let firstDone = Box(false), followerDone = Box(false)
        Task { await store.refresh(.automatic); firstDone.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        let followerEntered = Box(false)
        Task { followerEntered.value = true; await store.refresh(.afterUpdate); followerDone.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { followerEntered.value })
        runner.release(0)
        #expect(await waitUntil(timeout: .seconds(10)) { firstDone.value })
        #expect(store.error != nil, "the failed read is reported")
        runner.inner.failInfo = false
        try await expectOneMoreRead(store, reads + 1, "the follower read twice")
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 2 })
        #expect(store.isRefreshing && store.refreshTask != nil)
        runner.release(1)
        #expect(await waitUntil(timeout: .seconds(10)) { followerDone.value })
        #expect(store.error == nil)
        #expect(runner.maxInFlight == 1)
        #expect(!store.isRefreshing && store.refreshTask == nil)

        // On its own, a failed read also ends idle: a later automatic
        // refresh reads again rather than joining a stale task.
        runner.inner.failInfo = true
        let alone = Box(false)
        Task { await store.refresh(.automatic); alone.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 3 })
        runner.release(2)
        #expect(await waitUntil(timeout: .seconds(10)) { alone.value })
        #expect(store.error != nil)
        #expect(!store.isRefreshing && store.refreshTask == nil)
        runner.inner.failInfo = false
        let again = Box(false)
        Task { await store.refresh(.automatic); again.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 4 })
        runner.release(3)
        #expect(await waitUntil(timeout: .seconds(10)) { again.value })
        #expect(store.error == nil)
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }

    /// Automatic refreshes asked for during a read all join it: no read of
    /// their own, none after it, and none returns before the read ends.
    @Test(.timeLimit(.minutes(1))) func automaticRefreshesDuringAReadJoinIt() async throws {
        let (store, runner, _, _) = await rig()
        defer { runner.openAll() }
        let reads = store.refreshesStarted
        let done = Box(0), entered = Box(0)
        Task { await store.refresh(.automatic); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        // Each counts itself in the same main-actor job that enters
        // refresh and reaches its wait on the running read.
        for _ in 0..<3 { Task { entered.value += 1; await store.refresh(.automatic); done.value += 1 } }
        try #require(await waitUntil(timeout: .seconds(10)) { entered.value == 3 })
        try await Task.sleep(for: .milliseconds(50))
        await Task.yield()
        // All three are in refresh, joined to the read: none has returned
        // and none started a read while the gate is closed.
        #expect(done.value == 0, "an automatic refresh returned before the read it joined ended")
        #expect(store.refreshesStarted == reads + 1)
        #expect(runner.started == 1)
        #expect(store.isRefreshing && store.refreshTask != nil)
        runner.release(0)
        #expect(await waitUntil(timeout: .seconds(10)) { done.value == 4 })
        await Task.yield()
        #expect(store.refreshesStarted == reads + 1)
        #expect(runner.started == 1)
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }
}

/// A task executor that, once told to hold, keeps every job enqueued on
/// it until opened. A task started with it as its preference wakes on it
/// from a wait on another task, so holding it holds that task's resumption
/// (before it hops to its actor) without touching the main actor.
@available(macOS 15.0, *)
final class HeldResumption: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "V093RefreshJoinTests.HeldResumption")
    private var holding = false
    private var held: [UnownedJob] = []

    func enqueue(_ job: UnownedJob) {
        let now: Bool = lock.withLock {
            if holding { held.append(job); return false }
            return true
        }
        if now { run(job) }
    }

    /// Jobs enqueued from now on wait for `open()`.
    func hold() { lock.withLock { holding = true } }
    /// How many jobs are being held.
    var count: Int { lock.withLock { held.count } }
    /// Runs the held jobs (in order) and stops holding. Safe to call twice.
    func open() {
        let jobs: [UnownedJob] = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        for job in jobs { run(job) }
    }

    private func run(_ job: UnownedJob) {
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

extension V092RefreshJoinTests.GatedInfo {
    /// Stops gating new reads and opens every gate so far, so a test that
    /// stops early leaves no read suspended. Safe to call after the test
    /// opened them itself.
    func openAll() {
        gating = false
        for i in 0..<started { release(i) }
    }
}
