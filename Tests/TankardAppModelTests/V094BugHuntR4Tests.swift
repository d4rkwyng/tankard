import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 4: the R3 review's findings, against fake Homebrew.

@MainActor
private func v094R4Rig(_ variant: Demo.Variant = .arm64, gate: Bool = false, running: [RunningApp] = []) async -> AppStore {
    var deps = Demo.dependencies(variant, pace: 0)
    deps.appManagementGate = gate
    deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
    let settings = testSettings()
    InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true
    let store = AppStore(deps: deps, settings: settings)
    store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: running)
    await store.start()
    return store
}

/// `p` as no longer outdated (Auto-update upgraded it).
@MainActor
private func v094R4Upgraded(_ store: AppStore, _ p: Package) throws {
    var r = try #require(store.report)
    let i = try #require(r.packages.firstIndex { $0.id == p.id })
    r.packages[i].installedVersion = p.currentVersion ?? "9"
    r.packages[i].installedVersions = [r.packages[i].installedVersion]
    r.packages[i].upgradeAvailable = false
    store.report = r
}

// MARK: MUST-FIX 1: every upgrade waits for a fresh status

@MainActor
struct V094R4FreshnessTests {
    /// A selected package's Upgrade (no plan needed) and the plain start
    /// both wait for a read after brew's change.
    @Test func aPlainUpgradeWaitsForAFreshRead() async throws {
        let store = await v094R4Rig()
        let f = try #require(store.upgradable.first {
            $0.kind == .formula && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        })
        store.markStatusStale()
        store.requestUpgrade([f])
        #expect(store.upgrade == nil, "no upgrade against the old list")
        #expect(store.upgradePlan == nil)
        store.startUpgrade([f])
        #expect(store.upgrade == nil, "nor through the plain start (the menu bar's)")
        #expect(await waitUntil { !store.statusStale && !store.isRefreshing })
        store.requestUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.id) == [f.id])
        #expect(await waitUntil { s.isFinished })
    }

    /// Auto-update's brew update succeeded and the read after it failed:
    /// the list on screen is older than brew's metadata, so an open plan
    /// waits.
    @Test func aFailedReadAfterBrewUpdateMarksTheStatusStale() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let reads = try v094WrapStatus(&deps)
        let demo = deps.streamRunner
        let upgrades = V094AutoUpdateBlocksUpgradeTests.Failing()
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            let code = try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
            // The update succeeds; every read after it fails.
            if args.first == "update" { reads.fail = true }
            if args.first == "upgrade" { upgrades.set(["ran"]) }
            return code
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let before = store.upgradable
        try #require(!before.isEmpty)
        try #require(!store.statusStale)
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: nil))
        #expect(run.note != nil, "the read failed: no run")
        #expect(!upgrades.contains("ran"))
        #expect(store.statusStale, "brew update moved the metadata")

        store.upgradePlan = UpgradePlan(packages: before, classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil, "the plan waits")
        #expect(store.upgradePlan != nil)
        #expect(await waitUntil { !store.isRefreshing })
        #expect(store.statusStale, "that re-read failed too")

        reads.fail = false
        #expect(await store.refreshAfterChange())
        #expect(!store.statusStale)
    }

    /// A scheduled read that succeeds right after its update isn't stale.
    @Test func aSuccessfulScheduledReadIsFresh() async throws {
        let store = await v094R4Rig(.intelbrew)
        await store.refresh(.scheduled)
        #expect(store.lastScheduledUpdate?.succeeded == true)
        #expect(!store.statusStale)
    }
}

// MARK: MUST-FIX 2: Run Again resolves its targets again

@MainActor
struct V094R4RunAgainTests {
    func offer(_ store: AppStore, _ packages: [Package]) {
        store.appManagementResume = AppManagementResume(action: .upgrade, packages: packages, dropped: [])
        store.showUpgradeSheet = true
    }

