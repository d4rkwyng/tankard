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
    /// (R1 review) upgrades of these names fail while set (one the
    /// automatic update leaves outdated).
    final class Failing: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func set(_ n: Set<String>) { lock.withLock { names = n } }
        func contains(_ n: String) -> Bool { lock.withLock { names.contains(n) } }
    }

    func runningAutoUpdate(failing: Failing = Failing(), pick: (AppStore) -> Set<String> = { _ in [] })
        async throws -> (AppStore, Latch, Task<AutoUpdateRun?, Never>) {
        let gate = Latch()
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "fetch" { await gate.wait() }
            if args.first == "upgrade", let q = args.last, failing.contains(q.split(separator: "/").last.map(String.init) ?? q) {
                out(Data("Error: simulated failure\n".utf8))
                return 1
            }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        failing.set(pick(store))
        store.autoUpdate.settings.enabled = true
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: nil) }
        try #require(await waitUntil { u.isRunning && u.activity?.hasPrefix("Auto-update: downloading") == true })
        return (store, gate, task)
    }

    @Test func aPlanConfirmedDuringAutoUpdateStaysOnScreen() async throws {
        let failing = Failing()
        var left = ""
        let (store, gate, task) = try await runningAutoUpdate(failing: failing) { store in
            left = store.upgradable.first { $0.kind == .formula }?.name ?? ""
            return [left]
        }
        // (R1 review) an early failed #require can't leave the fetch waiting.
        defer { gate.release() }
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
        // (R1 review) the read after the run updated the plan on screen:
        // what the automatic update upgraded left it, the rest are brew's
        // current snapshots.
        let still = store.upgradable.filter { p in targets.contains { $0.id == p.id } }
        try #require(!still.isEmpty, "the fixture leaves something for the plan")
        #expect(still.map(\.name) == [left], "the automatic update upgraded the rest")
        failing.set([])
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.map(\.package.id) == UpgradePlan(packages: still, classifier: store.deps.classifier).rows.map(\.package.id))
        if still.count < targets.count { #expect(plan.changedNote != nil) }
        // Once it's done, the same plan starts.
        store.confirmUpgradePlan()
        #expect(store.upgradePlan == nil)
        #expect(store.upgrade != nil)
        // (R1 review) with what is still outdated now, not the snapshots
        // taken before the automatic update.
        let session = try #require(store.upgrade)
        let fresh = Dictionary(store.packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(session.items.map(\.package.id)) == Set(still.map(\.id)))
        for item in session.items {
            #expect(item.package.installedVersion == fresh[item.package.id]?.installedVersion)
            #expect(item.package.upgradeAvailable)
        }
        #expect(await waitUntil { session.isFinished })
    }

    @Test func theWindowsUpgradeButtonsWaitForAutoUpdate() async throws {
        let (store, gate, task) = try await runningAutoUpdate()
        defer { gate.release() }
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

// MARK: the scan line's count follows upgrades

// "Scanned 55 · 2 vulnerable" (status bar, menu bar, Settings) was
// counted once, when the scan ended. After an upgrade or uninstall of a
// vulnerable formula (and no rescan: scan-on-refresh is off by default)
// it kept saying 2 while the Vulnerable list and its header, which
// recount against what is installed, said fewer.
@MainActor
struct V094ScanCountTests {
    static func formula(_ name: String, _ version: String) -> Package {
        var p = Package.command(name)
        p.id = name
        p.name = name
        p.fullName = name
        p.installedVersion = version
        p.installedVersions = [version]
        return p
    }

    @Test func theCountFollowsWhatIsInstalled() throws {
        let store = InsightsStore(settings: InsightSettings(defaults: TestDefaults.fresh()), cache: nil, ttl: 3600, now: { Date() })
        var installed = [Self.formula("openssl@3", "3.5.9"), Self.formula("libssh2", "1.11.0"), Self.formula("xz", "5.6.2")]
        store.installedPackages = { installed }
        var scan = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        scan.checked = 55
        scan.complete = true
        scan.findings = ["openssl@3": [PackageVulnerability(id: "CVE-1", severity: .high)],
                         "libssh2": [PackageVulnerability(id: "CVE-2", severity: .high)]]
        scan.versions = ["openssl@3": "3.5.9", "libssh2": "1.11.0"]
        store.scanFinished(scan)
        #expect(store.shownScanOutcome == .done(checked: 55, found: 2, complete: true))

        // openssl@3 upgraded: the scan's version no longer matches.
        installed[0].installedVersion = "3.6.0"
        installed[0].installedVersions = ["3.6.0"]
        #expect(VulnerabilityCount.installed(scan, packages: installed) == 1)
        #expect(store.shownScanOutcome == .done(checked: 55, found: 1, complete: true))
        // libssh2 uninstalled.
        installed.remove(at: 1)
        #expect(store.shownScanOutcome == .done(checked: 55, found: 0, complete: true))
    }
}

// MARK: the new-vulnerabilities notice follows upgrades

// The menu bar's "New vulnerabilities: openssl@3" (and the ⚠ on its icon)
// came from the scan's findings alone. Once the user upgraded or
// uninstalled openssl@3 from the window, the notice stayed, and clicking
// it opened an empty Vulnerable list, until a rescan or that click.
@MainActor
struct V094NewVulnerabilityNoticeTests {
    @Test func aFormulaNoLongerVulnerableLeavesTheNotice() throws {
        let store = InsightsStore(settings: InsightSettings(defaults: TestDefaults.fresh()), cache: nil, ttl: 3600, now: { Date() })
        var installed = [V094ScanCountTests.formula("openssl@3", "3.5.9"), V094ScanCountTests.formula("libssh2", "1.11.0"),
                         V094ScanCountTests.formula("xz", "5.6.2")]
        store.installedPackages = { installed }
        store.settings.notifyNewVulnerabilities = true
        store.settings.seenVulnerabilities = []
        var scan = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        scan.checked = 55
        scan.complete = true
        scan.findings = ["openssl@3": [PackageVulnerability(id: "CVE-1", severity: .high)],
                         "libssh2": [PackageVulnerability(id: "CVE-2", severity: .high)]]
        scan.versions = ["openssl@3": "3.5.9", "libssh2": "1.11.0"]
        store.scanFinished(scan)
        #expect(store.newVulnerableFormulae == ["libssh2", "openssl@3"])

        installed[0].installedVersion = "3.6.0"
        installed[0].installedVersions = ["3.6.0"]
        #expect(store.newVulnerableFormulae == ["libssh2"])
        installed.remove(at: 1)
        #expect(store.newVulnerableFormulae.isEmpty)
    }
}

// MARK: (R1 review) the last package uninstalled: none vulnerable

// The inventory said [] both before the first report and after reading an
// installation with nothing in it. With the last package uninstalled the
// count went back to the scan's total and the notice to its names (the
// ⚠ again, leading to an empty Vulnerable list). nil is "not read yet".
@MainActor
struct V094EmptyInventoryTests {
    func scanned(_ installed: @escaping () -> [Package]?) throws -> InsightsStore {
        let store = InsightsStore(settings: InsightSettings(defaults: TestDefaults.fresh()), cache: nil, ttl: 3600, now: { Date() })
        store.installedPackages = installed
        store.settings.notifyNewVulnerabilities = true
        store.settings.seenVulnerabilities = []
        var scan = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        scan.checked = 55
        scan.complete = true
        scan.findings = ["openssl@3": [PackageVulnerability(id: "CVE-1", severity: .high)],
                         "libssh2": [PackageVulnerability(id: "CVE-2", severity: .high)]]
        scan.versions = ["openssl@3": "3.5.9", "libssh2": "1.11.0"]
        store.scanFinished(scan)
        return store
    }

    @Test func uninstallingEverythingLeavesNoneVulnerable() throws {
        var installed: [Package] = [V094ScanCountTests.formula("openssl@3", "3.5.9"), V094ScanCountTests.formula("libssh2", "1.11.0")]
        let store = try scanned { installed }
        #expect(store.shownScanOutcome == .done(checked: 55, found: 2, complete: true))
        #expect(store.newVulnerableFormulae == ["libssh2", "openssl@3"])
        installed.removeAll()
        #expect(store.shownScanOutcome == .done(checked: 55, found: 0, complete: true))
        #expect(store.newVulnerableFormulae == [])
        let scan = try #require(store.vulnerabilityScan)
        let header = VulnerableScanStatus(state: .idle, scan: scan, installed: installed)
        #expect(header.line(now: scan.scannedAt) == "Scanned 55 · 0 vulnerable · just now")
    }

    /// Before any report is read: the scan's own word.
    @Test func noReportYetIsTheScansWord() throws {
        let store = try scanned { nil }
        #expect(store.shownScanOutcome == .done(checked: 55, found: 2, complete: true))
        #expect(store.newVulnerableFormulae == ["libssh2", "openssl@3"])
    }

    /// Through the store: a report read with no packages counts none.
    @Test func anEmptyReportCountsNone() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        #expect(store.insights.installedPackages() == nil)
        await store.start()
        let r = try #require(store.report)
        #expect(store.insights.installedPackages()?.count == r.packages.count)
        store.report?.packages = []
        #expect(store.insights.installedPackages()?.isEmpty == true)
    }
}

