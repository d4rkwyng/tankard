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

// MARK: MUST-FIX 2: explicit targets as the list says now

@MainActor
struct V094R5CapturedTargetTests {
    func rig() async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return store
    }

    func markUpgraded(_ store: AppStore, _ p: Package) throws {
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.id == p.id })
        r.packages[i].installedVersion = p.currentVersion ?? "9"
        r.packages[i].installedVersions = [r.packages[i].installedVersion]
        r.packages[i].upgradeAvailable = false
        store.report = r
    }

    func remove(_ store: AppStore, _ p: Package) throws {
        var r = try #require(store.report)
        r.packages.removeAll { $0.id == p.id }
        store.report = r
    }

    /// "Upgrade the Remaining": one target upgraded meanwhile, one removed:
    /// neither is queued; the one still outdated is.
    @Test func upgradeTheRemainingUsesTheListNow() async throws {
        let store = await rig()
        let fs = store.upgradable.filter {
            $0.kind == .formula && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        }
        try #require(fs.count >= 3)
        store.interruptedRun = InterruptedRunOffer(packages: Array(fs.prefix(3)), total: 3)
        try markUpgraded(store, fs[0])
        try remove(store, fs[1])
        try #require(!store.statusStale)
        store.interruptedRunConfirm()
        let ids = store.upgrade?.items.map(\.package.id) ?? store.upgradePlan?.rows.map(\.package.id) ?? []
        #expect(ids == [fs[2].id])
    }

    /// Every captured target gone: nothing runs.
    @Test func upgradeTheRemainingWithNothingLeft() async throws {
        let store = await rig()
        let f = try v094R5PlainFormula(store)
        store.interruptedRun = InterruptedRunOffer(packages: [f], total: 1)
        try markUpgraded(store, f)
        store.interruptedRunConfirm()
        #expect(store.upgrade == nil)
        #expect(store.upgradePlan == nil)
    }

    /// The Upgrade button with a captured package removed since.
    @Test func theUpgradeButtonUsesTheListNow() async throws {
        let store = await rig()
        let f = try v094R5PlainFormula(store)
        try remove(store, f)
        store.requestUpgrade([f])
        #expect(store.upgrade == nil, "a removed package isn't queued")
        #expect(store.upgradePlan == nil)
    }

    /// The list's current copy is the one queued (its versions now).
    @Test func theQueuedPackageIsTheCurrentCopy() async throws {
        let store = await rig()
        var f = try v094R5PlainFormula(store)
        let current = f.currentVersion
        f.currentVersion = "0.0.0-captured"
        store.requestUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.currentVersion) == [current])
        #expect(await waitUntil { s.isFinished })
    }

    /// Sheet Retry: the failed package was removed meanwhile: it isn't
    /// queued from the failed step's copy.
    @Test func retryDoesntFallBackToTheFailedStepsCopy() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("Error: simulated failure\n".utf8))
            return 1
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let f = try v094R5PlainFormula(store)
        store.startUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !store.isRefreshing })
        try #require(s.retryableItems.map(\.package.id) == [f.id])
        try remove(store, f)
        store.retryInSheet()
        #expect(store.upgrade === s, "nothing new was queued")
        #expect(store.upgradePlan == nil)
        #expect(store.error?.title == "Nothing to retry")
    }
}

// MARK: MUST-FIX 3: Clean Up compares the inherited keep list too

/// The client's inherited HOMEBREW_NO_CLEANUP_FORMULAE (the app's
/// environment), changed by the next Refresh's settings reload.
final class V094R5InheritedKeep: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ v: String) { _value = v }
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor
struct V094R5InheritedKeepListTests {
    /// `f` with an old version on disk in every read.
    func rig() async throws -> (AppStore, V094R5InheritedKeep, kept: String, added: String) {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let inherited = V094R5InheritedKeep("tankard-r5-a")
        let reads = try v094WrapStatus(&deps) { c in
            c.sources.process[CleanupKeep.key] = inherited.value
        }
        deps.reloadSources = { c in
            var s = c.sources
            s.process[CleanupKeep.key] = inherited.value
            return s
        }
        deps.brewEnvFiles = { _ in [] }
        // Two of the demo's formulae: `f` has an old version on disk.
        let f = "xz", added = "sqlite"
        reads.transform = { data in Self.addOldVersion(of: f, to: data) }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = true
        return (store, inherited, f, added)
    }