    /// Auto-update upgraded one target while the offer was up: Run Again
    /// shows the plan without it instead of forwarding the captured one.
    @Test func runAgainShowsWhatChanged() async throws {
        let store = await v094R4Rig()
        let fs = Array(store.upgradable.filter { $0.kind == .formula }.prefix(2))
        try #require(fs.count == 2)
        offer(store, fs)
        try v094R4Upgraded(store, fs[0])
        store.appManagementResumeConfirm()
        #expect(store.upgrade == nil, "nothing captured runs")
        #expect(store.appManagementResume == nil)
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.map(\.package.id) == [fs[1].id])
        #expect(plan.changedNote != nil)
        #expect(store.showUpgradeSheet)
        store.confirmUpgradePlan()
        #expect(store.upgrade?.items.map(\.package.id) == [fs[1].id])
    }

    /// Everything upgraded meanwhile: the plan says so, nothing runs.
    @Test func runAgainWithNothingLeft() async throws {
        let store = await v094R4Rig()
        let f = try #require(store.upgradable.first { $0.kind == .formula })
        offer(store, [f])
        try v094R4Upgraded(store, f)
        store.appManagementResumeConfirm()
        #expect(store.upgrade == nil)
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.isEmpty)
        #expect(plan.changedNote != nil)
    }

    /// A stale status keeps the offer and asks for a read.
    @Test func runAgainWaitsForAFreshRead() async throws {
        let store = await v094R4Rig()
        let f = try #require(store.upgradable.first {
            $0.kind == .formula && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        })
        offer(store, [f])
        store.markStatusStale()
        store.appManagementResumeConfirm()
        #expect(store.appManagementResume != nil, "the offer stays")
        #expect(store.upgrade == nil)
        #expect(await waitUntil { !store.statusStale && !store.isRefreshing })
        store.appManagementResumeConfirm()
        #expect(store.appManagementResume == nil)
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.id) == [f.id])
        #expect(await waitUntil { s.isFinished })
    }

    /// An app open now shows in the plan before Run Again's upgrade.
    @Test func runAgainNamesAnAppOpenNow() async throws {
        let store = await v094R4Rig(running: [V085RunningAppsTests.chrome])
        let c = try #require(store.packages.first { $0.name == "google-chrome" && $0.isManualUpgradeTarget })
        offer(store, [c])
        store.appManagementResumeConfirm()
        #expect(store.upgrade == nil)
        #expect(store.upgradePlan?.runningAppsToRun == ["Google Chrome"])
    }
}

// MARK: MUST-FIX 3: every open app of a cask, by identity

@MainActor
struct V094R4RunningAppIdentityTests {
    static let canary = RunningApp(path: "/Applications/Google Chrome Canary.app", bundleID: "com.google.Chrome.canary")

    /// google-chrome with a second app.
    func rig(gate: Bool) async throws -> (AppStore, Package) {
        let store = await v094R4Rig(gate: gate, running: [V085RunningAppsTests.chrome])
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.name == "google-chrome" && $0.isManualUpgradeTarget })
        r.packages[i].appPaths = ["/Applications/Google Chrome.app", Self.canary.path!]
        store.report = r
        return (store, r.packages[i])
    }

    func open(_ store: AppStore, _ app: RunningApp) throws {
        let conditions = try #require(store.autoUpdate.conditions as? FixedConditions)
        conditions.apps.append(app)
    }

    @Test func everyOpenAppOfACaskIsNamed() async throws {
        let (store, c) = try await rig(gate: false)
        try open(store, Self.canary)
        let apps = store.runningCaskApps([c])
        #expect(apps.map(\.name) == ["Google Chrome", "Google Chrome Canary"])
        #expect(Set(apps.map(\.identity)).count == 2)
    }

    /// The App Management prompt acknowledged Chrome; Canary opened while
    /// it was up: Continue shows the plan naming it.
    @Test func continueNamesASecondAppOfAnAcknowledgedCask() async throws {
        let (store, c) = try await rig(gate: true)
        try #require(!store.settings.appManagementExplained)
        var plan = UpgradePlan(packages: [c], classifier: store.deps.classifier)
        plan.runningApps = store.runningCaskApps([c])
        try #require(plan.runningAppsToRun == ["Google Chrome"])
        store.upgradePlan = plan
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.acknowledgedRunningApps == [c.id])
        #expect(prompt.acknowledgedApps.map(\.name) == ["Google Chrome"])
        try open(store, Self.canary)
        store.appManagementContinue()
        #expect(store.upgrade == nil, "the newly open app shows first")
        let again = try #require(store.upgradePlan)
        #expect(Set(again.runningAppsToRun) == ["Google Chrome", "Google Chrome Canary"])
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
    }

    /// The open plan names Chrome; Canary opens before Upgrade: the plan
    /// shows it first.
    @Test func thePlanNamesASecondAppBeforeRunning() async throws {
        let (store, c) = try await rig(gate: false)
        store.requestUpgrade([c])
        try #require(store.upgradePlan?.runningAppsToRun == ["Google Chrome"])
        try open(store, Self.canary)
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil)
        #expect(Set(store.upgradePlan?.runningAppsToRun ?? []) == ["Google Chrome", "Google Chrome Canary"])
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
    }
}

// MARK: MUST-FIX 4: Clean Up's preview follows the retention settings

