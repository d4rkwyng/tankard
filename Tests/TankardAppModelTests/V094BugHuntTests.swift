import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt (item 1): user-facing bugs found against fake Homebrew.

// MARK: a quiet scheduled check keeps the refresh failure

// A Refresh whose brew update failed (offline) shows "Last refresh failed"
// and the error banner. A scheduled check (notifications, Auto-update)
// that then also couldn't reach the network is quiet: it shows nothing.
// It used to clear the earlier failure too, so the window said "Updated
// just now" / "Everything is up to date" although no update had succeeded,
// and the saved failure record was deleted.
extension AppStoreTests {
    static let unreachableUpdate: @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { args, output in
        guard args.first == "update" else { output(Data("ok\n".utf8)); return 0 }
        output(Data("fatal: unable to access 'https://github.com/Homebrew/brew/': Failed to connect to 127.0.0.1 port 3128\n".utf8))
        return 1
    }

    @Test func aQuietScheduledCheckKeepsTheRefreshFailure() async throws {
        let r = try rig(stream: Self.unreachableUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        let failed = try #require(r.store.error)
        #expect(r.store.upgradeCheckFailed)
        #expect(r.store.settings.lastUpdateFailure != nil)

        await r.store.refresh(.scheduled)
        #expect(r.store.lastScheduledUpdate?.quiet == .offline)
        #expect(r.log.count("update") == 2)
        #expect(r.store.error == failed)
        #expect(r.store.upgradeCheckFailed)
        #expect(r.store.settings.lastUpdateFailure != nil)
    }

    /// Without an earlier failure a quiet scheduled check still shows nothing.
    @Test func aQuietScheduledCheckAloneShowsNoError() async throws {
        let r = try rig(stream: Self.unreachableUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(.scheduled)
        #expect(r.store.lastScheduledUpdate?.quiet == .offline)
        #expect(r.store.error == nil)
        #expect(!r.store.upgradeCheckFailed)
    }
}

// MARK: Upgrade while an automatic update runs

// An Auto-update run has the queue, so startSession refuses a new run.
// The window's Upgrade buttons stayed on (a click did nothing), and an
// upgrade plan confirmed meanwhile was cleared before the refused start:
// the sheet stayed up with no plan and no run, so no buttons at all.
@MainActor
struct V094AutoUpdateBlocksUpgradeTests {
    func runningAutoUpdate() async throws -> (AppStore, Latch, Task<AutoUpdateRun?, Never>) {
        let gate = Latch()
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "fetch" { await gate.wait() }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: nil) }
        try #require(await waitUntil { u.isRunning && u.activity?.hasPrefix("Auto-update: downloading") == true })
        return (store, gate, task)
    }

    @Test func aPlanConfirmedDuringAutoUpdateStaysOnScreen() async throws {
        let (store, gate, task) = try await runningAutoUpdate()
        let targets = store.upgradable
        try #require(!targets.isEmpty && !store.isUpgrading)
        // The plan was open before the automatic run started.
        store.upgradePlan = UpgradePlan(packages: targets, classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil)
        // Not an empty sheet: the plan is still what it shows.
        #expect(store.upgradePlan != nil)
        #expect(store.showUpgradeSheet)
        gate.release()
        _ = await task.value
        #expect(await waitUntil { !store.autoUpdate.isRunning && !store.isRefreshing })
        // Once it's done, the same plan starts.
        store.confirmUpgradePlan()
        #expect(store.upgradePlan == nil)
        #expect(store.upgrade != nil)
    }

    @Test func theWindowsUpgradeButtonsWaitForAutoUpdate() async throws {
        let (store, gate, task) = try await runningAutoUpdate()
        #expect(!store.isUpgrading)
        #expect(store.windowBrewActionsBlocked)
        // A click that got through anyway opens nothing it can't start.
        store.requestUpgrade()
        #expect(store.upgradePlan == nil && store.upgrade == nil && !store.showUpgradeSheet)
        gate.release()
        _ = await task.value
        #expect(await waitUntil { !store.autoUpdate.isRunning })
        #expect(!store.windowBrewActionsBlocked)
    }
}

// MARK: a lock wait that runs out says brew was busy

// A step that found brew's lock held waits for it (BrewLockWait). When
// the wait ran out, the step failed with brew's "already locked" output
// thrown away (cleared when the wait began), so the sheet said only "The
// log below shows what brew printed", with no "Another Homebrew command
// is running" and no next step. History, which keeps that output, said
// it was locked.
@MainActor
struct V094LockWaitTimeoutTests {
    @Test func aWaitThatRunsOutFailsAsLocked() async throws {
        let calls = CallLog()
        let client = makeClient(FakeInfoRunner(log: calls, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: calls, behaviour: { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data(V083LockWaitTests.lockedLine.utf8))
            return 1
        })
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil)
        deps.lockWait = BrewLockWait(interval: .milliseconds(10), limit: .milliseconds(150), maxAttempts: 5,
                                     holders: { _ in ["4312 /bin/bash /opt/homebrew/Library/Homebrew/brew.sh install ffmpeg"] })
        let store = AppStore(deps: deps)
        await store.start()
        let pkg = try #require(store.upgradable.first)
        store.startUpgrade([pkg])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.lockWait != nil })
        #expect(await waitUntil { s.isFinished })
        #expect(calls.count("upgrade") == 1, "the lock never came free: brew ran once")
        #expect(s.items[0].state == .failed(1))
        #expect(s.failureKinds == [.locked])
        #expect(s.nextStep != nil)
    }
}