    /// The info JSON with a second (older) installed version of `name`.
    nonisolated static func addOldVersion(of name: String, to data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var formulae = json["formulae"] as? [[String: Any]],
              let i = formulae.firstIndex(where: { $0["name"] as? String == name }),
              var installed = formulae[i]["installed"] as? [[String: Any]], var old = installed.first
        else { return data }
        old["version"] = "0.0.1"
        installed.insert(old, at: 0)
        formulae[i]["installed"] = installed
        json["formulae"] = formulae
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    @Test func theInheritedListIsAnInput() async throws {
        let (store, inherited, f, added) = try await rig()
        let before = try #require(store.currentCleanupInputs())
        inherited.value = "tankard-r5-a,\(added)"
        await store.refresh(manual: true)
        try #require(store.packages.first { $0.name == f }?.installedVersions.count == 2)
        let after = try #require(store.currentCleanupInputs())
        #expect(before.inventory == after.inventory)
        #expect(before != after, "the keep list brew gets changed")
    }

    /// The preview was made with the old inherited list; a Refresh added a
    /// formula to it. Clean Up works the preview out again, and the run
    /// protects that formula (and Tankard's own kept one).
    @Test func cleanUpKeepsTheNewlyInheritedFormula() async throws {
        let (store, inherited, f, added) = try await rig()
        store.openCleanup()
        let old = try #require(store.cleanup)
        #expect(await waitUntil { old.phase == .ready })
        #expect(old.kept == [f])
        inherited.value = "tankard-r5-a,\(added)"
        await store.refresh(manual: true)
        #expect(!store.statusStale)
        store.startCleanup()
        if store.upgrade == nil {
            let fresh = try #require(store.cleanup)
            #expect(fresh !== old)
            #expect(await waitUntil { fresh.phase == .ready })
            store.startCleanup()
        }
        let s = try #require(store.upgrade)
        #expect(s.action == .cleanup)
        let keep = try #require(s.items.first?.command.environment[CleanupKeep.key])
        let names = Set(keep.split(separator: ",").map(String.init))
        #expect(names.contains(added), "the newly protected formula's old version stays")
        #expect(names.contains(f))
        #expect(names.contains("tankard-r5-a"))
    }
}

// MARK: MUST-FIX 4: no preview is no excuse to drop the keep list

@MainActor
struct V094R5NoPreviewTests {
    @Test func aDirectStartStillKeepsRetainedVersions() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = true
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.kind == .formula && Set($0.installedVersions).count == 1 })
        r.packages[i].installedVersions = ["0.0.1", r.packages[i].installedVersion]
        store.report = r
        let f = r.packages[i]
        try #require(store.cleanup == nil)
        store.startCleanup()
        let s = try #require(store.upgrade, "the direct start still runs")
        #expect(s.action == .cleanup)
        let keep = s.items.first?.command.environment[CleanupKeep.key] ?? ""
        #expect(keep.split(separator: ",").map(String.init).contains(f.name),
                "with no preview, “Keep the previous version” still keeps it")
        #expect(s.items.first?.command.display.contains(CleanupKeep.key) == true, "and the command shown says so")
    }

    /// The setting off: a direct start adds nothing (as before).
    @Test func aDirectStartWithKeepOffAddsNothing() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = false
        store.startCleanup()
        let s = try #require(store.upgrade)
        #expect(s.items.first?.command.environment[CleanupKeep.key] == nil)
        #expect(s.items.first?.command.display == "brew cleanup")
    }
}

// MARK: SHOULD-FIX: reconciliation by package, not short name

/// The formulae fake brew upgraded so far.
final class V094R5Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var all: [String] { lock.withLock { names } }
    func add(_ n: String) { lock.withLock { names.append(n) } }
}

@MainActor
struct V094R5ReconcileByIDTests {
    /// Auto-update upgrades formula `n`; the read after it also lists an
    /// outdated cask named `n`. The formula's upgrade stands.
    @Test func aSameNameCaskDoesntFailTheFormula() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let reads = try v094WrapStatus(&deps)
        let demo = deps.streamRunner
        let names = V094R5Names()
        reads.transform = { data in names.all.reduce(data) { V094R5ReconcileByIDTests.addOutdatedCask(named: $1, to: $0) } }
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            let code = try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
            if args.first == "upgrade", args.contains("--formula"), code == 0, let q = args.last {
                names.add(q.split(separator: "/").last.map(String.init) ?? q)
            }
            return code
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: nil))
        let name = try #require(run.upgraded.first { !$0.isCask }?.name ?? run.failed.first { !$0.isCask }?.name)
        #expect(store.packages.contains { $0.kind == .cask && $0.name == name && $0.upgradeAvailable },
                "the read lists the same-name cask as outdated")
        #expect(store.packages.contains { $0.kind == .formula && $0.name == name && !$0.upgradeAvailable })
        #expect(run.upgraded.contains { $0.name == name && !$0.isCask })
        #expect(!run.failed.contains { $0.name == name && $0.detail == "still outdated after brew upgrade" })
    }

    /// The JSON with an outdated cask whose token is `name`.
    nonisolated static func addOutdatedCask(named name: String, to data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        var casks = json["casks"] as? [[String: Any]] ?? []
        guard !casks.contains(where: { $0["token"] as? String == name }) else { return data }
        let cask: [String: Any] = [
            "token": name, "full_token": name, "tap": "homebrew/cask", "name": [name], "desc": NSNull(),
            "homepage": "https://example.com", "url": "https://example.com/\(name).dmg",
            "version": "2.0", "installed": "1.0", "installed_time": 1_700_000_000, "outdated": true,
            "auto_updates": false, "deprecated": false, "disabled": false, "artifacts": [[String: Any]](),
            "depends_on": [String: Any](), "conflicts_with": NSNull(), "caveats": NSNull(),
        ]
        casks.append(cask)
        json["casks"] = casks
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