@MainActor
struct V094R4CleanupRetentionTests {
    func rig() async throws -> (AppStore, Package) {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = false
        // A formula with two versions on disk.
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.kind == .formula && Set($0.installedVersions).count == 1 })
        r.packages[i].installedVersions = ["0.0.1", r.packages[i].installedVersion]
        store.report = r
        return (store, r.packages[i])
    }

    /// "Keep the previous version" turned on with the sheet open: Clean Up
    /// shows the preview again with the kept version instead of running.
    @Test func turningKeepOnRebuildsThePreview() async throws {
        let (store, f) = try await rig()
        store.openCleanup()
        let old = try #require(store.cleanup)
        #expect(await waitUntil { old.phase == .ready })
        #expect(!old.kept.contains(f.name))
        store.restorePoints.settings.keepPreviousVersion = true
        store.startCleanup()
        #expect(store.upgrade == nil, "not with the old keep list")
        #expect(store.showCleanupSheet)
        let fresh = try #require(store.cleanup)
        #expect(fresh !== old)
        #expect(fresh.keepPrevious)
        #expect(fresh.kept.contains(f.name))
        #expect(await waitUntil { fresh.phase == .ready })
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }

    /// A preview whose dry run hasn't answered doesn't run.
    @Test func aPendingDryRunDoesntRun() async throws {
        let (store, _) = try await rig()
        store.openCleanup()
        let c = try #require(store.cleanup)
        try #require(c.phase != .ready)
        store.startCleanup()
        #expect(store.upgrade == nil)
        #expect(await waitUntil { c.phase == .ready })
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }
}

// MARK: SHOULD-FIX 1: a failed reconciliation read decides nothing

@MainActor
struct V094R4ReconcileTests {
    @Test func aFailedReadDoesntCallUpgradesStillOutdated() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let reads = try v094WrapStatus(&deps)
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade" { reads.fail = true }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: nil))
        #expect(!run.upgraded.isEmpty, "brew said each upgrade succeeded")
        #expect(!run.failed.contains { $0.detail == "still outdated after brew upgrade" })
        #expect(store.statusStale, "the list is still the old one")
    }
}

// MARK: SHOULD-FIX 2: the sheets offer a Refresh while the status is stale

@MainActor
struct V094R4StaleRefreshTests {
    @Test func theSheetsRefreshReadsAgain() async throws {
        let store = await v094R4Rig()
        store.markStatusStale()
        let started = store.refreshesStarted
        store.refreshStaleStatus()
        #expect(await waitUntil { !store.statusStale && !store.isRefreshing })
        #expect(store.refreshesStarted > started)
    }

    @Test func bothSheetsShowIt() throws {
        let activity = try v094Source("TankardApp/ActivitySheets.swift")
        #expect(activity.components(separatedBy: "if store.statusStale {").count - 1 == 2)
        #expect(activity.components(separatedBy: "StaleStatusNote(store: store)").count - 1 == 2)
        #expect(activity.contains("store.refreshStaleStatus()"))
    }
}

// MARK: SHOULD-FIX 3: an unknown bottle may compile; it isn't certain

struct V094R4UnknownBottleCopyTests {
    @Test func theCopySaysItMayCompile() {
        let ghost = CatalogEntry(kind: .formula, name: "ghost", fullName: "ghost", tap: "homebrew/core", desc: nil, bottle: .unknown,
                                 detailsLoaded: true)
        let m = ContextMenus.discoverInstall(ghost, compileWarning: nil, busy: false)
        #expect(m.action == .install(confirmCompile: true))
        #expect(m.title == "Install ghost (may compile)…")
        #expect(ContextMenus.bottleUnverified(ghost, compileWarning: nil))
        let text = InstallCompileText.unverifiedMessage(name: "ghost", intelbrew: false)
        #expect(text.contains("couldn't check whether ghost has a bottle"))
        #expect(!text.contains("so brew compiles it"))
        #expect(InstallCompileText.unverifiedMessage(name: "ghost", intelbrew: true).contains("Intelbrew bottle"))

        let src = CatalogEntry(kind: .formula, name: "src", fullName: "src", tap: "homebrew/core", desc: nil, bottle: .fromSource,
                               detailsLoaded: true)
        let w = CompileClassifier().installWarning(src)
        #expect(w != nil)
        #expect(!ContextMenus.bottleUnverified(src, compileWarning: w))
        #expect(ContextMenus.discoverInstall(src, compileWarning: w, busy: false).title == "Install src (compiles)…")
    }

    @Test func theConfirmationUsesIt() throws {
        let activity = try v094Source("TankardApp/ActivitySheets.swift")
        #expect(activity.contains("InstallCompileText.unverifiedMessage(name: entry.name"))
        #expect(activity.contains("Install (may compile)"))
    }
}
