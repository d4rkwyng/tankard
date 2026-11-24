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

    func rig() async -> (AppStore, GatedInfo, CallLog) {
        let log = CallLog()
        let runner = GatedInfo(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let client = makeClient(runner)
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client },
                                                         streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                                         cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        #expect(await waitUntil { !store.isRefreshing })
        runner.gating = true
        return (store, runner, log)
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
        let (store, runner, log) = await rig()
        let reads = store.refreshesStarted
        let done = Box(0)
        Task { await store.refresh(.automatic); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        Task { await store.refresh(.manual); done.value += 1 }
        Task { await store.refresh(.scheduled); done.value += 1 }
        Task { await store.refresh(.afterUpdate); done.value += 1 }
        try await Task.sleep(for: .milliseconds(50)) // they reach their wait (the read can't end yet)
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
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }

    /// The second half of the fix, alone: the read's own caller resumes
    /// after a waiter has started its read, and must not clear that read's
    /// task. While it runs, an automatic refresh joins it (no new read) and
    /// returns only when it ends; a scheduled check waits for it.
    @Test(.timeLimit(.minutes(1))) func theCallerOfAFinishedReadLeavesTheNextReadsTask() async throws {
        let (store, runner, _) = await rig()
        let reads = store.refreshesStarted
        let firstDone = Box(false), followerDone = Box(false)
        Task { await store.refresh(.automatic); firstDone.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        Task { await store.refresh(.afterUpdate); followerDone.value = true }
        try await Task.sleep(for: .milliseconds(50))
        runner.release(0)
        try await expectOneMoreRead(store, reads + 1, "the follower read twice")
        #expect(await waitUntil(timeout: .seconds(10)) { firstDone.value })
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 2 })
        // The first caller has resumed (and cleared what it may clear).
        #expect(store.isRefreshing)
        #expect(store.refreshTask != nil, "the first read's caller cleared the follower's task")

        let joined = Box(false), scheduled = Box(false)
        Task { await store.refresh(.automatic); joined.value = true }
        Task { await store.refresh(.scheduled); scheduled.value = true }
        try await Task.sleep(for: .milliseconds(50))
        await Task.yield()
        #expect(store.refreshesStarted == reads + 2, "a refresh started a read beside the follower's")
        #expect(runner.running == 1)
        #expect(!joined.value, "the automatic refresh returned before the read it joined ended")

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
        let (store, runner, _) = await rig()
        let reads = store.refreshesStarted
        runner.inner.failInfo = true
        let firstDone = Box(false), followerDone = Box(false)
        Task { await store.refresh(.automatic); firstDone.value = true }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        Task { await store.refresh(.afterUpdate); followerDone.value = true }
        try await Task.sleep(for: .milliseconds(50))
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
    /// their own, and none after it.
    @Test(.timeLimit(.minutes(1))) func automaticRefreshesDuringAReadJoinIt() async throws {
        let (store, runner, _) = await rig()
        let reads = store.refreshesStarted
        let done = Box(0)
        Task { await store.refresh(.automatic); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        for _ in 0..<3 { Task { await store.refresh(.automatic); done.value += 1 } }
        try await Task.sleep(for: .milliseconds(50))
        runner.release(0)
        #expect(await waitUntil(timeout: .seconds(10)) { done.value == 4 })
        await Task.yield()
        #expect(store.refreshesStarted == reads + 1)
        #expect(runner.started == 1)
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }
}
