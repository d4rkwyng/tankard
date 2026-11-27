import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 5: the R4 review's findings, against fake Homebrew.

/// Fake Homebrew whose status reads fail once `failAfter` is seen (the
/// change succeeded; the read after it doesn't).
@MainActor
private func v094R5FailingReads(_ variant: Demo.Variant = .intelbrew, failAfter command: String)
    throws -> (AppStore.Dependencies, V094StatusRunner) {
    var deps = Demo.dependencies(variant, pace: 0, pinned: ["ruby"])
    let reads = try v094WrapStatus(&deps)
    let demo = deps.streamRunner
    deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
        let code = try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        if args.first == command, code == 0 { reads.fail = true }
        return code
    }
    return (deps, reads)
}

/// A formula the plain Upgrade starts without a plan.
@MainActor
private func v094R5PlainFormula(_ store: AppStore) throws -> Package {
    try #require(store.upgradable.first {
        $0.kind == .formula && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
    })
}

// MARK: MUST-FIX 1: every successful change marks the list stale

@MainActor
struct V094R5StaleAtEveryChangeTests {
    /// Refresh's `brew update` succeeded and its read failed: the list on
    /// screen is older than brew's metadata; an Upgrade waits.
    @Test func aManualRefreshsUpdateThenAFailedRead() async throws {
        let (deps, reads) = try v094R5FailingReads(failAfter: "update")
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        try #require(!store.statusStale)
        let f = try v094R5PlainFormula(store)
        await store.refresh(manual: true)
        #expect(store.statusStale, "brew update moved the metadata; the read after it failed")
        store.requestUpgrade([f])
        #expect(store.upgrade == nil, "no upgrade against the old list")
        reads.fail = false
        #expect(await store.refreshAfterChange())
        #expect(!store.statusStale)
    }

    /// A Refresh whose read succeeds is fresh.
    @Test func aManualRefreshThatReadsIsFresh() async throws {
        let (deps, reads) = try v094R5FailingReads(failAfter: "never")
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        await store.refresh(manual: true)
        #expect(!reads.fail)
        #expect(!store.statusStale)
    }

    /// The background updater's `brew update` succeeded and its follow-up
    /// read failed.
    @Test func aBackgroundUpdateThenAFailedRead() async throws {
        let (deps, _) = try v094R5FailingReads(failAfter: "update")
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        try #require(!store.statusStale)
        let f = try v094R5PlainFormula(store)
        #expect(await store.runBackgroundUpdate() == false, "its read failed")
        #expect(store.statusStale)
        store.startUpgrade([f])
        #expect(store.upgrade == nil)
    }

    /// A finished foreground upgrade and a failed read after it: the
    /// pre-upgrade inventory is stale (Clean Up's keep list and an Upgrade
    /// wait for a fresh one).
    @Test func aForegroundUpgradeThenAFailedRead() async throws {
        let (deps, _) = try v094R5FailingReads(failAfter: "upgrade")
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let f = try v094R5PlainFormula(store)
        let reads = store.refreshesCompleted
        store.startUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && store.refreshesCompleted > reads && !store.isRefreshing })
        #expect(s.succeededCount == 1)
        #expect(store.statusStale, "the list on screen is the pre-upgrade one")
        store.closeUpgrade()
        store.startCleanup()
        #expect(store.upgrade?.action != .cleanup, "Clean Up waits for a fresh read")
        let g = try #require(store.upgradable.first { $0.id != f.id && $0.kind == .formula })
        store.requestUpgrade([g])
        #expect(store.upgrade?.action != .upgrade || store.upgrade === s)
    }
}

@MainActor
struct V094R5RunEndFreshTests {
    /// The run's follow-up read succeeds: fresh, and a retry right after
    /// the run isn't held.
    @Test func aForegroundUpgradeThenASuccessfulRead() async throws {
        let (deps, _) = try v094R5FailingReads(failAfter: "never")
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let f = try v094R5PlainFormula(store)
        let reads = store.refreshesCompleted
        store.startUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && store.refreshesCompleted > reads && !store.isRefreshing })
        #expect(!store.statusStale)
    }

    /// A failed follow-up read doesn't mark stale over a read begun after
    /// the run that succeeded.
    @Test func aLaterSuccessfulReadWins() async throws {
        let store = await v094R4RigForR5()
        let at = store.refreshesStarted
        #expect(await store.refreshAfterChange())
        store.markStatusStale(afterFailedReadSince: at)
        #expect(!store.statusStale)
        store.markStatusStale(afterFailedReadSince: store.refreshesStarted)
        #expect(store.statusStale)
    }
}

@MainActor
private func v094R4RigForR5() async -> AppStore {
    var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
    deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
    let store = AppStore(deps: deps, settings: testSettings())
    await store.start()
    return store
}