// MARK: (R1 review) a stale plan shows its new targets before running

// A read while the plan is open (an automatic update upgraded part of it,
// brew update moved a version) changes the plan on screen. Upgrade on a
// plan that went stale since the last look shows the change first, then
// runs brew's current targets, never the snapshots taken when it opened.
@MainActor
struct V094StalePlanTests {
    @Test func aReadWhileOpenUpdatesThePlan() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let targets = Array(store.upgradable.filter { $0.kind == .formula }.prefix(3))
        try #require(targets.count == 3)
        store.upgradePlan = UpgradePlan(packages: targets, classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        let shown = try #require(store.upgradePlan)

        // Elsewhere: the first was upgraded, the second's new version moved on.
        var r = try #require(store.report)
        let i0 = try #require(r.packages.firstIndex { $0.id == targets[0].id })
        r.packages[i0].upgradeAvailable = false
        r.packages[i0].installedVersion = r.packages[i0].currentVersion ?? "new"
        let i1 = try #require(r.packages.firstIndex { $0.id == targets[1].id })
        r.packages[i1].currentVersion = "99.0"
        store.report = r

        let plan = try #require(store.upgradePlan)
        #expect(plan.id == shown.id)
        #expect(Set(plan.rows.map(\.package.id)) == [targets[1].id, targets[2].id])
        #expect(plan.rows.first { $0.package.id == targets[1].id }?.package.currentVersion == "99.0")
        #expect(plan.changedNote != nil)
        #expect(!plan.sameTargets(as: shown))

        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(Set(s.items.map(\.package.id)) == [targets[1].id, targets[2].id])
        #expect(s.items.first { $0.package.id == targets[1].id }?.package.currentVersion == "99.0")
        #expect(await waitUntil { s.isFinished })
    }

    /// A plan set before the read it missed (not yet revalidated):
    /// Upgrade shows the new plan first instead of starting.
    @Test func upgradeOnAStalePlanShowsItFirst() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let targets = Array(store.upgradable.filter { $0.kind == .formula }.prefix(2))
        try #require(targets.count == 2)
        var stale = targets
        stale[0].currentVersion = "0.0.1-old"
        store.upgradePlan = UpgradePlan(packages: stale, classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil)
        let plan = try #require(store.upgradePlan)
        #expect(plan.changedNote != nil)
        #expect(plan.rows.first { $0.package.id == targets[0].id }?.package.currentVersion == targets[0].currentVersion)
        #expect(store.showUpgradeSheet)
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.currentVersion) == plan.toRun.map(\.currentVersion))
        #expect(await waitUntil { s.isFinished })
    }

    /// Everything upgraded meanwhile: the plan says so and runs nothing.
    @Test func aPlanWithNothingLeftRunsNothing() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let target = try #require(store.upgradable.first { $0.kind == .formula })
        store.upgradePlan = UpgradePlan(packages: [target], classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.id == target.id })
        r.packages[i].upgradeAvailable = false
        store.report = r
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.isEmpty && plan.toRun.isEmpty)
        #expect(plan.changedNote?.contains("Nothing is left") == true)
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil)
        #expect(!store.showUpgradeSheet)
    }

    /// An unrelated read (sizes, vulnerabilities) leaves the plan as it was.
    @Test func aReadThatChangesNothingLeavesNoNote() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let targets = Array(store.upgradable.prefix(2))
        store.upgradePlan = UpgradePlan(packages: targets, classifier: store.deps.classifier)
        var r = try #require(store.report)
        r.packages[0].diskBytes = 12345
        store.report = r
        #expect(store.upgradePlan?.changedNote == nil)
        #expect(store.upgradePlan?.rows.map(\.package.id) == UpgradePlan(packages: targets, classifier: store.deps.classifier).rows.map(\.package.id))
    }
}
